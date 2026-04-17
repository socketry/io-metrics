# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "socket"

class IO
	module Metrics
		# Darwin (macOS) implementation of listener statistics using netstat -L.
		class Listener::Darwin
			NETSTAT = "/usr/sbin/netstat"
			
			# Whether listener listeners can be captured on this system.
			def self.supported?
				File.executable?(NETSTAT)
			end
			
			# Parse an address from netstat format to Addrinfo (TCP, numeric port).
			# @parameter address [String] Address string from netstat, e.g. "127.0.0.1.50876" or "*.63703".
			# @returns [Addrinfo | Nil] Addrinfo for the listener, or nil if the line cannot be parsed.
			def self.parse_address(address)
				# Handle wildcard addresses: *.port -> 0.0.0.0:port
				if address.start_with?("*.")
					port = address[2..-1].to_i
					return Addrinfo.tcp("0.0.0.0", port)
				end
				
				# Handle IPv4 addresses: ip.port -> ip:port
				if address =~ /^([0-9.]+)\.(\d+)$/
					ip = $1
					port = $2.to_i
					return Addrinfo.tcp(ip, port)
				end
				
				# Handle IPv6 or other formats: best-effort via Addrinfo.parse
				begin
					Addrinfo.parse(address)
				rescue ArgumentError, SocketError
					nil
				end
			end
			
			# Build a stable string key for TCP listener filter matching (same style as Linux / user filters).
			def self.tcp_listener_key(addrinfo)
				if addrinfo.ipv6?
					"[#{addrinfo.ip_address}]:#{addrinfo.ip_port}"
				else
					"#{addrinfo.ip_address}:#{addrinfo.ip_port}"
				end
			end
			
			# Parse netstat -L output and extract listener statistics.
			# @parameter addresses [Array(String) | Nil] Optional filter for specific addresses.
			# @returns [Array(Listener)] One entry per listening socket reported by netstat.
			def self.capture_tcp(addresses = nil)
				listeners = {}
				address_filter = addresses ? addresses.map{|address| address.downcase}.to_set : nil
				
				IO.popen([NETSTAT, "-L", "-an", "-p", "tcp"], "r") do |io|
					# Skip header lines
					io.each_line do |line|
						# Skip header and empty lines
						next if line.start_with?("Current") || line.start_with?("Listen") || line.strip.empty?
						
						# Format: "queue_length/incomplete_queue_length/maximum_queue_length    Local Address"
						fields = line.split(/\s+/)
						next if fields.size < 2
						
						queue_statistics = fields[0]
						local_address_raw = fields[1]
						
						# Parse queue statistics: "queue_length/incomplete_queue_length/maximum_queue_length"
						if queue_statistics =~ /^(\d+)\/(\d+)\/(\d+)$/
							queue_length = $1.to_i
							# incomplete_queue_length = $2.to_i  # incomplete connections (SYN_RECV)
							# maximum_queue_length = $3.to_i  # maximum queue size
							
							addrinfo = parse_address(local_address_raw)
							next unless addrinfo
							
							key = tcp_listener_key(addrinfo)
							# Apply filter if specified
							next if address_filter && !address_filter.include?(key.downcase)
							
							listeners[key] ||= Listener.new(addrinfo, 0, 0, 0)
							listeners[key].queued_count = queue_length
							
							# active_count and close_wait_count set to 0 (netstat -L doesn't expose connection states)
							listeners[key].active_count = 0
							listeners[key].close_wait_count = 0
						end
					end
				end
				
				return listeners.values
			rescue Errno::ENOENT, Errno::EACCES
				return []
			end
			
			# Capture listener listeners for TCP sockets.
			# @parameter addresses [Array(String) | Nil] TCP address(es) to capture, e.g. ["0.0.0.0:80"]. If nil, captures all.
			# @parameter paths [Array(String) | Nil] Unix socket path(s) to capture (not supported on Darwin).
			# @returns [Array(Listener)] TCP listeners from netstat.
			def self.capture(addresses: nil, paths: nil)
				capture_tcp(addresses)
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
		
		# Capture listener listeners for the given address(es).
		# @parameter addresses [Array(String) | Nil] TCP address(es) to capture, e.g. ["0.0.0.0:80"]. If nil, captures all listening TCP sockets.
		# @parameter paths [Array(String) | Nil] Unix socket path(s) to capture (not supported on Darwin).
		# @returns [Array(Listener) | Nil] Captured listeners, or nil if not supported.
		def capture(**options)
			IO::Metrics::Listener::Darwin.capture(**options)
		end
	end
end
