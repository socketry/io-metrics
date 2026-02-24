# IO::Metrics

Extract I/O metrics from the host system, specifically listen queue statistics.

[![Development Status](https://github.com/socketry/io-metrics/workflows/Test/badge.svg)](https://github.com/socketry/io-metrics/actions?workflow=Test)

## Usage

``` ruby
require "io/metrics"

# Check if supported on this platform
if IO::Metrics::Listener.supported?
	# Capture stats for all listening sockets
	listeners = IO::Metrics::Listener.capture
	
	listeners.each do |address, listener|
		puts "#{address}: queue_size=#{listener.queue_size}, active=#{listener.active_connections}"
	end
	
	# Capture stats for specific addresses
	listeners = IO::Metrics::Listener.capture(["0.0.0.0:80", "127.0.0.1:8080"])
	
	# Capture Unix domain socket stats
	listeners = IO::Metrics::Listener.capture(paths: ["/tmp/socket.sock"])
end
```

## Platform Support

  - **Linux**: Full support via `/proc/net/tcp`, `/proc/net/tcp6` (IPv4 and IPv6), and `/proc/net/unix`
  - **macOS**: TCP listener support via `netstat -L` (Unix sockets not supported)

## Metrics

### Listener

  - `queue_size`: Number of connections waiting to be accepted (queued)
  - `active_connections`: Number of active connections (computed by matching ESTABLISHED connections to listeners by address and port)

## Design

This gem is designed to replace raindrops with a simpler interface. It focuses on extracting queue size metrics from the OS, which is the primary use case for monitoring server load.

Unlike raindrops which uses netlink/inet\_diag for efficient TCP statistics, this implementation reads from `/proc/net/tcp` for simplicity. This means:

  - Queue size is accurately reported for listening sockets
  - Active connection counts are not available without netlink (set to 0)
  - Queue latency is not available from `/proc` (would require additional instrumentation)

## Contributing

We welcome contributions to this project.

1.  Fork it.
2.  Create your feature branch (`git checkout -b my-new-feature`).
3.  Commit your changes (`git commit -am 'Add some feature'`).
4.  Push to the branch (`git push origin my-new-feature`).
5.  Create new Pull Request.

### Developer Certificate of Origin

In order to protect users of this project, we require all contributors to comply with the [Developer Certificate of Origin](https://developercertificate.org/). This ensures that all contributions are properly licensed and attributed.

### Community Guidelines

This project is best served by a collaborative and respectful environment. Treat each other professionally, respect differing viewpoints, and engage constructively. Harassment, discrimination, or harmful behavior is not tolerated. Communicate clearly, listen actively, and support one another. If any issues arise, please inform the project maintainers.
