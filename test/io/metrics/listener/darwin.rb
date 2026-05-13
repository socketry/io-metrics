# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"
require "socket"

return unless RUBY_PLATFORM.include?("darwin")
return unless IO::Metrics::Listener::Darwin.supported?

describe IO::Metrics::Listener::Darwin do
	def find_listener(stats, key)
		stats.find do |l|
			address = l.address
			display = address.ipv6? ? "[#{address.ip_address}]:#{address.ip_port}" : "#{address.ip_address}:#{address.ip_port}"
			display == key
		end
	end
	
	with "IPv4 listener" do
		it "detects a wildcard IPv4 listener" do
			server = TCPServer.new("0.0.0.0", 0)
			port = server.addr[1]
			address = "0.0.0.0:#{port}"
			
			begin
				stats = IO::Metrics::Listener::Darwin.capture_tcp
				expect(find_listener(stats, address)).to be_a(IO::Metrics::Listener)
			ensure
				server.close
			end
		end
		
		it "reports accept queue depth for IPv4 connections" do
			n = 5
			server = TCPServer.new("127.0.0.1", 0)
			server.listen(n + 2)
			port = server.addr[1]
			address = "127.0.0.1:#{port}"
			
			clients = n.times.map{TCPSocket.new("127.0.0.1", port)}
			sleep 0.05
			
			begin
				stats = IO::Metrics::Listener::Darwin.capture_tcp
				row = find_listener(stats, address)
				expect(row).not.to be_nil
				expect(row.queued_count).to be == n
			ensure
				clients.each(&:close)
				server.close
			end
		end
	end
	
	with "IPv6 listener" do
		it "detects an IPv6 loopback listener" do
			server = TCPServer.new("::1", 0)
			port = server.addr[1]
			address = "[::1]:#{port}"
			
			begin
				stats = IO::Metrics::Listener::Darwin.capture_tcp
				expect(find_listener(stats, address)).to be_a(IO::Metrics::Listener)
			ensure
				server.close
			end
		rescue Errno::EADDRNOTAVAIL
			skip "IPv6 not available on this system"
		end
		
		it "reports accept queue depth for IPv6 connections" do
			n = 5
			server = TCPServer.new("::1", 0)
			server.listen(n + 2)
			port = server.addr[1]
			address = "[::1]:#{port}"
			
			clients = n.times.map{TCPSocket.new("::1", port)}
			sleep 0.05
			
			begin
				stats = IO::Metrics::Listener::Darwin.capture_tcp
				row = find_listener(stats, address)
				expect(row).not.to be_nil
				expect(row.queued_count).to be == n
			ensure
				clients.each(&:close)
				server.close
			end
		rescue Errno::EADDRNOTAVAIL
			skip "IPv6 not available on this system"
		end
		
		it "accumulates queued_count for both IPv4 and IPv6 wildcard sockets on the same port" do
			# macOS netstat -L renders both 0.0.0.0:PORT and [::]:PORT as "*.PORT",
			# so they share a single listener entry keyed as "0.0.0.0:PORT".
			# The queued_count must be the SUM of both sockets' accept queues.
			n = 3
			s4 = Socket.new(:INET, :STREAM)
			s4.setsockopt(:SOCKET, :REUSEADDR, true)
			s4.bind(Socket.sockaddr_in(0, "0.0.0.0"))
			s4.listen(n + 2)
			port = Socket.unpack_sockaddr_in(s4.getsockname)[0]
			
			s6 = Socket.new(:INET6, :STREAM)
			s6.setsockopt(:SOCKET, :REUSEADDR, true)
			s6.setsockopt(:IPV6, :V6ONLY, 1)
			s6.bind(Addrinfo.tcp("::", port).to_sockaddr)
			s6.listen(n + 2)
			
			clients4 = n.times.map{TCPSocket.new("127.0.0.1", port)}
			clients6 = n.times.map{TCPSocket.new("::1", port)}
			sleep 0.05
			
			begin
				stats = IO::Metrics::Listener::Darwin.capture_tcp
				row = find_listener(stats, "0.0.0.0:#{port}")
				expect(row).to be_a(IO::Metrics::Listener)
				# Both wildcard sockets appear as "*.PORT" — queued_count is the combined total.
				expect(row.queued_count).to be == (n * 2)
			ensure
				clients4.each(&:close)
				clients6.each(&:close)
				s4.close
				s6.close
			end
		rescue Errno::EADDRNOTAVAIL
			skip "IPv6 not available on this system"
		end
	end
end
