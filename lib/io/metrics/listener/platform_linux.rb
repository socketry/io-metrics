# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

begin
	require_relative "native"
rescue LoadError
	require_relative "linux"
	require_relative "linux_wiring"
end
