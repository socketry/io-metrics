# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "json"

class IO
	module Metrics
		# Represents a network listener socket with its queue statistics.
		# @attribute address [Addrinfo | Nil] Listening endpoint from capture; nil only for {Listener.zero} placeholders.
		# @attribute queued_count [Integer] Number of connections waiting to be accepted (currently in the accept queue).
		# @attribute active_count [Integer] Number of accepted connections in ESTABLISHED state.
		# @attribute close_wait_count [Integer] Number of accepted connections in CLOSE_WAIT state (peer has closed; application still processing).
		class Listener < Struct.new(:address, :queued_count, :active_count, :close_wait_count)
			# Serialize for JSON; address uses Addrinfo#inspect_sockaddr.
			def as_json(*)
				{
					address: address&.inspect_sockaddr,
					queued_count: queued_count,
					active_count: active_count,
					close_wait_count: close_wait_count,
				}
			end
			
			# Convert the object to a JSON string.
			def to_json(*arguments)
				as_json.to_json(*arguments)
			end
			
			# Create a zero-initialized Listener instance (no endpoint; for tests or templates).
			# @returns [Listener] Counters zero; {#address} is nil.
			def self.zero
				new(nil, 0, 0, 0)  # address, queued_count, active_count, close_wait_count
			end
			
			# Whether listener stats can be captured on this system.
			def self.supported?
				false
			end
			
			# Capture listener stats for the given address(es).
			# @parameter addresses [Array(String) | Nil] TCP address(es) to capture, e.g. ["0.0.0.0:80"]. If nil, captures all listening TCP sockets.
			# @parameter paths [Array(String) | Nil] Unix socket path(s) to capture. If nil and addresses is nil, captures all. If nil but addresses specified, captures none.
			# @returns [Array(Listener) | Nil] Captured listeners, or nil if not supported.
			def self.capture(**options)
				return nil
			end
		end
	end
end

if RUBY_PLATFORM.include?("linux")
	require_relative "listener/linux"
elsif RUBY_PLATFORM.include?("darwin")
	require_relative "listener/darwin"
end
