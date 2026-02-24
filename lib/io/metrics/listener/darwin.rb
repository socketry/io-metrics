# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

class IO
	module Metrics
		# Darwin (macOS) implementation of listener statistics using netstat -L.
		class Listener::Darwin
			NETSTAT = "/usr/sbin/netstat"
			
			# Whether listener stats can be captured on this system.
			def self.supported?
				File.executable?(NETSTAT)
			end
			
			# Parse an address from netstat format to "ip:port" format.
			# @parameter address [String] Address string from netstat, e.g. "127.0.0.1.50876" or "*.63703".
			# @returns [String] Address in "ip:port" format, e.g. "127.0.0.1:50876" or "0.0.0.0:63703".
			def self.parse_address(address)
				# Handle wildcard addresses: *.port -> 0.0.0.0:port
				if address.start_with?("*.")
					port = address[2..-1]
					return "0.0.0.0:#{port}"
				end
				
				# Handle IPv4 addresses: ip.port -> ip:port
				if address =~ /^([0-9.]+)\.(\d+)$/
					ip = $1
					port = $2
					return "#{ip}:#{port}"
				end
				
				# Handle IPv6 addresses (if present in future)
				# For now, return as-is
				return address
			end
			
			# Parse netstat -L output and extract listener statistics.
			# @parameter addresses [Array<String> | Nil] Optional filter for specific addresses.
			# @returns [Hash<String, Listener>] Hash mapping "ip:port" to Listener.
			def self.capture_tcp(addresses = nil)
				stats = {}
				address_filter = addresses ? addresses.map{|address| address.downcase}.to_set : nil
				
				IO.popen([NETSTAT, "-L", "-an", "-p", "tcp"], "r") do |io|
					# Skip header lines
					io.each_line do |line|
						# Skip header and empty lines
						next if line.start_with?("Current") || line.start_with?("Listen") || line.strip.empty?
						
						# Format: "qlen/incqlen/maxqlen    Local Address"
						fields = line.split(/\s+/)
						next if fields.size < 2
						
						queue_info = fields[0]
						local_addr_raw = fields[1]
						
						# Parse queue info: "qlen/incqlen/maxqlen"
						if queue_info =~ /^(\d+)\/(\d+)\/(\d+)$/
							qlen = $1.to_i
							# incqlen = $2.to_i  # incomplete connections (SYN_RECV)
							# maxqlen = $3.to_i  # max queue size
							
							# Parse address
							address = parse_address(local_addr_raw)
							
							# Apply filter if specified
							next if address_filter && !address_filter.include?(address)
							
							stats[address] ||= Listener.zero
							stats[address].queue_size = qlen
							# active_connections set to 0 (can't reliably count per listener)
							stats[address].active_connections = 0
						end
					end
				end
				
				return stats
			rescue Errno::ENOENT, Errno::EACCES
				return {}
			end
			
			# Capture listener stats for TCP sockets.
			# @parameter addresses [String | Array<String> | Nil] TCP address(es) to capture, e.g. "0.0.0.0:80" or ["127.0.0.1:8080"]. If nil, captures all.
			# @parameter paths [String | Array<String> | Nil] Unix socket path(s) to capture (not supported on Darwin).
			# @returns [Hash(String, Listener)] Hash mapping addresses to Listener.
			def self.capture(addresses: nil, paths: nil)
				stats = {}
				
				# Capture TCP stats (Unix sockets not supported on Darwin via netstat)
				stats.merge!(capture_tcp(addresses))
				
				return stats
			end
		end
	end
end

# Wire Listener.capture and Listener.supported? to this implementation on Darwin.
if IO::Metrics::Listener::Darwin.supported?
	class << IO::Metrics::Listener
		# Whether listener capture is supported on this platform.
		# @returns [Boolean] True if netstat is executable.
		def supported?
			true
		end
		
		# Capture listener stats for the given address(es).
		# @parameter addresses [Array<String> | Nil] TCP address(es) to capture, e.g. ["0.0.0.0:80"]. If nil, captures all listening TCP sockets.
		# @parameter paths [Array<String> | Nil] Unix socket path(s) to capture (not supported on Darwin).
		# @returns [Hash(String, Listener) | Nil] A hash mapping addresses to Listener, or nil if not supported.
		def capture(**options)
			IO::Metrics::Listener::Darwin.capture(**options)
		end
	end
end
