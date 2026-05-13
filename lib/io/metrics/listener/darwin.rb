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
			# @parameter address [String] Address string from netstat, e.g. "127.0.0.1.50876", "*.63703",
			#   "[::1].8080", or "::1.8080" (bare IPv6, no brackets, as macOS netstat outputs).
			# @returns [Addrinfo | Nil] Addrinfo for the listener, or nil if the line cannot be parsed.
			def self.parse_address(address)
				# Handle wildcard addresses: *.port -> 0.0.0.0:port
				if address.start_with?("*.")
					port = address[2..-1].to_i
					return Addrinfo.tcp("0.0.0.0", port)
				end
				
				# Handle bracketed IPv6: [::1].8080, [fe80::1%lo0].8080, [::].8080
				if address =~ /\A\[([^\]]+)\]\.(\d+)\z/
					ip = $1.sub(/%.*\z/, "")  # strip zone identifier (text after `%`), e.g. `%lo0`
					port = $2.to_i
					return Addrinfo.tcp(ip, port)
				end
				
				# Split at the last dot; everything after must be a numeric port.
				# This handles both IPv4 (127.0.0.1.PORT) and bare IPv6 (::1.PORT, fe80::1%lo0.PORT).
				if (dot_index = address.rindex(".")) && address[dot_index + 1..].match?(/\A\d+\z/)
					ip = address[0, dot_index]
					port = address[dot_index + 1..].to_i
					
					if ip.include?(":")
						# IPv6: strip zone identifier (text after `%`); `fe80::1%lo0` becomes `fe80::1`
						ip = ip.sub(/%.*\z/, "")
						return Addrinfo.tcp(ip, port)
					else
						return Addrinfo.tcp(ip, port)
					end
				end
				
				nil
			end
			
			# Build a stable string key for TCP listener filter matching (same style as Linux / user filters).
			def self.tcp_listener_key(addrinfo)
				if addrinfo.ipv6?
					"[#{addrinfo.ip_address}]:#{addrinfo.ip_port}"
				else
					"#{addrinfo.ip_address}:#{addrinfo.ip_port}"
				end
			end
			
			# Parse a single netstat -L output stream and accumulate into +listeners+.
			# @parameter io [IO] Open pipe from netstat.
			# @parameter listeners [Hash] Accumulator keyed by listener address string.
			# @parameter address_filter [Set | Nil] Optional downcased address filter.
			def self.parse_netstat_output(io, listeners, address_filter)
				io.each_line do |line|
					next if line.start_with?("Current") || line.start_with?("Listen") || line.strip.empty?
					
					# Format: "queue_length/incomplete_queue_length/maximum_queue_length    Local Address"
					fields = line.split(/\s+/)
					next if fields.size < 2
					
					queue_statistics = fields[0]
					local_address_raw = fields[1]
					
					# Parse queue statistics: "queue_length/incomplete_queue_length/maximum_queue_length"
					next unless queue_statistics =~ /^(\d+)\/(\d+)\/(\d+)$/
					queue_length = $1.to_i
					# incomplete_queue_length = $2.to_i  # incomplete connections (SYN_RECV)
					# maximum_queue_length = $3.to_i  # maximum queue size
					
					addrinfo = parse_address(local_address_raw)
					next unless addrinfo
					
					key = tcp_listener_key(addrinfo)
					next if address_filter && !address_filter.include?(key.downcase)
					
					listeners[key] ||= Listener.new(addrinfo, 0, 0, 0, 0, 0)
					# Accumulate rather than overwrite: macOS shows both IPv4 and IPv6 wildcard
					# sockets as "*.PORT", so multiple LISTEN rows can share the same key.
					listeners[key].queued_count += queue_length
					# active_count and close_wait_count are 0 (netstat -L doesn't expose connection states)
					listeners[key].active_count = 0
					listeners[key].close_wait_count = 0
				end
			end
			
			# Parse netstat -L output and extract listener statistics for IPv4 and IPv6.
			# @parameter addresses [Array(String) | Nil] Optional filter for specific addresses.
			# @returns [Array(Listener)] One entry per listening socket reported by netstat.
			def self.capture_tcp(addresses = nil)
				listeners = {}
				address_filter = addresses ? addresses.map{|address| address.downcase}.to_set : nil
				
				# A single `netstat -L -an -p tcp` invocation reports both IPv4 and IPv6
				# listeners on macOS — no separate tcp6 pass is needed.
				IO.popen([NETSTAT, "-L", "-an", "-p", "tcp"], "r") do |io|
					parse_netstat_output(io, listeners, address_filter)
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
