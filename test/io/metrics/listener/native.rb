# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"
require "socket"

return unless RUBY_PLATFORM.include?("linux") && defined?(IO::Metrics::Listener::Native)

describe IO::Metrics::Listener::Native do
	def listener_key(listener)
		address = listener.address
		address.ipv6? ? "[#{address.ip_address}]:#{address.ip_port}" : "#{address.ip_address}:#{address.ip_port}"
	end
	
	def find_listener(stats, key)
		stats.find{|l| listener_key(l) == key}
	end
	
	with "supported?" do
		it "returns true on Linux with inet_diag" do
			expect(IO::Metrics::Listener::Native.supported?).to be == true
		end
	end
	
	with ".capture" do
		it "returns an Array" do
			stats = IO::Metrics::Listener::Native.capture
			expect(stats).to be_a(Array)
		end
		
		it "includes an active TCP listener" do
			server = TCPServer.new("127.0.0.1", 0)
			port   = server.addr[1]
			key    = "127.0.0.1:#{port}"
			
			begin
				stats = IO::Metrics::Listener::Native.capture
				row   = find_listener(stats, key)
				expect(row).not.to be_nil
				expect(row).to be_a(IO::Metrics::Listener)
			ensure
				server.close
			end
		end
		
		it "filters by address" do
			server = TCPServer.new("127.0.0.1", 0)
			port   = server.addr[1]
			key    = "127.0.0.1:#{port}"
			
			begin
				stats = IO::Metrics::Listener::Native.capture(addresses: [key])
				expect(stats.size).to be == 1
				expect(listener_key(stats.first)).to be == key
			ensure
				server.close
			end
		end
		
		it "counts accepted ESTABLISHED connections as active" do
			server = TCPServer.new("127.0.0.1", 0)
			port   = server.addr[1]
			key    = "127.0.0.1:#{port}"
			
			begin
				c1 = TCPSocket.new("127.0.0.1", port)
				c2 = TCPSocket.new("127.0.0.1", port)
				a1 = server.accept
				a2 = server.accept
				sleep 0.05
				
				stats = IO::Metrics::Listener::Native.capture(addresses: [key])
				row   = find_listener(stats, key)
				expect(row).not.to be_nil
				expect(row.active_count).to be >= 2
			ensure
				[c1, c2, a1, a2].compact.each{|s| s.close rescue nil}
				server.close
			end
		end
		
		it "counts queued (not-yet-accepted) connections" do
			server = TCPServer.new("127.0.0.1", 0)
			port   = server.addr[1]
			key    = "127.0.0.1:#{port}"
			n      = 3
			
			begin
				clients = n.times.map{TCPSocket.new("127.0.0.1", port)}
				
				deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
				loop do
					stats = IO::Metrics::Listener::Native.capture(addresses: [key])
					row   = find_listener(stats, key)
					break if row&.queued_count.to_i >= n
					raise "timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
					sleep 0.02
				end
				
				stats = IO::Metrics::Listener::Native.capture(addresses: [key])
				row   = find_listener(stats, key)
				expect(row).not.to be_nil
				expect(row.queued_count).to be >= n
			ensure
				clients&.each{|c| c.close rescue nil}
				server.close
			end
		end
		
		it "counts CLOSE_WAIT connections" do
			server   = TCPServer.new("127.0.0.1", 0)
			port     = server.addr[1]
			key      = "127.0.0.1:#{port}"
			client   = TCPSocket.new("127.0.0.1", port)
			accepted = server.accept
			
			begin
				client.close   # server side enters CLOSE_WAIT
				sleep 0.1
				
				stats = IO::Metrics::Listener::Native.capture(addresses: [key])
				row   = find_listener(stats, key)
				expect(row).not.to be_nil
				expect(row.close_wait_count).to be >= 1
			ensure
				accepted&.close rescue nil
				server.close
			end
		end
		
		it "counts FIN_WAIT connections when server closes first" do
			server   = TCPServer.new("127.0.0.1", 0)
			port     = server.addr[1]
			key      = "127.0.0.1:#{port}"
			client   = TCPSocket.new("127.0.0.1", port)
			accepted = server.accept
			
			begin
				accepted.close   # server enters FIN_WAIT1 → FIN_WAIT2
				sleep 0.05
				
				stats = IO::Metrics::Listener::Native.capture(addresses: [key])
				row   = find_listener(stats, key)
				expect(row).not.to be_nil
				expect(row.fin_wait_count).to be >= 1
			ensure
				client&.close rescue nil
				server.close rescue nil
			end
		end
		
		it "counts TIME_WAIT connections after both sides close" do
			server   = TCPServer.new("127.0.0.1", 0)
			port     = server.addr[1]
			key      = "127.0.0.1:#{port}"
			client   = TCPSocket.new("127.0.0.1", port)
			accepted = server.accept
			
			begin
				accepted.close   # server closes → FIN_WAIT2
				sleep 0.02
				client.close     # client closes → server enters TIME_WAIT
				sleep 0.05
				
				stats = IO::Metrics::Listener::Native.capture(addresses: [key])
				row   = find_listener(stats, key)
				expect(row).not.to be_nil
				expect(row.time_wait_count).to be >= 1
			ensure
				server.close rescue nil
			end
		end
		
		it "native and Linux results agree on active_count for established connections" do
			server = TCPServer.new("127.0.0.1", 0)
			port   = server.addr[1]
			key    = "127.0.0.1:#{port}"
			n      = 4
			
			begin
				clients  = n.times.map{TCPSocket.new("127.0.0.1", port)}
				accepted = n.times.map{server.accept}
				sleep 0.05
				
				native_stats = IO::Metrics::Listener::Native.capture(addresses: [key])
				linux_stats  = IO::Metrics::Listener::Linux.capture(addresses: [key])
				
				native_row = find_listener(native_stats, key)
				linux_row  = linux_stats&.find{|l|
					address = l.address
					"#{address.ip_address}:#{address.ip_port}" == key
				}
				
				expect(native_row).not.to be_nil
				expect(linux_row).not.to be_nil
				
				# Both backends count the same ESTABLISHED connections.
				diff = (native_row.active_count - linux_row.active_count).abs
				expect(diff).to be <= 1
			ensure
				[*clients, *accepted].compact.each{|s| s.close rescue nil}
				server.close
			end
		end
	end
end
