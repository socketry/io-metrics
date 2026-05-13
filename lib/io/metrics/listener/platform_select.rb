# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

if RUBY_PLATFORM.include?("linux")
	require_relative "platform_linux"
elsif RUBY_PLATFORM.include?("darwin")
	require_relative "darwin"
else
	require_relative "unsupported"
end
