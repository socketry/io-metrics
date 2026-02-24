# Getting Started

This guide explains how to use `io-metrics` to capture listener queue statistics from the host operating system.

## Installation

Add the gem to your project:

~~~ bash
$ bundle add io-metrics
~~~

## Capturing Listener Statistics

To capture socket listener statistics, use `IO::Metrics::Listener.capture`. On unsupported platforms, `supported?` returns false, so it's good practice to check first:

~~~ ruby
require "io/metrics"

if IO::Metrics::Listener.supported?
	# Capture stats for all listening sockets
	listeners = IO::Metrics::Listener.capture
	
	listeners.each do |address, listener|
		puts "#{address}: queue_size=#{listener.queue_size}, active=#{listener.active_connections}"
	end
end
~~~

## Filtering by Address

You can limit captures to specific TCP addresses:

~~~ ruby
require "io/metrics"

listeners = IO::Metrics::Listener.capture(addresses: ["0.0.0.0:80", "127.0.0.1:8080"])
~~~

## Capturing Unix Domain Sockets

Unix domain socket paths can be captured alongside or instead of TCP addresses:

~~~ ruby
require "io/metrics"

# Only Unix sockets
listeners = IO::Metrics::Listener.capture(paths: ["/tmp/socket.sock"])

# Both TCP and Unix sockets together
listeners = IO::Metrics::Listener.capture(addresses: ["0.0.0.0:80"], paths: ["/tmp/socket.sock"])
~~~

## Metrics

Each `IO::Metrics::Listener` value provides:

- `queue_size`: Number of connections waiting to be accepted (the listen backlog).
- `active_connections`: Number of active established connections to this listener.
