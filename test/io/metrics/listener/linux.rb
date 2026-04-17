# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"
require "io/metrics/linux_context"
require "tempfile"
require "socket"

return unless RUBY_PLATFORM.include?("linux")

describe IO::Metrics::Listener::Linux do
	include IO::Metrics::LinuxContext
	
	def listener_display_key(listener)
		a = listener.address
		if a.afamily == Socket::AF_UNIX
			a.unix_path
		elsif a.ipv6?
			"[#{a.ip_address}]:#{a.ip_port}"
		else
			"#{a.ip_address}:#{a.ip_port}"
		end
	end
	
	def find_listener(stats, key)
		stats.find{|l| listener_display_key(l) == key}
	end
	
	with "live socket integration" do
		before do
			skip "/proc/net TCP stats unavailable" unless IO::Metrics::Listener::Linux.supported?
		end
		
		it "counts close_wait connections while application holds socket open" do
			server = TCPServer.new("127.0.0.1", 0)
			port = server.addr[1]
			address = "127.0.0.1:#{port}"
			
			begin
				client = TCPSocket.new("127.0.0.1", port)
				accepted = server.accept
				
				# Client closes — server socket moves to CLOSE_WAIT.
				client.close
				sleep 0.05
				
				stats = IO::Metrics::Listener::Linux.capture(addresses: [address])
				row = find_listener(stats, address)
				expect(row).not.to be_nil
				expect(row.close_wait_count).to be >= 1
			ensure
				accepted&.close rescue nil
				server.close
			end
		end
		
		it "counts established TCP connections after accept" do
			server = TCPServer.new("127.0.0.1", 0)
			port = server.addr[1]
			address = "127.0.0.1:#{port}"
			client1 = client2 = accepted1 = accepted2 = nil
			
			begin
				client1 = TCPSocket.new("127.0.0.1", port)
				client2 = TCPSocket.new("127.0.0.1", port)
				accepted1 = server.accept
				accepted2 = server.accept
				sleep 0.01
				
				stats = IO::Metrics::Listener::Linux.capture(addresses: [address])
				row = find_listener(stats, address)
				expect(row).not.to be_nil
				expect(row.active_count).to be >= 2
			ensure
				[client1, client2, accepted1, accepted2].compact.each(&:close) rescue nil
				server.close
			end
		end
		
		it "captures Unix domain socket listeners" do
			tmpfile = Tempfile.new("test_socket")
			socket_path = tmpfile.path
			tmpfile.close
			tmpfile.unlink
			server = UNIXServer.new(socket_path)
			
			begin
				sleep 0.01
				stats = IO::Metrics::Listener::Linux.capture(paths: [socket_path])
				row = find_listener(stats, socket_path)
				expect(row).to be_a(IO::Metrics::Listener)
			ensure
				server.close
				File.unlink(socket_path) rescue nil
			end
		end
		
		it "counts Unix socket queued and active connections" do
			tmpfile = Tempfile.new("test_socket")
			socket_path = tmpfile.path
			tmpfile.close
			tmpfile.unlink
			server = UNIXServer.new(socket_path)
			client1 = client2 = accepted1 = nil
			
			begin
				client1 = UNIXSocket.new(socket_path)
				client2 = UNIXSocket.new(socket_path)
				accepted1 = server.accept
				sleep 0.01
				
				stats = IO::Metrics::Listener::Linux.capture(paths: [socket_path])
				row = find_listener(stats, socket_path)
				expect(row).not.to be_nil
				expect(row.queued_count + row.active_count).to be >= 1
			ensure
				[client1, client2, accepted1].compact.each(&:close) rescue nil
				server.close
				File.unlink(socket_path) rescue nil
			end
		end
		
		it "captures TCP and Unix listeners together" do
			tcp_server = TCPServer.new("127.0.0.1", 0)
			tcp_port = tcp_server.addr[1]
			tcp_address = "127.0.0.1:#{tcp_port}"
			
			tmpfile = Tempfile.new("test_socket")
			socket_path = tmpfile.path
			tmpfile.close
			tmpfile.unlink
			unix_server = UNIXServer.new(socket_path)
			
			begin
				sleep 0.01
				stats = IO::Metrics::Listener::Linux.capture(
					addresses: [tcp_address],
					paths: [socket_path]
				)
				expect(find_listener(stats, tcp_address)).to be_a(IO::Metrics::Listener)
				expect(find_listener(stats, socket_path)).to be_a(IO::Metrics::Listener)
			ensure
				tcp_server.close
				unix_server.close
				File.unlink(socket_path) rescue nil
			end
		end
		
		it "sums queue_size across SO_REUSEPORT sockets sharing the same address" do
			make_server = proc do
				s = Socket.new(Socket::AF_INET6, Socket::SOCK_STREAM)
				s.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, [1].pack("i"))
				s.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, [1].pack("i"))
				s.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [1].pack("i"))
				s
			end
			
			server1 = make_server.()
			server1.bind(Addrinfo.tcp("::", 0).to_sockaddr)
			server1.listen(20)
			port = server1.local_address.ip_port
			address = "[::]:#{port}"
			
			server2 = make_server.()
			server2.bind(Addrinfo.tcp("::", port).to_sockaddr)
			server2.listen(20)
			
			clients = []
			10.times{clients << TCPSocket.new("::1", port)}
			
			# Poll until both sockets have received connections
			deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
			loop do
				all = IO::Metrics::Listener::Linux.capture || []
				total_queue = all.select{|l| l.address.ipv6? && l.address.ip_port == port}.sum(&:queued_count)
				break if total_queue >= 10
				raise "timeout waiting for queue" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
				sleep 0.02
			end
			
			stats = IO::Metrics::Listener::Linux.capture
			row = find_listener(stats, address)
			expect(row).not.to be_nil
			expect(row.queued_count).to be == 10
			expect(row.active_count).to be == 0
		ensure
			clients&.each{|c| c.close rescue nil}
			server1&.close rescue nil
			server2&.close rescue nil
		end
	end
	
	with ".parse_ipv4" do
		it "can parse IPv4 addresses from hex format" do
			expect(IO::Metrics::Listener::Linux.parse_ipv4("00000000")).to be == "0.0.0.0"
			
			# 3600007F = 127.0.0.54
			expect(IO::Metrics::Listener::Linux.parse_ipv4("3600007F")).to be == "127.0.0.54"
		end
	end
	
	with ".parse_ipv6" do
		it "can parse IPv6 addresses from hex format" do
			# 00000000000000000000000001000000 = ::1 (little-endian IPv6 loopback)
			expect(IO::Metrics::Listener::Linux.parse_ipv6("00000000000000000000000001000000")).to be == "::1"
			
			# 00000000000000000000000000000000 = :: (all zeros)
			expect(IO::Metrics::Listener::Linux.parse_ipv6("00000000000000000000000000000000")).to be == "::"
			
			# Test a more complex address compression
			# 0000000000000000000000000000FFFF = ::ffff:0.0.0.0 (IPv4-mapped address - IPAddr converts to dotted notation)
			expect(IO::Metrics::Listener::Linux.parse_ipv6("0000000000000000FFFF000000000000")).to be == "::ffff:0.0.0.0"
		end
	end
	
	with ".parse_port" do
		it "can parse ports from hex format" do
			expect(IO::Metrics::Listener::Linux.parse_port("0016")).to be == 22
			expect(IO::Metrics::Listener::Linux.parse_port("0035")).to be == 53
			expect(IO::Metrics::Listener::Linux.parse_port("1389")).to be == 5001
			expect(IO::Metrics::Listener::Linux.parse_port("0CEA")).to be == 3306
		end
	end
	
	with ".parse_state" do
		it "can parse socket states" do
			expect(IO::Metrics::Listener::Linux.parse_state("0A")).to be == :listen
			expect(IO::Metrics::Listener::Linux.parse_state("01")).to be == :established
			expect(IO::Metrics::Listener::Linux.parse_state("03")).to be == :syn_recv
		end
	end
	
	with ".capture_tcp_file" do
		let(:fixture_path) {File.join(root, "proc_net_tcp.txt")}
		let(:reuseport_fixture_path) {File.join(root, "proc_net_tcp6_reuseport.txt")}
		
		it "can parse real /proc/net/tcp data" do
			unless File.readable?(fixture_path)
				skip "Test fixture not available"
			end
			
			stats = IO::Metrics::Listener::Linux.capture_tcp_file(fixture_path, nil, ipv6: false)
			
			expect(stats).to be_a(Array)
			expect(stats.size).to be > 0
			
			# Check specific listeners from fixture
			# Line 0: 3600007F:0035 = 127.0.0.54:53 (LISTEN)
			# Line 1: 00000000:0016 = 0.0.0.0:22 (LISTEN)
			# Line 2: 00000000:0CEA = 0.0.0.0:3306 (LISTEN)
			# Line 3: 0100007F:1389 = 127.0.0.1:5001 (LISTEN)
			keys = stats.map{|listener| listener_display_key(listener)}
			%w[127.0.0.54:53 0.0.0.0:22 0.0.0.0:3306 127.0.0.1:5001].each do |key|
				expect(keys).to be(:include?, key)
			end
			
			# Check queue sizes (all should be 0 in fixture)
			stats.each do |listener|
				expect(listener).to be_a(IO::Metrics::Listener)
				expect(listener.address).to be_a(Addrinfo)
				expect(listener.queued_count).to be >= 0
				expect(listener.active_count).to be >= 0
			end
		end
		
		it "can count active connections from ESTABLISHED state" do
			unless File.readable?(fixture_path)
				skip "Test fixture not available"
			end
			
			stats = IO::Metrics::Listener::Linux.capture_tcp_file(fixture_path, nil, ipv6: false)
			
			# From fixture:
			# Line 3: 0100007F:1389 = 127.0.0.1:5001 (LISTEN)
			# Lines 18-19: ESTABLISHED connections to 127.0.0.1:1389 (5001)
			# These should match to the listener
			if row = find_listener(stats, "127.0.0.1:5001")
				expect(row.active_count).to be == 2
			end
		end
		
		it "sums queue_size across SO_REUSEPORT LISTEN rows for the same address" do
			unless File.readable?(reuseport_fixture_path)
				skip "Test fixture not available"
			end
			
			# Fixture has two LISTEN rows for [::]:8080 (0x1F90) with rx_queue 7 and 3.
			# It also has 12 server-side ESTABLISHED inode=0 entries and 3 client-side entries.
			# Expected: queue_size = 7+3 = 10, active_connections = max(12-10, 0) = 2.
			stats = IO::Metrics::Listener::Linux.capture_tcp_file(reuseport_fixture_path, nil, ipv6: true)
			
			row = find_listener(stats, "[::]:8080")
			expect(row).not.to be_nil
			expect(row.queued_count).to be == 10
			expect(row.active_count).to be == 2
		end
	end
	
	with ".capture_unix" do
		let(:fixture_path) {File.join(root, "proc_net_unix.txt")}
		
		it "can parse real /proc/net/unix data" do
			unless File.readable?(fixture_path)
				skip "Test fixture not available"
			end
			
			stats = IO::Metrics::Listener::Linux.capture_unix(nil, file: fixture_path)
			
			expect(stats).to be_a(Array)
			
			# Check specific Unix sockets from fixture
			paths = stats.map{|listener| listener.address.unix_path}
			%w[/run/user/1000/wayland-0 /run/user/1000/bus /run/dbus/system_bus_socket].each do |path|
				expect(paths).to be(:include?, path)
			end
			
			# Check that queued and active connections are counted correctly
			# From fixture: /run/user/1000/bus has 2 SS_CONNECTED (0x03) entries (lines 4-5)
			expect(find_listener(stats, "/run/user/1000/bus").active_count).to be == 2
			
			# From fixture: /run/user/1000/wayland-0 has 1 SS_CONNECTING (0x02) entry (line 3)
			expect(find_listener(stats, "/run/user/1000/wayland-0").queued_count).to be == 1
		end
		
		it "can filter by specific paths" do
			unless File.readable?(fixture_path)
				skip "Test fixture not available"
			end
			
			stats = IO::Metrics::Listener::Linux.capture_unix(["/run/user/1000/bus"], file: fixture_path)
			
			paths = stats.map{|listener| listener.address.unix_path}
			expect(paths).to be(:include?, "/run/user/1000/bus")
			expect(paths).not.to be(:include?, "/run/user/1000/wayland-0")
		end
	end
end
