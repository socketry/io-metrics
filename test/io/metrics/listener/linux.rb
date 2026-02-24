# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"

return unless RUBY_PLATFORM.include?("linux")

describe IO::Metrics::Listener::Linux do
	with ".parse_ipv4" do
		it "can parse IPv4 addresses from hex format" do
			# 0100007F = 127.0.0.1 (little-endian)
			expect(IO::Metrics::Listener::Linux.parse_ipv4("0100007F")).to be == "127.0.0.1"
			
			# 00000000 = 0.0.0.0 (wildcard)
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
		let(:fixture_path) {File.expand_path(".linux/proc_net_tcp.txt", __dir__)}
		
		it "can parse real /proc/net/tcp data" do
			unless File.readable?(fixture_path)
				skip "Test fixture not available"
			end
			
			stats = IO::Metrics::Listener::Linux.capture_tcp_file(fixture_path, nil, ipv6: false)
			
			expect(stats).to be_a(Hash)
			expect(stats.size).to be > 0
			
			# Check specific listeners from fixture
			# Line 0: 3600007F:0035 = 127.0.0.54:53 (LISTEN)
			# Line 1: 00000000:0016 = 0.0.0.0:22 (LISTEN)
			# Line 2: 00000000:0CEA = 0.0.0.0:3306 (LISTEN)
			# Line 3: 0100007F:1389 = 127.0.0.1:5001 (LISTEN)
			expect(stats).to have_keys("127.0.0.54:53", "0.0.0.0:22", "0.0.0.0:3306", "127.0.0.1:5001")
			
			# Check queue sizes (all should be 0 in fixture)
			stats.each_value do |listener|
				expect(listener).to be_a(IO::Metrics::Listener)
				expect(listener.queue_size).to be >= 0
				expect(listener.active_connections).to be >= 0
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
			if stats["127.0.0.1:5001"]
				expect(stats["127.0.0.1:5001"].active_connections).to be == 2
			end
		end
	end
	
	with ".capture_unix" do
		let(:fixture_path) {File.expand_path(".linux/proc_net_unix.txt", __dir__)}
		
		it "can parse real /proc/net/unix data" do
			unless File.readable?(fixture_path)
				skip "Test fixture not available"
			end
			
			stats = IO::Metrics::Listener::Linux.capture_unix(nil, file: fixture_path)
			
			expect(stats).to be_a(Hash)
			
			# Check specific Unix sockets from fixture
			expect(stats).to have_keys("/run/user/1000/wayland-0", "/run/user/1000/bus", "/run/dbus/system_bus_socket")
			
			# Check that queued and active connections are counted correctly
			# From fixture: /run/user/1000/bus has 2 SS_CONNECTED (0x03) entries (lines 4-5)
			expect(stats["/run/user/1000/bus"].active_connections).to be == 2
			
			# From fixture: /run/user/1000/wayland-0 has 1 SS_CONNECTING (0x02) entry (line 3)
			expect(stats["/run/user/1000/wayland-0"].queue_size).to be == 1
		end
		
		it "can filter by specific paths" do
			unless File.readable?(fixture_path)
				skip "Test fixture not available"
			end
			
			stats = IO::Metrics::Listener::Linux.capture_unix(["/run/user/1000/bus"], file: fixture_path)
			
			expect(stats).to have_keys("/run/user/1000/bus")
			expect(stats).not.to have_keys("/run/user/1000/wayland-0")
		end
	end
end
