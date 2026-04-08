# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"
require "json"
require "socket"

describe IO::Metrics::Listener do
	def listener_display_key(listener)
		address = listener.address
		return address.unix_path if address.afamily == Socket::AF_UNIX
		
		address.ipv6? ? "[#{address.ip_address}]:#{address.ip_port}" : "#{address.ip_address}:#{address.ip_port}"
	end
	
	def find_listener(stats, key)
		stats.find { |listener| listener_display_key(listener) == key }
	end
	
	# Wait until capture reports at least the given accept-queue depth (fully established, not yet accepted).
	def wait_for_tcp_queue_at_least(address, minimum, timeout: 2.0, interval: 0.01)
		deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
		
		loop do
			stats = IO::Metrics::Listener.capture(addresses: [address])
			next unless stats
			
			row = find_listener(stats, address)
			return row if row && row.queue_size >= minimum
			
			raise "timed out waiting for queue_size >= #{minimum} on #{address}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
			
			sleep interval
		end
	end
	
	with ".zero" do
		it "creates a zero-initialized instance" do
			listener = IO::Metrics::Listener.zero
			
			expect(listener).to have_attributes(
				address: be_nil,
				queue_size: be == 0,
				active_connections: be == 0
			)
		end
		
		it "serializes to JSON with null address and integer counters" do
			json = JSON.parse(IO::Metrics::Listener.zero.to_json)
			
			expect(json["address"]).to be_nil
			expect(json["queue_size"]).to be == 0
			expect(json["active_connections"]).to be == 0
		end
	end
	
	with ".capture" do
		it "can capture listener stats" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			stats = IO::Metrics::Listener.capture
			
			expect(stats).to be_a(Array)
		end
		
		it "includes an ephemeral listener when capturing without filters" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			server = TCPServer.new("127.0.0.1", 0)
			port = server.addr[1]
			address = "127.0.0.1:#{port}"
			
			begin
				sleep 0.01
				stats = IO::Metrics::Listener.capture
				expect(find_listener(stats, address)).not.to be_nil
			ensure
				server.close
			end
		end
		
		it "finds a wildcard IPv4 listener by address filter" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			server = TCPServer.new("0.0.0.0", 0)
			port = server.addr[1]
			address = "0.0.0.0:#{port}"
			
			begin
				stats = IO::Metrics::Listener.capture(addresses: [address])
				expect(find_listener(stats, address)).to be_a(IO::Metrics::Listener)
			ensure
				server.close
			end
		end
		
		it "can capture stats for specific addresses" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			# Try to capture stats for common ports
			stats = IO::Metrics::Listener.capture(addresses: ["0.0.0.0:22", "127.0.0.1:8080"])
			
			expect(stats).to be_a(Array)
			stats.each do |listener|
				expect(listener).to be_a(IO::Metrics::Listener)
				expect(listener.address).to be_a(Addrinfo)
				expect(listener.queue_size).to be >= 0
				expect(listener.active_connections).to be >= 0
			end
		end
		
		it "can generate json value" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			stats = IO::Metrics::Listener.capture
			next if stats.empty?
			
			listener = stats.first
			json_string = listener.to_json
			json = JSON.parse(json_string)
			
			expect(json).to have_keys("address", "queue_size", "active_connections")
			expect(json["address"]).to be_a(String)
			expect(json["queue_size"]).to be_a(Integer)
			expect(json["active_connections"]).to be_a(Integer)
		end
		
		with "TCP accept queue" do
			it "reports accept queue size when clients connect without accept" do
				unless IO::Metrics::Listener.supported?
					skip "Listener stats are not supported on this platform!"
				end
				
				n = 10
				server = TCPServer.new("127.0.0.1", 0)
				server.listen([n, Socket::SOMAXCONN].min)
				port = server.addr[1]
				address = "127.0.0.1:#{port}"
				clients = []
				clients_mutex = Mutex.new
				
				begin
					threads = n.times.map do
						Thread.new do
							c = TCPSocket.new("127.0.0.1", port)
							clients_mutex.synchronize { clients << c }
						end
					end
					threads.each(&:join)
					
					row = wait_for_tcp_queue_at_least(address, n)
					expect(row.queue_size).to be == n
				ensure
					clients.each(&:close) rescue nil
					server.close
				end
			end
			
			it "reports remaining accept queue after partial accept" do
				unless IO::Metrics::Listener.supported?
					skip "Listener stats are not supported on this platform!"
				end
				
				total = 8
				accept_count = 3
				server = TCPServer.new("127.0.0.1", 0)
				server.listen([total, Socket::SOMAXCONN].min)
				port = server.addr[1]
				address = "127.0.0.1:#{port}"
				clients = []
				clients_mutex = Mutex.new
				accepted = []
				
				begin
					threads = total.times.map do
						Thread.new do
							c = TCPSocket.new("127.0.0.1", port)
							clients_mutex.synchronize { clients << c }
						end
					end
					threads.each(&:join)
					
					wait_for_tcp_queue_at_least(address, total)
					
					accept_count.times { accepted << server.accept }
					sleep 0.02
					
					stats = IO::Metrics::Listener.capture(addresses: [address])
					row = find_listener(stats, address)
					expect(row).not.to be_nil
					expect(row.queue_size).to be == (total - accept_count)
					if RUBY_PLATFORM.include?("linux")
						expect(row.active_connections).to be >= accept_count
					end
				ensure
					clients.each(&:close) rescue nil
					accepted.each(&:close) rescue nil
					server.close
				end
			end
			
			it "reports accept queue size on IPv6 loopback when clients connect without accept" do
				unless IO::Metrics::Listener.supported?
					skip "Listener stats are not supported on this platform!"
				end
				
				# Darwin uses netstat -L; IPv6 listener lines are not consistently parseable.
				if RUBY_PLATFORM.include?("darwin")
					skip "IPv6 listener queue capture is not exercised on Darwin"
				end
				
				n = 10
				server = TCPServer.new("::1", 0)
				server.listen([n, Socket::SOMAXCONN].min)
				port = server.addr[1]
				address = "[::1]:#{port}"
				clients = []
				clients_mutex = Mutex.new
				
				begin
					threads = n.times.map do
						Thread.new do
							c = TCPSocket.new("::1", port)
							clients_mutex.synchronize { clients << c }
						end
					end
					threads.each(&:join)
					
					row = wait_for_tcp_queue_at_least(address, n)
					expect(row.queue_size).to be == n
				ensure
					clients.each(&:close) rescue nil
					server.close
				end
			rescue Errno::EADDRNOTAVAIL
				skip "IPv6 not available on this system"
			end
		end
	end
end
