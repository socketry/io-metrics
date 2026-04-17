#!/usr/bin/env ruby
# frozen_string_literal: true

# Scenario 1: Long tail after response (rack.response_finished analogue)
#
# The server sends the complete HTTP response, then performs post-response work
# (analogous to Rack's rack.response_finished callbacks). The client closes the
# TCP connection as soon as it receives the full response (Connection: close).
#
# During the post-response work window:
#   - TCP state on the server side: CLOSE_WAIT (client sent FIN, server hasn't closed yet)
#   - Raindrops active: 0  ← not ESTABLISHED, so not counted
#   - io-metrics active_connections: 0  ← same reason
#   - Logical requests in flight: 1  ← application is still "finishing" the request
#
# This is the first plausible reason why kernel TCP metrics undercount true
# application load relative to a framework-level requests_active counter.
#
# Usage (Linux only):
#   cd examples/raindrops && bundle install --gemfile=gems.rb && ruby tail_after_response.rb

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("gems.rb", __dir__)
require "bundler/setup"
require "io/metrics"
require "raindrops"
require "socket"

unless RUBY_PLATFORM.include?("linux")
  abort "This example is Linux-only (inet_diag + /proc/net/tcp)."
end

POST_RESPONSE_WORK_SECONDS = 2

# Counts current ESTABLISHED connections on the given port from both libraries.
def snapshot(port)
  all_metrics   = IO::Metrics::Listener.capture || []
  metrics_entry = all_metrics.find { |l| l.address.ip? && l.address.ip_port == port }

  raindrops_all   = Raindrops::Linux.tcp_listener_stats(nil)
  raindrops_entry = raindrops_all.find { |k, _| k.to_s.end_with?(":#{port}") }&.last

  {
    metrics_active:    metrics_entry&.active_connections.to_i,
    metrics_queued:    metrics_entry&.queue_size.to_i,
    raindrops_active:  raindrops_entry&.active.to_i,
    raindrops_queued:  raindrops_entry&.queued.to_i,
  }
end

def print_snapshot(label, snap, logical_active:)
  puts "  #{label}"
  puts "    logical requests_active : #{logical_active}"
  puts "    io-metrics active       : #{snap[:metrics_active]}"
  puts "    raindrops  active       : #{snap[:raindrops_active]}"
  puts
end

# Synchronisation between server thread and main thread.
response_sent  = Queue.new  # server pushes when response is fully sent
work_done      = Queue.new  # server pushes when post-response work is done
logical_active = 0
logical_mu     = Mutex.new

server = TCPServer.new("127.0.0.1", 0)
port   = server.addr[1]
puts "Listening on 127.0.0.1:#{port}"
puts

server_thread = Thread.new do
  conn = server.accept

  # Read the full HTTP request (stop at blank line).
  loop do
    line = conn.gets
    break if line.nil? || line.chomp.empty?
  end

  # Mark request as active (equivalent to requests_active increment).
  logical_mu.synchronize { logical_active += 1 }

  # Send a complete HTTP/1.0 response with Connection: close.
  body = "hello\n"
  conn.write(
    "HTTP/1.0 200 OK\r\n" \
    "Content-Length: #{body.bytesize}\r\n" \
    "Connection: close\r\n" \
    "\r\n" +
    body
  )

  # Response is fully sent. Signal main thread to measure.
  # The client will close the TCP connection upon receiving this — moving
  # the server-side socket from ESTABLISHED → CLOSE_WAIT.
  response_sent.push(true)

  # Simulate rack.response_finished work (logging, metrics flush, etc.).
  sleep POST_RESPONSE_WORK_SECONDS

  # Request logically complete.
  logical_mu.synchronize { logical_active -= 1 }
  work_done.push(true)

  conn.close
end

client_thread = Thread.new do
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write("GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  # Parse response headers to find Content-Length so we can close as soon as
  # the body is received — without waiting for the server to close (EOF).
  content_length = 0
  loop do
    line = sock.gets("\r\n")
    break if line.nil? || line.chomp.empty?
    content_length = $1.to_i if line =~ /\AContent-Length:\s*(\d+)/i
  end
  sock.read(content_length) if content_length > 0

  # Full response received. Close immediately — sends FIN to server, moving
  # the server-side socket from ESTABLISHED → CLOSE_WAIT.
  sock.close
end

# Wait until the response has been sent and the client has (likely) closed.
response_sent.pop
sleep 0.1  # give the client FIN time to arrive

puts "=== During post-response work (rack.response_finished analogue) ==="
puts "    Server socket is in CLOSE_WAIT; logically the request is still active."
puts
print_snapshot(
  "snapshot",
  snapshot(port),
  logical_active: logical_mu.synchronize { logical_active },
)

puts "Waiting for post-response work to finish..."
work_done.pop
sleep 0.05

puts "=== After post-response work completed ==="
print_snapshot(
  "snapshot",
  snapshot(port),
  logical_active: logical_mu.synchronize { logical_active },
)

server_thread.join
client_thread.join
server.close

puts "Done. During the #{POST_RESPONSE_WORK_SECONDS}s post-response window:"
puts "  logical_active was 1 (request still in flight)"
puts "  Raindrops and io-metrics both reported 0 (TCP was CLOSE_WAIT, not ESTABLISHED)"
