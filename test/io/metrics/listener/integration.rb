# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"
require "socket"
require "tempfile"

return unless RUBY_PLATFORM.include?("linux")

describe IO::Metrics::Listener::Linux do
	with "real TCP sockets" do
		it "can capture TCP listener statistics" do
			# Bind a TCP server socket
			server = TCPServer.new("127.0.0.1", 0)
			port = server.addr[1]
			address = "127.0.0.1:#{port}"
			
			begin
				# Capture listener stats
				stats = IO::Metrics::Listener::Linux.capture_tcp([address])
				
				# Should find the listener
				expect(stats).to have_keys(address)
				expect(stats[address]).to be_a(IO::Metrics::Listener)
				expect(stats[address].queue_size).to be >= 0
				expect(stats[address].active_connections).to be == 0
			ensure
				server.close
			end
		end
		
		it "can count active TCP connections" do
			# Bind a TCP server socket
			server = TCPServer.new("127.0.0.1", 0)
			port = server.addr[1]
			address = "127.0.0.1:#{port}"
			
			begin
				# Create client connections
				client1 = TCPSocket.new("127.0.0.1", port)
				client2 = TCPSocket.new("127.0.0.1", port)
				
				# Accept connections
				accepted1 = server.accept
				accepted2 = server.accept
				
				# Give the kernel a moment to update /proc
				sleep 0.01
				
				# Capture listener stats
				stats = IO::Metrics::Listener::Linux.capture_tcp([address])
				
				# Should count established connections
				expect(stats).to have_keys(address)
				expect(stats[address].active_connections).to be >= 2
			ensure
				[client1, client2, accepted1, accepted2].compact.each(&:close) rescue nil
				server.close
			end
		end
		
		it "can capture IPv6 TCP listeners" do
			begin
				# Try to bind an IPv6 server socket
				server = TCPServer.new("::1", 0)
				port = server.addr[1]
				address = "[::1]:#{port}"
				
				# Capture listener stats
				stats = IO::Metrics::Listener::Linux.capture_tcp([address])
				
				# Should find the listener
				expect(stats).to have_keys(address)
				expect(stats[address]).to be_a(IO::Metrics::Listener)
			ensure
				server.close if server
			end
		rescue Errno::EADDRNOTAVAIL
			skip "IPv6 not available on this system"
		end
		
		it "can capture wildcard listeners" do
			# Bind to all interfaces
			server = TCPServer.new("0.0.0.0", 0)
			port = server.addr[1]
			address = "0.0.0.0:#{port}"
			
			begin
				# Capture listener stats
				stats = IO::Metrics::Listener::Linux.capture_tcp([address])
				
				# Should find the wildcard listener
				expect(stats).to have_keys(address)
				expect(stats[address]).to be_a(IO::Metrics::Listener)
			ensure
				server.close
			end
		end
	end
	
	with "real Unix domain sockets" do
		it "can capture Unix socket listener statistics" do
			# Create a temporary socket path
			tmpfile = Tempfile.new("test_socket")
			socket_path = tmpfile.path
			tmpfile.close
			tmpfile.unlink
			
			# Create a Unix server socket
			server = UNIXServer.new(socket_path)
			
			begin
				# Give the kernel a moment to update /proc
				sleep 0.01
				
				# Capture Unix socket stats
				stats = IO::Metrics::Listener::Linux.capture_unix([socket_path])
				
				# Should find the listener
				expect(stats).to have_keys(socket_path)
				expect(stats[socket_path]).to be_a(IO::Metrics::Listener)
			ensure
				server.close
				File.unlink(socket_path) rescue nil
			end
		end
		
		it "can count Unix socket connections" do
			# Create a temporary socket path
			tmpfile = Tempfile.new("test_socket")
			socket_path = tmpfile.path
			tmpfile.close
			tmpfile.unlink
			
			# Create a Unix server socket
			server = UNIXServer.new(socket_path)
			
			begin
				# Create client connections
				client1 = UNIXSocket.new(socket_path)
				client2 = UNIXSocket.new(socket_path)
				
				# Accept one connection (leave one in queue)
				accepted1 = server.accept
				
				# Give the kernel a moment to update /proc
				sleep 0.01
				
				# Capture Unix socket stats
				stats = IO::Metrics::Listener::Linux.capture_unix([socket_path])
				
				# Should count connections
				expect(stats).to have_keys(socket_path)
				# Note: Exact counts may vary by system/timing
				total_connections = stats[socket_path].queue_size + stats[socket_path].active_connections
				expect(total_connections).to be >= 1
			ensure
				[client1, client2, accepted1].compact.each(&:close) rescue nil
				server.close
				File.unlink(socket_path) rescue nil
			end
		end
	end
	
	with "capture method integration" do
		it "can capture all socket types together" do
			# Create TCP server
			tcp_server = TCPServer.new("127.0.0.1", 0)
			tcp_port = tcp_server.addr[1]
			tcp_address = "127.0.0.1:#{tcp_port}"
			
			# Create Unix server
			tmpfile = Tempfile.new("test_socket")
			socket_path = tmpfile.path
			tmpfile.close
			tmpfile.unlink
			unix_server = UNIXServer.new(socket_path)
			
			begin
				# Give the kernel a moment to update /proc
				sleep 0.01
				
				# Capture both types
				stats = IO::Metrics::Listener::Linux.capture(
					addresses: [tcp_address],
					paths: [socket_path]
				)
				
				# Should find both
				expect(stats).to have_keys(tcp_address, socket_path)
				expect(stats[tcp_address]).to be_a(IO::Metrics::Listener)
				expect(stats[socket_path]).to be_a(IO::Metrics::Listener)
			ensure
				tcp_server.close
				unix_server.close
				File.unlink(socket_path) rescue nil
			end
		end
		
		it "can capture all listeners when no filter specified" do
			# Create a server
			server = TCPServer.new("127.0.0.1", 0)
			port = server.addr[1]
			address = "127.0.0.1:#{port}"
			
			begin
				# Give the kernel a moment to update /proc
				sleep 0.01
				
				# Capture all listeners (no filter)
				stats = IO::Metrics::Listener::Linux.capture
				
				# Should include our server (and possibly others)
				expect(stats).to be_a(Hash)
				expect(stats.size).to be > 0
			ensure
				server.close
			end
		end
	end
end
