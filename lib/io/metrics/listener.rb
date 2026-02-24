# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "json"

class IO
	module Metrics
		# Represents a network listener socket with its queue statistics.
		# @attribute queue_size [Integer] Number of connections waiting to be accepted (queued).
		# @attribute active_connections [Integer] Number of active connections (already accepted).
		class Listener < Struct.new(:queue_size, :active_connections)
			alias as_json to_h
			
			# Convert the object to a JSON string.
			def to_json(*arguments)
				as_json.to_json(*arguments)
			end
			
			# Create a zero-initialized Listener instance.
			# @returns [Listener] A new Listener object with all fields set to zero.
			def self.zero
				self.new(0, 0)
			end
			
			# Whether listener stats can be captured on this system.
			def self.supported?
				false
			end
			
			# Capture listener stats for the given address(es).
			# @parameter addresses [String | Array<String> | Nil] Address(es) to capture stats for, e.g. "0.0.0.0:80" or ["127.0.0.1:8080"]. If nil, captures all listening sockets.
			# @returns [Hash(String, Listener) | Nil] A hash mapping addresses to Listener, or nil if not supported.
			def self.capture(addresses = nil)
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
