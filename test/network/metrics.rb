# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"

describe IO::Metrics do
	it "has a version number" do
		expect(IO::Metrics::VERSION).to be =~ /\A\d+\.\d+\.\d+\Z/
	end
end
