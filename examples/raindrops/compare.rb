#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares TCP listen-queue metrics from io-metrics and Raindrops on Linux.
# Uses a dual-stack listener and matches all rows by +ip_port+, logging IPv4, IPv6, and totals.
#
#   cd examples/raindrops && bundle install --gemfile=gems.rb && ruby compare.rb
#
# Set BUNDLE_GEMFILE if you run the script from another directory:
#   BUNDLE_GEMFILE=examples/raindrops/gems.rb bundle exec ruby examples/raindrops/compare.rb
#
# Both use kernel TCP stats (Raindrops via inet_diag; io-metrics via /proc/net/tcp).
# Queued ≈ accept backlog; active ≈ established connections past accept() (see io-metrics Linux impl).

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("gems.rb", __dir__)
require "bundler/setup"
require "io/metrics"
require "raindrops"
require "socket"

unless RUBY_PLATFORM.include?("linux")
	abort "This example is Linux-only (inet_diag + /proc/net/tcp)."
end

unless defined?(Raindrops::Linux.tcp_listener_stats)
	abort "Raindrops Linux extension not available (raindrops gem built without linux_inet_diag?)."
end

unless IO::Metrics::Listener.supported?
	abort "io-metrics listener capture not supported (/proc/net/tcp not readable?)."
end

def listener_display_key(listener)
	address = listener.address
	return address.unix_path if address.afamily == Socket::AF_UNIX
	
	address.ipv6? ? "[#{address.ip_address}]:#{address.ip_port}" : "#{address.ip_address}:#{address.ip_port}"
end

# Extract TCP port from Raindrops / netstat-style keys ("127.0.0.1:8080", "[::1]:8080").
def port_from_listener_key(key)
	string = key.to_s
	return Regexp.last_match(1).to_i if string.match(/\]:(\d+)\z/)
	return Regexp.last_match(1).to_i if string.match(/:(\d+)\z/)
	
	nil
end

def raindrops_lookup(raindrops_by_address, display_key)
	raindrops_by_address[display_key] ||
		raindrops_by_address.find { |listener_key, _| listener_key.to_s.downcase == display_key.downcase }&.last
end

# Snapshot all TCP listeners on +port+ from both libraries (full capture + all tcp_listener_stats).
def sample_by_port(port)
	all_metrics = IO::Metrics::Listener.capture || []
	tcp_on_port = all_metrics.select do |listener|
		address = listener.address
		next false if address.afamily == Socket::AF_UNIX
		
		address.ip_port == port
	end
	
	raindrops_all = Raindrops::Linux.tcp_listener_stats(nil)
	raindrops_on_port = raindrops_all.select do |listener_key, _|
		port_from_listener_key(listener_key) == port
	end
	
	ipv4_metrics = tcp_on_port.select(&:ipv4?)
	ipv6_metrics = tcp_on_port.select(&:ipv6?)
	
	raindrops_ipv4 = raindrops_on_port.reject { |listener_key, _| listener_key.to_s.start_with?("[") }
	raindrops_ipv6 = raindrops_on_port.select { |listener_key, _| listener_key.to_s.start_with?("[") }
	
	combined = {
		metrics_queued: tcp_on_port.sum(&:queue_size),
		metrics_active: tcp_on_port.sum(&:active_connections),
		raindrops_queued: raindrops_on_port.values.sum(&:queued),
		raindrops_active: raindrops_on_port.values.sum(&:active),
	}
	
	subtotal = lambda do |metrics_rows, raindrops_pairs|
		rd_hash = raindrops_pairs.to_h
		{
			metrics_queued: metrics_rows.sum(&:queue_size),
			metrics_active: metrics_rows.sum(&:active_connections),
			raindrops_queued: rd_hash.values.sum(&:queued),
			raindrops_active: rd_hash.values.sum(&:active),
		}
	end
	
	{
		port: port,
		ipv4_metrics: ipv4_metrics,
		ipv6_metrics: ipv6_metrics,
		raindrops_ipv4: raindrops_ipv4,
		raindrops_ipv6: raindrops_ipv6,
		raindrops_all_on_port: raindrops_on_port,
		ipv4_subtotal: subtotal.call(ipv4_metrics, raindrops_ipv4),
		ipv6_subtotal: subtotal.call(ipv6_metrics, raindrops_ipv6),
		combined: combined,
	}
end

ROW_FORMAT = "%-36s %12s %12s | %12s %12s\n"

