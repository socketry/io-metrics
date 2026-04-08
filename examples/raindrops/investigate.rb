#!/usr/bin/env ruby
# frozen_string_literal: true

# Investigation script: try to reproduce io-metrics queue_size being 2x raindrops.
# Runs several scenarios and dumps raw /proc data + library results.
# Usage: bundle exec ruby investigate.rb

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("gems.rb", __dir__)
require "bundler/setup"
require "io/metrics"
require "raindrops"
require "socket"

PORT_HEX = ->(port) { format("%04X", port) }

# ─── helpers ────────────────────────────────────────────────────────────────

def proc_lines_for_port(port)
	hex = PORT_HEX.(port)
	{
		tcp:  File.readlines("/proc/net/tcp").select  { |l| l.include?(hex) },
		tcp6: File.readlines("/proc/net/tcp6").select { |l| l.include?(hex) },
	}
end

def print_proc(port)
	lines = proc_lines_for_port(port)
	puts "  /proc/net/tcp  (#{lines[:tcp].size} lines):"
	lines[:tcp].each  { |l| puts "    #{l.rstrip}" }
	puts "  /proc/net/tcp6 (#{lines[:tcp6].size} lines):"
	lines[:tcp6].each { |l| puts "    #{l.rstrip}" }
end

def library_results(port)
	# io-metrics
	all_metrics = IO::Metrics::Listener.capture || []
	metrics = all_metrics.select do |l|
		l.address && (l.address.ip_port == port rescue false)
	end

	# raindrops
	rd_all = Raindrops::Linux.tcp_listener_stats(nil)
	hex = PORT_HEX.(port).upcase
	raindrops = rd_all.select do |key, _|
		key.to_s =~ /:#{port}\z/
	end

	{metrics: metrics, raindrops: raindrops}
end

def print_results(label, port)
	puts "\n── #{label} ──"
	r = library_results(port)

	puts "  io-metrics:"
	if r[:metrics].empty?
		puts "    (none)"
	else
		r[:metrics].each do |l|
			puts "    #{l.address.inspect_sockaddr}  queue=#{l.queue_size}  active=#{l.active_connections}"
		end
	end
	total_metrics_q = r[:metrics].sum(&:queue_size)

	puts "  raindrops:"
	if r[:raindrops].empty?
		puts "    (none)"
	else
		r[:raindrops].each do |key, v|
			puts "    #{key}  queued=#{v.queued}  active=#{v.active}"
		end
	end
	total_rd_q = r[:raindrops].values.sum(&:queued)

	ratio = total_rd_q > 0 ? (total_metrics_q.to_f / total_rd_q).round(2) : "inf"
	puts "  TOTALS: io-metrics queue=#{total_metrics_q}  raindrops queued=#{total_rd_q}  ratio=#{ratio}"
	puts "  raw /proc:"
	print_proc(port)
end

def wait_for_queue(min_q, port, timeout: 3.0)
	deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
	loop do
		all = IO::Metrics::Listener.capture || []
		total = all.select { |l| l.address && (l.address.ip_port == port rescue false) }.sum(&:queue_size)
		return true if total >= min_q
		raise "timeout waiting for queue #{min_q} on port #{port}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
		sleep 0.02
	end
end

# ════════════════════════════════════════════════════════════════════════════
puts "=" * 70
puts "SCENARIO 1: Dual-stack socket (IPV6_V6ONLY=0), IPv4 + IPv6 clients"
puts "=" * 70
# Does the LISTEN socket appear in BOTH /proc/net/tcp and /proc/net/tcp6?

server1 = TCPServer.new("::", 0)
server1.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [0].pack("i")) rescue nil
server1.listen(20)
port1 = server1.addr[1]

print_results("idle", port1)

clients1 = []
5.times { clients1 << TCPSocket.new("127.0.0.1", port1) }
5.times { clients1 << TCPSocket.new("::1", port1) }
wait_for_queue(10, port1)
print_results("10 connected (5×IPv4 + 5×IPv6), none accepted", port1)

clients1.each(&:close)
server1.close

# ════════════════════════════════════════════════════════════════════════════
puts "\n" + "=" * 70
puts "SCENARIO 2: IPv6-only socket (IPV6_V6ONLY=1)"
puts "=" * 70

server2 = TCPServer.new("::", 0)
server2.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [1].pack("i")) rescue nil
server2.listen(20)
port2 = server2.addr[1]

print_results("idle", port2)

clients2 = []
10.times { clients2 << TCPSocket.new("::1", port2) }
wait_for_queue(10, port2)
print_results("10 IPv6 clients, none accepted", port2)

