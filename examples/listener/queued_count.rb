#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic script to confirm io-metrics queued_count is not double-counting
# under various listener configurations (IPv4, IPv6, dual-stack, SO_REUSEPORT).
#
# Run on Linux:
#   ruby examples/listener/queued_count.rb
#
# Each scenario:
#  1. Creates one or more listening sockets.
#  2. Fills the accept queue with N connections (without accept()-ing them).
#  3. Captures io-metrics and checks the total queued_count.
#  4. Reports PASS / FAIL and shows per-listener detail.
#
# If double-counting is present (e.g. a connection appears in both /proc/net/tcp
# and /proc/net/tcp6), the reported queued_count will be 2× the expected value.

require "socket"
require_relative "../../lib/io/metrics"

unless IO::Metrics::Listener.supported?
	abort "io-metrics listener capture not supported (/proc/net/tcp not readable)."
end

BASE_PORT  = 19_292
QUEUE_SIZE = 5   # small backlog so the queue fills quickly

# ─── Helpers ────────────────────────────────────────────────────────────────

def ipv4_server(port, backlog: QUEUE_SIZE)
	s = Socket.new(:INET, :STREAM)
	s.setsockopt(:SOCKET, :REUSEADDR, true)
	s.bind(Socket.sockaddr_in(port, "0.0.0.0"))
	s.listen(backlog)
	s
end

def ipv6_server(port, backlog: QUEUE_SIZE, v6only: true)
	s = Socket.new(:INET6, :STREAM)
	s.setsockopt(:SOCKET, :REUSEADDR, true)
	s.setsockopt(:IPV6, :V6ONLY, v6only ? 1 : 0)
	s.bind(Addrinfo.tcp("::", port).to_sockaddr)
	s.listen(backlog)
	s
rescue => error
	warn "  (IPv6 unavailable: #{error.message})"
	nil
end

def queue_connections(host, port, count)
	count.times.map do
		family = host.include?(":") ? :INET6 : :INET
		s = Socket.new(family, :STREAM)
		begin
			s.connect_nonblock(Addrinfo.tcp(host, port).to_sockaddr)
		rescue IO::WaitWritable, Errno::EINPROGRESS
			# expected for non-blocking connect
		rescue Errno::ECONNREFUSED, Errno::ECONNRESET
			# queue full; connection still attempted
		end
		s
	end
end

def captured_for_port(port)
	listeners = IO::Metrics::Listener.capture
	return [] unless listeners
	listeners.select do |l|
		l.address&.ip_port == port
	rescue
		false
	end
end

def check(scenario, port, expected_queued)
	listeners = captured_for_port(port)
	total = listeners.sum(&:queued_count)
	
	if total == expected_queued
		status = "PASS"
	elsif total == expected_queued * 2
		status = "FAIL — 2× double-count (#{total} instead of #{expected_queued})"
	else
		status = "FAIL — got #{total}, expected #{expected_queued}"
	end
	
	puts "  #{status}"
	listeners.each do |l|
		addr = l.address&.inspect_sockaddr || "unknown"
		puts "    #{addr}: queued=#{l.queued_count} active=#{l.active_count}"
	end
	puts "    Total queued_count across all listeners on port #{port}: #{total}"
end

# ─── Scenario 1: Single IPv4 listener ───────────────────────────────────────
# Baseline: bind 0.0.0.0:PORT, queue QUEUE_SIZE connections, expect QUEUE_SIZE.
# Double-counting would appear if the same connections were visible in both
# /proc/net/tcp and /proc/net/tcp6.

port = BASE_PORT
puts "\n── Scenario 1: single IPv4 listener (0.0.0.0:#{port}) ──────────────"
puts "  Queueing #{QUEUE_SIZE} IPv4 connections without accept()."
puts "  Expected queued_count = #{QUEUE_SIZE}"

server = ipv4_server(port)
clients = queue_connections("127.0.0.1", port, QUEUE_SIZE)
sleep 0.05
check("IPv4 only", port, QUEUE_SIZE)
clients.each(&:close)
server.close

# ─── Scenario 2: Single IPv6 listener (IPV6_V6ONLY=1) ──────────────────────
# IPv6 socket accepts only pure IPv6 connections.  Connections should not
# appear in /proc/net/tcp (IPv4), so no double-count is possible.

port = BASE_PORT + 1
puts "\n── Scenario 2: IPv6 listener with IPV6_V6ONLY=1 ([::]:#{port}) ──────"
puts "  Queueing #{QUEUE_SIZE} IPv6 connections without accept()."
puts "  Expected queued_count = #{QUEUE_SIZE}"

