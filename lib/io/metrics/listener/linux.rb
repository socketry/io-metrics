# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "set"
require "ipaddr"

class IO
	module Metrics
		# Linux implementation of listener statistics using /proc/net/tcp, /proc/net/tcp6, and /proc/net/unix.
		class Listener::Linux
			# TCP socket states (from include/net/tcp_states.h)
			TCP_ESTABLISHED = 0x01
			TCP_SYN_SENT = 0x02
			TCP_SYN_RECV = 0x03
			TCP_FIN_WAIT1 = 0x04
			TCP_FIN_WAIT2 = 0x05
			TCP_TIME_WAIT = 0x06
			TCP_CLOSE = 0x07
			TCP_CLOSE_WAIT = 0x08
			TCP_LAST_ACK = 0x09
			TCP_LISTEN = 0x0A
			TCP_CLOSING = 0x0B
			
			# Unix socket states (from include/uapi/linux/net.h)
			SS_UNCONNECTED = 0x01
			SS_CONNECTING = 0x02
			SS_CONNECTED = 0x03
			
			# Regex pattern for parsing /proc/net/tcp and /proc/net/tcp6 lines.
			# Captures: local_ip, local_port, remote_ip, remote_port, state, tx_queue, rx_queue
			TCP_LINE_PATTERN = /\A\s*\d+:\s+([0-9A-Fa-f]+):([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+):([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+)\s+([0-9A-Fa-f]+):([0-9A-Fa-f]+)/
			
			# Whether listener stats can be captured on this system.
			def self.supported?
				File.readable?("/proc/net/tcp")
			end
			
			# Parse an IPv4 address from /proc/net/tcp format (hex, little-endian).
			# @parameter hex [String] Hexadecimal address string, e.g. "0100007F" for 127.0.0.1.
			# @returns [String] IP address in dotted decimal format, e.g. "127.0.0.1".
			def self.parse_ipv4(hex)
				raise ArgumentError, "Invalid IPv4 hex format: #{hex.inspect}" unless hex =~ /\A[0-9A-Fa-f]{8}\z/
				
				# Each byte is 2 hex chars, read in reverse order (little-endian)
				bytes = hex.scan(/../).reverse.map{|b| b.to_i(16)}
				bytes.join(".")
			end
			
			# Parse an IPv6 address from /proc/net/tcp6 format (hex, little-endian).
			# @parameter hex [String] Hexadecimal address string, 32 hex chars (16 bytes).
			# @returns [String] IP address in compressed IPv6 format, e.g. "::1" or "2001:db8::1".
			def self.parse_ipv6(hex)
				raise ArgumentError, "Invalid IPv6 hex format: #{hex.inspect}" unless hex =~ /\A[0-9A-Fa-f]{32}\z/
				
				# IPv6 is 16 bytes (32 hex chars) stored as 4-byte words in little-endian format
				# Split into 4-byte words (8 hex chars each) and reverse bytes within each word
				words = hex.scan(/.{8}/)
				
				reversed_words = words.map do |word|
					word.scan(/../).reverse.join("")
				end
				
				# Convert to 16-bit segments and create colon-separated format
				segments = reversed_words.flat_map do |word|
					[word[0..3], word[4..7]]
				end
				
				ipv6_expanded = segments.join(":")
				
				# Use IPAddr to compress the address
				IPAddr.new(ipv6_expanded).to_s
			end
			
			# Parse a port from /proc/net/tcp format (hex).
			# @parameter hex [String] Hexadecimal port string, e.g. "0050" for port 80.
			# @returns [Integer] Port number.
			def self.parse_port(hex)
				hex.to_i(16)
			end
			
			# Parse a socket state from /proc/net/tcp format.
			# @parameter hex [String] Hexadecimal state string.
			# @returns [Symbol] Socket state (:listen, :established, etc.)
			def self.parse_state(hex)
				state = hex.to_i(16)
				case state
				when TCP_LISTEN then :listen
				when TCP_ESTABLISHED then :established
				when TCP_SYN_SENT then :syn_sent
				when TCP_SYN_RECV then :syn_recv
				when TCP_FIN_WAIT1 then :fin_wait1
				when TCP_FIN_WAIT2 then :fin_wait2
				when TCP_TIME_WAIT then :time_wait
				when TCP_CLOSE then :close
				when TCP_CLOSE_WAIT then :close_wait
				when TCP_LAST_ACK then :last_ack
				when TCP_CLOSING then :closing
				else :unknown
				end
			end
			
			# Find the best matching listener for an ESTABLISHED connection.
			# @parameter local_address [String] Local address in "ip:port" or "[ipv6]:port" format.
			# @parameter listeners [Hash<String, Listener>] Hash of listener addresses to Listener objects.
			# @returns [String | Nil] The address of the matching listener, or nil if no match.
			def self.find_matching_listener(local_address, listeners)
				# Try exact match first
				return local_address if listeners.key?(local_address)
				
				# Parse the address to extract IP and port
				if local_address.start_with?("[")
					# IPv6 format: [::1]:port
					if match = local_address.match(/\A\[(.+)\]:(\d+)\z/)
						local_ip = $1
						local_port = $2
					else
						return nil
					end
				else
					# IPv4 format: 127.0.0.1:port
					local_ip, local_port = local_address.split(":", 2)
					return nil unless local_port
				end
				
				# Determine address type using IPAddr for robust detection
				begin
					addr = IPAddr.new(local_ip)
					
					if addr.ipv4?
						# Try IPv4 wildcard match (0.0.0.0:port)
						wildcard_address = "0.0.0.0:#{local_port}"
						return wildcard_address if listeners.key?(wildcard_address)
					else
						# Try IPv6 wildcard match ([::]:port)
						wildcard_address = "[::]:#{local_port}"
						return wildcard_address if listeners.key?(wildcard_address)
					end
				rescue IPAddr::InvalidAddressError
					# If IP parsing fails, return nil
					return nil
				end
				
				return nil
			end
			
			# Parse /proc/net/tcp or /proc/net/tcp6 and extract listener statistics (optimized single-pass).
			# @parameter file [String] Path to /proc/net/tcp or /proc/net/tcp6.
			# @parameter addresses [Array<String> | Nil] Optional filter for specific addresses.
			# @parameter ipv6 [Boolean] Whether parsing IPv6 addresses.
			# @returns [Hash(String, Listener)] Hash mapping "ip:port" or "[ipv6]:port" to Listener.
			def self.capture_tcp_file(file, addresses = nil, ipv6: false)
				stats = {}
				address_filter = addresses ? addresses.map{|address| address.downcase}.to_set : nil
				connections = []
				
				# Single pass: collect LISTEN sockets and ESTABLISHED connections
				File.foreach(file) do |line|
					next if line.start_with?("sl")
					
					if match = TCP_LINE_PATTERN.match(line)
						local_ip_hex = match[1]
						local_port_hex = match[2]
						remote_ip_hex = match[3]
						remote_port_hex = match[4]
						state_hex = match[5]
						tx_queue_hex = match[6]
						rx_queue_hex = match[7]
						
						state = parse_state(state_hex)
						
						# Process LISTEN sockets
						if state == :listen
							if ipv6
								local_ip = parse_ipv6(local_ip_hex)
								local_address = "[#{local_ip}]:#{parse_port(local_port_hex)}"
							else
								local_ip = parse_ipv4(local_ip_hex)
								local_port = parse_port(local_port_hex)
								local_address = "#{local_ip}:#{local_port}"
							end
							
							# Apply filter if specified
							next if address_filter && !address_filter.include?(local_address)
							
							stats[local_address] ||= Listener.zero
							# rx_queue shows number of connections waiting to be accepted
							stats[local_address].queue_size = rx_queue_hex.to_i(16)
							stats[local_address].active_connections = 0
						# Collect ESTABLISHED connections to count later
						elsif state == :established
							if ipv6
								local_ip = parse_ipv6(local_ip_hex)
								local_address = "[#{local_ip}]:#{parse_port(local_port_hex)}"
							else
								local_ip = parse_ipv4(local_ip_hex)
								local_port = parse_port(local_port_hex)
								local_address = "#{local_ip}:#{local_port}"
							end
							connections << local_address
						end
					end
				end
				
				# Count ESTABLISHED connections for each listener
				connections.each do |local_address|
					if listener_address = find_matching_listener(local_address, stats)
						stats[listener_address].active_connections += 1
					end
				end
				
				return stats
			rescue Errno::ENOENT, Errno::EACCES
				return {}
			end
			
			# Parse /proc/net/unix and extract listener statistics for Unix domain sockets.
			# @parameter paths [Array<String> | Nil] Optional filter for specific socket paths.
			# @parameter file [String] Optional path to Unix socket file (defaults to "/proc/net/unix").
			# @returns [Hash(String, Listener)] Hash mapping socket path to Listener.
			def self.capture_unix(paths = nil, file: "/proc/net/unix")
				stats = {}
				path_filter = paths ? paths.to_set : nil
				
				File.foreach(file) do |line|
					line = line.strip
					next if line.start_with?("Num")
					
					# Format: Num RefCount Protocol Flags Type St Inode Path
					# Example (stripped): "00000000cf265b54: 00000003 00000000 00000000 0001 03 18324 /run/user/1000/wayland-0"
					# After splitting by whitespace:
					# [0] = "00000000cf265b54:", [1] = RefCount, [2] = Protocol, [3] = Flags, [4] = Type, [5] = St, [6] = Inode, [7+] = Path
					fields = line.split(/\s+/)
					next if fields.size < 7
					
					# State field is at index 5 (St)
					# 01 = SS_UNCONNECTED (listening), 02 = SS_CONNECTING (queued), 03 = SS_CONNECTED (active)
					state_hex = fields[5]
					# Path starts at index 7
					path = fields[7..-1]&.join(" ") || ""
					
					# Apply filter if specified
					next if path_filter && !path_filter.include?(path)
					next if path.empty?
					
					state = state_hex.to_i(16)
					
					stats[path] ||= Listener.zero
					
					case state
					when SS_CONNECTING # Queued connections
						stats[path].queue_size += 1
					when SS_CONNECTED # Active connections
						stats[path].active_connections += 1
					end
				end
				
				return stats
			rescue Errno::ENOENT, Errno::EACCES
				return {}
			end
			
			# Parse /proc/net/tcp and /proc/net/tcp6 and extract listener statistics.
			# @parameter addresses [Array<String> | Nil] Optional filter for specific addresses.
			# @returns [Hash(String, Listener)] Hash mapping "ip:port" or "[ipv6]:port" to Listener.
			def self.capture_tcp(addresses = nil)
				stats = {}
				
				# Capture IPv4 listeners and connections
				if File.readable?("/proc/net/tcp")
					stats.merge!(capture_tcp_file("/proc/net/tcp", addresses, ipv6: false))
				end
				
				# Capture IPv6 listeners and connections
				if File.readable?("/proc/net/tcp6")
					stats.merge!(capture_tcp_file("/proc/net/tcp6", addresses, ipv6: true))
				end
				
				return stats
			end
			
			# Capture listener stats for TCP and/or Unix domain sockets.
			# @parameter addresses [String | Array<String> | Nil] TCP address(es) to capture, e.g. "0.0.0.0:80" or ["127.0.0.1:8080"]. If nil and paths is nil, captures all. If nil but paths specified, captures none.
			# @parameter paths [String | Array<String> | Nil] Unix socket path(s) to capture. If nil and addresses is nil, captures all. If nil but addresses specified, captures none.
			# @parameter unix_file [String] Optional path to Unix socket file (defaults to "/proc/net/unix").
			# @returns [Hash(String, Listener)] Hash mapping addresses/paths to Listener.
			def self.capture(addresses: nil, paths: nil, unix_file: "/proc/net/unix")
				stats = {}
				
				# Normalize addresses to array
				tcp_addresses = case addresses
				when String then [addresses]
				when Array then addresses
				when nil then paths.nil? ? nil : :skip
				else nil
				end
				
				# Normalize paths to array
				# If addresses are specified but paths is nil, don't capture Unix sockets
				# Only capture Unix sockets if paths is explicitly provided or addresses is nil
				unix_paths = case paths
				when String then [paths]
				when Array then paths
				when nil then addresses.nil? ? nil : :skip
				else nil
				end
				
				# Capture TCP stats (only if not skipped)
				stats.merge!(capture_tcp(tcp_addresses)) unless tcp_addresses == :skip
				
				# Capture Unix domain socket stats (only if not skipped)
				stats.merge!(capture_unix(unix_paths, file: unix_file)) unless unix_paths == :skip
				
				return stats
			end
		end
	end
end

# Wire Listener.capture and Listener.supported? to this implementation on Linux.
if IO::Metrics::Listener::Linux.supported?
	class << IO::Metrics::Listener
		# Whether listener capture is supported on this platform.
		# @returns [Boolean] True if /proc/net/tcp is readable.
		def supported?
			true
		end
		
		# Capture listener stats for the given address(es).
		# @parameter addresses [String | Array<String> | Nil] TCP address(es) to capture, e.g. "0.0.0.0:80". If nil, captures all listening sockets.
		# @parameter paths [String | Array<String> | Nil] Unix socket path(s) to capture. If nil and addresses is nil, captures all. If nil but addresses specified, captures none.
		# @returns [Hash(String, Listener) | Nil] A hash mapping addresses/paths to Listener, or nil if not supported.
		def capture(addresses = nil, paths: nil, **options)
			# Handle legacy single-parameter API for backward compatibility
			if addresses.is_a?(Hash)
				IO::Metrics::Listener::Linux.capture(**addresses)
			elsif addresses.nil? && options.empty? && paths.nil?
				# No arguments - capture everything
				IO::Metrics::Listener::Linux.capture(addresses: nil, paths: nil)
			else
				# Normal keyword arguments
				IO::Metrics::Listener::Linux.capture(addresses: addresses, paths: paths, **options)
			end
		end
	end
end
