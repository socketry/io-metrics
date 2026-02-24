# frozen_string_literal: true

require_relative "lib/io/metrics/version"

Gem::Specification.new do |spec|
	spec.name = "io-metrics"
	spec.version = IO::Metrics::VERSION
	
	spec.summary = "Extract I/O metrics from the host system."
	spec.authors = ["Samuel Williams"]
	spec.license = "MIT"
	
	spec.cert_chain  = ["release.cert"]
	spec.signing_key = File.expand_path("~/.gem/release.pem")
	
	spec.homepage = "https://github.com/socketry/io-metrics"
	
	spec.metadata = {
		"documentation_uri" => "https://socketry.github.io/io-metrics/",
		"funding_uri" => "https://github.com/sponsors/ioquatix",
		"source_code_uri" => "https://github.com/socketry/io-metrics.git",
	}
	
	spec.files = Dir.glob(["{lib}/**/*", "*.md"], File::FNM_DOTMATCH, base: __dir__)
	
	spec.required_ruby_version = ">= 3.2"
	
	spec.add_dependency "console", "~> 1.8"
	spec.add_dependency "json", "~> 2"
end
