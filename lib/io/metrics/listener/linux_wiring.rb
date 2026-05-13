# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

if IO::Metrics::Listener::Linux.supported?
	class << IO::Metrics::Listener
		# Whether listener capture is supported on this platform.
		# @returns [Boolean] True if /proc/net/tcp is readable.
		def supported?
			true
		end
		
		# Capture listener listeners for the given address(es).
		# @parameter addresses [Array(String) | Nil] TCP address(es) to capture, e.g. ["0.0.0.0:80"]. If nil, captures all listening TCP sockets.
		# @parameter paths [Array(String) | Nil] Unix socket path(s) to capture. If nil and addresses is nil, captures all. If nil but addresses specified, captures none.
		# @returns [Array(Listener) | Nil] Captured listeners, or nil if not supported.
		def capture(**options)
			IO::Metrics::Listener::Linux.capture(**options)
		end
	end
end
