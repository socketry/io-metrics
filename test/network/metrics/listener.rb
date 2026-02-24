# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"

describe IO::Metrics::Listener do
	with ".zero" do
		it "creates a zero-initialized instance" do
			listener = IO::Metrics::Listener.zero
			
			expect(listener).to have_attributes(
				queue_size: be == 0,
				active_connections: be == 0
			)
		end
	end
	
	with ".capture" do
		it "can capture listener stats" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			stats = IO::Metrics::Listener.capture
			
			expect(stats).to be_a(Hash)
		end
		
		it "can capture stats for specific addresses" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			# Try to capture stats for common ports
			stats = IO::Metrics::Listener.capture(["0.0.0.0:22", "127.0.0.1:8080"])
			
			expect(stats).to be_a(Hash)
			stats.each_value do |listener|
				expect(listener).to be_a(IO::Metrics::Listener)
				expect(listener.queue_size).to be >= 0
				expect(listener.active_connections).to be >= 0
			end
		end
		
		it "can generate json value" do
			unless IO::Metrics::Listener.supported?
				skip "Listener stats are not supported on this platform!"
			end
			
			stats = IO::Metrics::Listener.capture
			next if stats.empty?
			
			listener = stats.values.first
			json_string = listener.to_json
			json = JSON.parse(json_string)
			
			expect(json).to have_keys("queue_size", "active_connections")
			expect(json["queue_size"]).to be_a(Integer)
			expect(json["active_connections"]).to be_a(Integer)
		end
	end
end
