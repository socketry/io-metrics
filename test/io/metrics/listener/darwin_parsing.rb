# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "io/metrics"
require "set"
require "socket"
require "stringio"

if RUBY_PLATFORM.include?("darwin")
	describe IO::Metrics::Listener::Darwin do
		with ".parse_address" do
			it "parses wildcard *.port as IPv4 any" do
				addr = IO::Metrics::Listener::Darwin.parse_address("*.49152")
				expect(addr.ipv4?).to be == true
				expect(addr.ip_address).to be == "0.0.0.0"
				expect(addr.ip_port).to be == 49152
			end
			
			it "parses bracketed IPv6 with zone stripped" do
				addr = IO::Metrics::Listener::Darwin.parse_address("[fe80::1%lo0].443")
				expect(addr.ipv6?).to be == true
				expect(addr.ip_address).to be == "fe80::1"
				expect(addr.ip_port).to be == 443
			end
			
			it "parses bracketed IPv6 loopback" do
				addr = IO::Metrics::Listener::Darwin.parse_address("[::1].8080")
				expect(addr.ipv6?).to be == true
				expect(addr.ip_address).to be == "::1"
				expect(addr.ip_port).to be == 8080
			end
			
			it "parses dotted IPv4 with trailing port" do
				addr = IO::Metrics::Listener::Darwin.parse_address("127.0.0.1.9090")
				expect(addr.ipv4?).to be == true
				expect(addr.ip_address).to be == "127.0.0.1"
				expect(addr.ip_port).to be == 9090
			end
			
			it "parses bare IPv6 with trailing port" do
				addr = IO::Metrics::Listener::Darwin.parse_address("::1.9091")
				expect(addr.ipv6?).to be == true
				expect(addr.ip_address).to be == "::1"
				expect(addr.ip_port).to be == 9091
			end
			
			it "returns nil for unparseable input" do
				expect(IO::Metrics::Listener::Darwin.parse_address("not-an-address")).to be == nil
			end
		end
		
		with ".tcp_listener_key" do
			it "formats IPv4 keys" do
				addr = Addrinfo.tcp("127.0.0.1", 80)
				expect(IO::Metrics::Listener::Darwin.tcp_listener_key(addr)).to be == "127.0.0.1:80"
			end
			
			it "formats IPv6 keys" do
				addr = Addrinfo.tcp("::1", 443)
				expect(IO::Metrics::Listener::Darwin.tcp_listener_key(addr)).to be == "[::1]:443"
			end
		end
		
		with ".parse_netstat_output" do
			it "accumulates listener rows from netstat-style lines" do
				input = <<~NETSTAT
					Current listen queue sizes ...
					Listen ... Local Address
					2/0/128    [::1].8080
					1/0/128    127.0.0.1.9092
				NETSTAT
				
				listeners = {}
				IO::Metrics::Listener::Darwin.parse_netstat_output(StringIO.new(input), listeners, nil)
				
				expect(listeners["[::1]:8080"]).to be_a(IO::Metrics::Listener)
				expect(listeners["[::1]:8080"].queued_count).to be == 2
				expect(listeners["127.0.0.1:9092"]).to be_a(IO::Metrics::Listener)
			end
			
			it "applies address filter when given" do
				input = "1/0/128    127.0.0.1.7\n"
				filter = Set["127.0.0.1:7"]
				listeners = {}
				IO::Metrics::Listener::Darwin.parse_netstat_output(StringIO.new(input), listeners, filter)
				expect(listeners.keys).to be == ["127.0.0.1:7"]
			end
		end
		
		with ".capture_tcp" do
			it "returns empty array when netstat cannot be executed" do
				mock(IO) do |m|
					m.replace(:popen) do |*_args, **_kwargs|
						raise Errno::ENOENT, "netstat"
					end
				end
				
				expect(IO::Metrics::Listener::Darwin.capture_tcp).to be == []
			end
		end
	end
end