clients2.each(&:close)
server2.close

# ════════════════════════════════════════════════════════════════════════════
puts "\n" + "=" * 70
puts "SCENARIO 3: Two separate sockets — IPv4 (0.0.0.0) then IPv6 (::) on same port"
puts "=" * 70

server3_v4 = TCPServer.new("0.0.0.0", 0)
server3_v4.listen(20)
port3 = server3_v4.addr[1]

server3_v6 = Socket.new(Socket::AF_INET6, Socket::SOCK_STREAM)
server3_v6.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [1].pack("i"))
server3_v6.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, [1].pack("i"))
v6_sockaddr = Addrinfo.tcp("::", port3).to_sockaddr
server3_v6.bind(v6_sockaddr)
server3_v6.listen(20)

print_results("idle — two separate sockets", port3)

clients3 = []
5.times { clients3 << TCPSocket.new("127.0.0.1", port3) }
5.times { clients3 << TCPSocket.new("::1", port3) }
wait_for_queue(10, port3)
print_results("10 connected (5×IPv4 via v4 sock, 5×IPv6 via v6 sock), none accepted", port3)

clients3.each(&:close)
server3_v4.close
server3_v6.close

# ════════════════════════════════════════════════════════════════════════════
puts "\n" + "=" * 70
puts "SCENARIO 4: SO_REUSEPORT — two listeners on same address"
puts "=" * 70

make_reuseport_server = ->(family) do
	s = Socket.new(family, Socket::SOCK_STREAM)
	s.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, [1].pack("i"))
	s.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, [1].pack("i"))
	if family == Socket::AF_INET6
		s.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [1].pack("i"))
	end
	s
end

server4a = make_reuseport_server.(Socket::AF_INET6)
server4a.bind(Addrinfo.tcp("::", 0).to_sockaddr)
server4a.listen(20)
port4 = server4a.local_address.ip_port

server4b = make_reuseport_server.(Socket::AF_INET6)
server4b.bind(Addrinfo.tcp("::", port4).to_sockaddr)
server4b.listen(20)

print_results("idle — two SO_REUSEPORT sockets", port4)

clients4 = []
# Connect enough to hopefully fill both accept queues
20.times { clients4 << TCPSocket.new("::1", port4) }
sleep 0.1
print_results("20 IPv6 clients — io-metrics (assigns last rx_queue) vs raindrops (sums idiag_rqueue)", port4)

clients4.each(&:close)
server4a.close
server4b.close

# ════════════════════════════════════════════════════════════════════════════
puts "\n" + "=" * 70
puts "SCENARIO 4b: SO_REUSEPORT with IPv4 + IPv6 mixed sockets on same port"
puts "=" * 70
# Test if io-metrics under/over-reports vs Raindrops with mixed family REUSEPORT

server4c_v4 = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM)
server4c_v4.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, [1].pack("i"))
server4c_v4.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, [1].pack("i"))
server4c_v4.bind(Addrinfo.tcp("0.0.0.0", 0).to_sockaddr)
server4c_v4.listen(20)
port4b = server4c_v4.local_address.ip_port

server4c_v6 = Socket.new(Socket::AF_INET6, Socket::SOCK_STREAM)
server4c_v6.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, [1].pack("i"))
server4c_v6.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, [1].pack("i"))
server4c_v6.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [0].pack("i")) rescue nil
server4c_v6.bind(Addrinfo.tcp("::", port4b).to_sockaddr)
server4c_v6.listen(20)

print_results("idle — IPv4 (0.0.0.0) + dual-stack ([::]) REUSEPORT", port4b)

clients4b = []
10.times { clients4b << TCPSocket.new("127.0.0.1", port4b) }
sleep 0.1
print_results("10 IPv4 clients — key question: does io-metrics double-count [::] AND 0.0.0.0?", port4b)

clients4b.each(&:close)
server4c_v4.close
server4c_v6.close

# ════════════════════════════════════════════════════════════════════════════
puts "\n" + "=" * 70
puts "SCENARIO 5: Partially accepted — what does rx_queue show vs Raindrops?"
puts "=" * 70

server5 = TCPServer.new("::", 0)
server5.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [0].pack("i")) rescue nil
server5.listen(20)
port5 = server5.addr[1]

clients5 = []
10.times { clients5 << TCPSocket.new("::1", port5) }
wait_for_queue(10, port5)
print_results("10 connected, none accepted", port5)

accepted5 = 4.times.map { server5.accept }
sleep 0.05
print_results("4 accepted (should be queue=6, active=4)", port5)

accepted5.each(&:close)
clients5.each(&:close)
server5.close

puts "\nDone."
