# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

# Load the pure-Ruby Linux implementation for Unix socket support and as a
# fallback if the C extension is not available.
require_relative "linux"

# Load the native C extension (netlink inet_diag). Defines
# IO::Metrics::Listener::Native with a fast TCP capture path.
require "IO_Metrics"

class IO
	module Metrics
		# Re-wire the top-level Listener.capture to prefer the native inet_diag
		# path for TCP sockets while delegating Unix sockets to the pure-Ruby
		# Linux implementation.
		class << Listener
			# Whether native listener stats can be captured on this system.
			# @returns [Boolean] True when the inet_diag C extension is loaded.
			def supported?
				IO::Metrics::Listener::Native.supported?
			end
			
			# @parameter addresses [Array(String) | Nil] TCP address filter.
			# @parameter paths [Array(String) | Nil] Unix socket path filter.
			def capture(addresses: nil, paths: nil)
				# When only Unix paths are requested, skip TCP entirely.
				tcp_skip  = addresses.nil? && !paths.nil?
				# When only TCP addresses are requested, skip Unix entirely.
				unix_skip = paths.nil? && !addresses.nil?
				
				result = []
				result.concat(IO::Metrics::Listener::Native.capture(addresses: addresses)) unless tcp_skip
				result.concat(IO::Metrics::Listener::Linux.capture_unix(paths))           unless unix_skip
				result
			end
		end
	end
end