def print_metrics_table(title, snapshot)
	puts title
	printf ROW_FORMAT, "", "metrics_q", "metrics_act", "raindrops_q", "raindrops_act"
	
	rd_hash = snapshot[:raindrops_all_on_port].to_h
	
	print_rows = lambda do |label, metrics_rows|
		puts "  #{label}:"
		if metrics_rows.empty?
			puts "    (none)"
		else
			metrics_rows.each do |listener|
				key = listener_display_key(listener)
				stats = raindrops_lookup(rd_hash, key)
				printf ROW_FORMAT, "    #{key}",
					listener.queue_size,
					listener.active_connections,
					stats&.queued.inspect,
					stats&.active.inspect
			end
		end
	end
	
	print_rows.call("IPv4 listeners", snapshot[:ipv4_metrics])
	print_rows.call("IPv6 listeners", snapshot[:ipv6_metrics])
	
	ipv4 = snapshot[:ipv4_subtotal]
	ipv6 = snapshot[:ipv6_subtotal]
	combined = snapshot[:combined]
	
	printf ROW_FORMAT, "  IPv4 subtotal", ipv4[:metrics_queued], ipv4[:metrics_active], ipv4[:raindrops_queued], ipv4[:raindrops_active]
	printf ROW_FORMAT, "  IPv6 subtotal", ipv6[:metrics_queued], ipv6[:metrics_active], ipv6[:raindrops_queued], ipv6[:raindrops_active]
	printf ROW_FORMAT, "  combined (port)", combined[:metrics_queued], combined[:metrics_active], combined[:raindrops_queued], combined[:raindrops_active]
	puts
end

n_ipv4 = 5
n_ipv6 = 5
n_total = n_ipv4 + n_ipv6

server = TCPServer.new("::", 0)
if defined?(Socket::IPPROTO_IPV6) && defined?(Socket::IPV6_V6ONLY)
	begin
		server.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, [0].pack("i"))
	rescue StandardError
		# Not all platforms allow toggling; IPv6-only is still useful for the example.
	end
end
server.listen([n_total, Socket::SOMAXCONN].min)
port = server.addr[1]

clients = []
mutex = Mutex.new
accepted = []

begin
	puts "Dual-stack listener on port #{port} (IPv4 clients → 127.0.0.1, IPv6 clients → ::1)"
	puts
	
	print_metrics_table("--- idle ---", sample_by_port(port))
	
	threads = []
	n_ipv4.times do
		threads << Thread.new do
			client_socket = TCPSocket.new("127.0.0.1", port)
			mutex.synchronize { clients << client_socket }
		end
	end
	n_ipv6.times do
		threads << Thread.new do
			client_socket = TCPSocket.new("::1", port)
			mutex.synchronize { clients << client_socket }
		end
	end
	threads.each(&:join)
	
	deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
	peak_connected = nil
	loop do
		peak_connected = sample_by_port(port)
		combined = peak_connected[:combined]
		break if combined[:metrics_queued].to_i >= n_total && combined[:raindrops_queued].to_i >= n_total
		
		raise "timeout waiting for both backends to report #{n_total} queued" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
		
		sleep 0.02
	end
	
	print_metrics_table("--- #{n_total} connected (#{n_ipv4} IPv4 + #{n_ipv6} IPv6), no accept ---", peak_connected)
	
	accept_count = 4
	accepted.replace(accept_count.times.map { server.accept })
	
	sleep 0.05
	after_accept = sample_by_port(port)
	print_metrics_table("--- accepted #{accept_count} ---", after_accept)
	
	accepted.each(&:close)
	clients.each(&:close)
	clients.clear
	
	sleep 0.05
	cleared = sample_by_port(port)
	print_metrics_table("--- all clients closed ---", cleared)
	
	metrics_queue_at_peak = peak_connected[:combined][:metrics_queued].to_i
	raindrops_queue_at_peak = peak_connected[:combined][:raindrops_queued].to_i
	if metrics_queue_at_peak == raindrops_queue_at_peak
		puts "Combined queued counts match at peak (#{metrics_queue_at_peak})."
	else
		puts "Combined queued mismatch at peak: io-metrics=#{metrics_queue_at_peak} raindrops=#{raindrops_queue_at_peak}."
	end
rescue Errno::EADDRNOTAVAIL, Errno::ECONNREFUSED => error
	warn "IPv6 client connect failed (#{error.class}: #{error.message}); try a host with ::1 or adjust the script."
	raise
ensure
	accepted.each(&:close) rescue nil
	clients.each(&:close) rescue nil
	server.close rescue nil
end
