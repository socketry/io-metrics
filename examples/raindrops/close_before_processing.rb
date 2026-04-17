#!/usr/bin/env ruby
# frozen_string_literal: true

# Scenario 2: Client closes connection before server finishes processing
#
# The client sends the full HTTP request, then immediately closes the TCP
# connection (or shuts down its write side). The server is left holding a
# socket in CLOSE_WAIT while it does the actual work (simulating a slow
# database query, downstream API call, etc.).
#
# During the processing window:
#   - TCP state on the server side: CLOSE_WAIT (client sent FIN before response)
#   - Raindrops active: 0  ← not ESTABLISHED, so not counted
#   - io-metrics active_connections: 0  ← same reason
#   - Logical requests in flight: 1  ← server is processing the request
#
# This models a proxy/load balancer that drops the upstream connection as soon
# as it has buffered the request body and forwarded it — the originating TCP
# connection is gone but the work is still in progress.
#
# Usage (Linux only):
#   cd examples/raindrops && bundle install --gemfile=gems.rb && ruby close_before_processing.rb

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("gems.rb", __dir__)
require "bundler/setup"
require "io/metrics"
require "raindrops"
require "socket"

unless RUBY_PLATFORM.include?("linux")
  abort "This example is Linux-only (inet_diag + /proc/net/tcp)."
end

PROCESSING_SECONDS = 2

def snapshot(port)
  all_metrics   = IO::Metrics::Listener.capture || []
  metrics_entry = all_metrics.find { |l| l.address.ip? && l.address.ip_port == port }

  raindrops_all   = Raindrops::Linux.tcp_listener_stats(nil)
  raindrops_entry = raindrops_all.find { |k, _| k.to_s.end_with?(":#{port}") }&.last

  {
    metrics_active:   metrics_entry&.active_connections.to_i,
    metrics_queued:   metrics_entry&.queue_size.to_i,
    raindrops_active: raindrops_entry&.active.to_i,
    raindrops_queued: raindrops_entry&.queued.to_i,
  }
end

def print_snapshot(label, snap, logical_active:)
  puts "  #{label}"
  puts "    logical requests_active : #{logical_active}"
  puts "    io-metrics active       : #{snap[:metrics_active]}"
  puts "    raindrops  active       : #{snap[:raindrops_active]}"
  puts
end

processing_started = Queue.new
processing_done    = Queue.new
logical_active     = 0
logical_mu         = Mutex.new

server = TCPServer.new("127.0.0.1", 0)
port   = server.addr[1]
puts "Listening on 127.0.0.1:#{port}"
puts

server_thread = Thread.new do
  conn = server.accept

  # Read the full HTTP request.
  loop do
    line = conn.gets
    break if line.nil? || line.chomp.empty?
  end

  # Request received. Mark as logically active and signal main thread.
  # At this point the client has already closed — the server socket is
  # in CLOSE_WAIT.
  logical_mu.synchronize { logical_active += 1 }
  processing_started.push(true)

  # Simulate slow processing (DB query, downstream call, etc.).
  sleep PROCESSING_SECONDS

  logical_mu.synchronize { logical_active -= 1 }
  processing_done.push(true)

  # Send the response (client may already be gone — swallow the error).
  begin
    conn.write(
      "HTTP/1.0 200 OK\r\n" \
      "Content-Length: 6\r\n" \
      "Connection: close\r\n" \
      "\r\ndone\r\n"
    )
  rescue Errno::EPIPE, Errno::ECONNRESET
    # Client already closed — expected in this scenario.
  end

  conn.close
end

client_thread = Thread.new do
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write("GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  # Shut down the write side immediately after sending the request.
  # This sends FIN to the server, moving the server socket to CLOSE_WAIT,
  # while the server hasn't even started processing yet.
  sock.shutdown(Socket::SHUT_WR)

  # Optionally drain any response (may or may not arrive before we close).
  begin
    sock.read
  rescue Errno::ECONNRESET
    # Fine — server may send RST if it errors.
  ensure
    sock.close
  end
end

# Wait until the server has received the request and started processing.
processing_started.pop
sleep 0.1  # let the client's FIN propagate

puts "=== During request processing (client already closed) ==="
puts "    Server socket is in CLOSE_WAIT; request is being processed."
puts
print_snapshot(
  "snapshot",
  snapshot(port),
  logical_active: logical_mu.synchronize { logical_active },
)

puts "Waiting for processing to finish..."
processing_done.pop
sleep 0.05

puts "=== After processing completed ==="
print_snapshot(
  "snapshot",
  snapshot(port),
  logical_active: logical_mu.synchronize { logical_active },
)

server_thread.join
client_thread.join
server.close

puts "Done. During the #{PROCESSING_SECONDS}s processing window:"
puts "  logical_active was 1 (request in flight)"
puts "  Raindrops and io-metrics both reported 0 (TCP was CLOSE_WAIT, not ESTABLISHED)"
