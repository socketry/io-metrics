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
		# @attribute close_wait_count [Integer] Number of connections in CLOSE_WAIT state (peer has closed; application still holds the socket).
		# @attribute fin_wait_count [Integer] Number of connections in FIN_WAIT1 or FIN_WAIT2 state (server has initiated close; peer has not yet completed close).
		# @attribute time_wait_count [Integer] Number of connections in TIME_WAIT state (both sides closed; waiting ~60s for delayed packets before releasing the port or file descriptor).
		class Listener < Struct.new(:address, :queued_count, :active_count, :close_wait_count, :fin_wait_count, :time_wait_count)
			# Serialization for JSON; address uses Addrinfo#inspect_sockaddr.
			def as_json(*)
				{
					address: address&.inspect_sockaddr,
					queued_count: queued_count,
					active_count: active_count,
					close_wait_count: close_wait_count,
					fin_wait_count: fin_wait_count,
					time_wait_count: time_wait_count,
				}
			end
			
			# Convert the object to a JSON string.
			def to_json(*arguments)
				as_json.to_json(*arguments)
			end
			
			# Create a zero-initialized Listener instance (no endpoint; for tests or templates).
			# @returns [Listener] Counters zero; {#address} is nil.
			def self.zero
				new(nil, 0, 0, 0, 0, 0)
			end
		end
	end
end

require_relative "listener/platform_select"
