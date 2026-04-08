#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares TCP listen-queue metrics from io-metrics and Raindrops on Linux.
#
#   cd examples/raindrops && bundle install --gemfile=gems.rb && ruby compare.rb
#
# Set BUNDLE_GEMFILE if you run the script from another directory:
#   BUNDLE_GEMFILE=examples/raindrops/gems.rb bundle exec ruby examples/raindrops/compare.rb
#
# Both use kernel TCP stats (Raindrops via inet_diag; io-metrics via /proc/net/tcp).
# Queued ≈ accept backlog; active ≈ established connections attributed to the listener.

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

def sample_listener_metrics(address)
	metrics_listener = IO::Metrics::Listener.capture(addresses: [address])&.find do |listener|
		next false unless listener.address.ipv4?
		
		"#{listener.address.ip_address}:#{listener.address.ip_port}" == address
	end
	
	raindrops_by_address = Raindrops::Linux.tcp_listener_stats([address])
	raindrops_stats = raindrops_by_address[address] ||
		raindrops_by_address.find { |listener_address, _| listener_address.to_s.downcase == address.downcase }&.last
	
	{
		metrics_queued: metrics_listener&.queue_size,
		metrics_active: metrics_listener&.active_connections,
		raindrops_queued: raindrops_stats&.queued,
		raindrops_active: raindrops_stats&.active,
	}
end

n = 10
server = TCPServer.new("127.0.0.1", 0)
server.listen([n, Socket::SOMAXCONN].min)
port = server.addr[1]
address = "127.0.0.1:#{port}"
clients = []
mutex = Mutex.new
accepted = []

begin
	puts "Listener #{address}"
	puts format(
		"%-20s %16s %16s | %16s %16s",
		"",
		"metrics_queue",
		"metrics_active",
		"raindrops_queue",
		"raindrops_active"
	)
	
	baseline = sample_listener_metrics(address)
	puts format(
		"%-20s %16s %16s | %16s %16s",
		"idle",
		baseline[:metrics_queued].inspect,
		baseline[:metrics_active].inspect,
		baseline[:raindrops_queued].inspect,
		baseline[:raindrops_active].inspect
	)
	
	threads = n.times.map do
		Thread.new do
			client_socket = TCPSocket.new("127.0.0.1", port)
			mutex.synchronize { clients << client_socket }
		end
	end
	threads.each(&:join)
	
	deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
	peak_connected = nil
	loop do
		peak_connected = sample_listener_metrics(address)
		break if peak_connected[:metrics_queued].to_i >= n && peak_connected[:raindrops_queued].to_i >= n
		
		raise "timeout waiting for both backends to report #{n} queued" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
		
		sleep 0.02
	end
	
	puts format(
		"%-20s %16s %16s | %16s %16s",
		"#{n} connected",
		peak_connected[:metrics_queued].inspect,
		peak_connected[:metrics_active].inspect,
		peak_connected[:raindrops_queued].inspect,
		peak_connected[:raindrops_active].inspect
	)
	
	accept_count = 4
	accepted = accept_count.times.map { server.accept }
	
	sleep 0.05
	after_accept = sample_listener_metrics(address)
	puts format(
		"%-20s %16s %16s | %16s %16s",
		"accepted #{accept_count}",
		after_accept[:metrics_queued].inspect,
		after_accept[:metrics_active].inspect,
		after_accept[:raindrops_queued].inspect,
		after_accept[:raindrops_active].inspect
	)
	
	accepted.each(&:close)
	clients.each(&:close)
	clients.clear
	
	sleep 0.05
	cleared = sample_listener_metrics(address)
	puts format(
		"%-20s %16s %16s | %16s %16s",
		"all closed",
		cleared[:metrics_queued].inspect,
		cleared[:metrics_active].inspect,
		cleared[:raindrops_queued].inspect,
		cleared[:raindrops_active].inspect
	)
	
	metrics_queue_at_peak = peak_connected[:metrics_queued].to_i
	raindrops_queue_at_peak = peak_connected[:raindrops_queued].to_i
	if metrics_queue_at_peak == raindrops_queue_at_peak
		puts "\nQueued counts match at peak (#{metrics_queue_at_peak})."
	else
		puts "\nQueued mismatch at peak: io-metrics=#{metrics_queue_at_peak} raindrops=#{raindrops_queue_at_peak} (investigate dual-stack aggregation or timing)."
	end
ensure
	accepted.each(&:close) rescue nil
	clients.each(&:close) rescue nil
	server.close rescue nil
end
