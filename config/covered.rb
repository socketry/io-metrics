# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

def make_policy(policy)
	super
	
	# Side-effect-only loaders and pure wiring: coverage is exercised indirectly.
	policy.skip(/listener\/platform_linux\.rb\z/)
	policy.skip(/listener\/linux_wiring\.rb\z/)
	policy.skip(/listener\/platform_select\.rb\z/)
	
	if RUBY_PLATFORM.include?("linux")
		policy.skip(/listener\/darwin\.rb\z/)
	elsif RUBY_PLATFORM.include?("darwin")
		policy.skip(/listener\/native\.rb\z/)
		policy.skip(/listener\/linux\.rb\z/)
	end
	
	if RUBY_PLATFORM.include?("linux") || RUBY_PLATFORM.include?("darwin")
		policy.skip(/listener\/unsupported\.rb\z/)
	end
end