server = ipv6_server(port, v6only: true)
if server
	clients = queue_connections("::1", port, QUEUE_SIZE)
	sleep 0.05
	check("IPv6 IPV6_V6ONLY=1", port, QUEUE_SIZE)
	clients.each(&:close)
	server.close
else
	puts "  Skipped."
end

# ─── Scenario 3: IPv6 listener with IPV6_V6ONLY=0 ──────────────────────────
# With IPV6_V6ONLY=0 the IPv6 socket also accepts IPv4-mapped connections
# (::ffff:127.0.0.1).  Those connections appear in /proc/net/tcp6 only —
# NOT in /proc/net/tcp — so io-metrics should still report the correct count.
# Double-counting would show 2× here if io-metrics were reading both files
# for the same socket.

port = BASE_PORT + 2
puts "\n── Scenario 3: IPv6 listener with IPV6_V6ONLY=0 ([::]:#{port}) ──────"
puts "  Queueing #{QUEUE_SIZE} IPv4 connections (appear as ::ffff:127.0.0.1 in tcp6)."
puts "  Expected queued_count = #{QUEUE_SIZE} (not 2×)"

server = ipv6_server(port, v6only: false)
if server
	clients = queue_connections("127.0.0.1", port, QUEUE_SIZE)
	sleep 0.05
	check("IPv6 IPV6_V6ONLY=0 + IPv4 clients", port, QUEUE_SIZE)
	clients.each(&:close)
	server.close
else
	puts "  Skipped."
end

# ─── Scenario 4: Dual-stack — separate IPv4 and IPv6 sockets on same port ──
# Falcon could bind to BOTH 0.0.0.0:PORT (IPv4) and [::]:PORT (IPv6).
# io-metrics should see two distinct listener entries and sum their queued counts.
# With QUEUE_SIZE connections on each, expected total = 2 × QUEUE_SIZE.
# Double-counting would show 4× (each connection counted twice).

port = BASE_PORT + 3
puts "\n── Scenario 4: dual-stack — 0.0.0.0 + [::] on port #{port} ──────────"
puts "  Queueing #{QUEUE_SIZE} IPv4 + #{QUEUE_SIZE} IPv6 connections."
puts "  Expected queued_count = #{QUEUE_SIZE * 2} (one entry per stack, no double-count)"
puts "  Double-count would show #{QUEUE_SIZE * 4}"

s4 = ipv4_server(port, backlog: QUEUE_SIZE * 2)
s6 = ipv6_server(port, backlog: QUEUE_SIZE * 2, v6only: true)

if s6
	clients4 = queue_connections("127.0.0.1", port, QUEUE_SIZE)
	clients6 = queue_connections("::1", port, QUEUE_SIZE)
	sleep 0.05
	# Expected total is always QUEUE_SIZE * 2 regardless of how many listener
	# entries io-metrics returns:
	#   Linux  — two separate entries (0.0.0.0:PORT and [::]:PORT).
	#   macOS  — both wildcards appear as "*.PORT" and are merged into one
	#             0.0.0.0:PORT entry; queued_count is their accumulated sum.
	# Double-counting would produce QUEUE_SIZE * 4.
	check("dual-stack IPv4+IPv6", port, QUEUE_SIZE * 2)
	clients4.each(&:close)
	clients6.each(&:close)
	s6.close
else
	puts "  Skipped (IPv6 unavailable)."
end
s4.close

# ─── Scenario 5: SO_REUSEPORT — two workers sharing one IPv4 port ───────────
# With SO_REUSEPORT the kernel distributes incoming connections across sockets.
# /proc/net/tcp shows one LISTEN row per socket, each with its own rx_queue.
# io-metrics accumulates these, so total should equal the number of queued
# connections — not N_workers × queued.

port = BASE_PORT + 4
puts "\n── Scenario 5: SO_REUSEPORT — 2 workers on 0.0.0.0:#{port} ──────────"
puts "  Queueing #{QUEUE_SIZE} connections (distributed across 2 sockets)."
puts "  Expected queued_count = #{QUEUE_SIZE} (accumulated, not multiplied by 2)"

workers = 2.times.map do
	s = Socket.new(:INET, :STREAM)
	s.setsockopt(:SOCKET, :REUSEADDR, true)
	s.setsockopt(:SOCKET, :REUSEPORT, true)
	s.bind(Socket.sockaddr_in(port, "0.0.0.0"))
	s.listen(QUEUE_SIZE)
	s
end

clients = queue_connections("127.0.0.1", port, QUEUE_SIZE)
sleep 0.05
check("SO_REUSEPORT x2", port, QUEUE_SIZE)
clients.each(&:close)
workers.each(&:close)

puts "\nDone."
