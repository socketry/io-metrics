# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "sus/shared"

module IO::Metrics
	LinuxContext = Sus::Shared("linux context") do
		let(:root) {File.join(__dir__, "linux")}
	end
end