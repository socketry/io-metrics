# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

class IO
	module Metrics
		class << Listener
			# @returns [Boolean] False on platforms without a listener capture implementation.
			def supported?
				false
			end
			
			# @returns [Nil] Listener capture is not available on this platform.
			def capture(**options)
				nil
			end
		end
	end
end
