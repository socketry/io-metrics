#!/usr/bin/env ruby
# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

return if RUBY_DESCRIPTION =~ /jruby/

require "mkmf"

extension_name = "IO_Metrics"

append_cflags(["-Wall", "-Wno-unknown-pragmas", "-std=c99"])

if ENV.key?("RUBY_DEBUG")
	$stderr.puts "Enabling debug mode..."
	append_cflags(["-DRUBY_DEBUG", "-O0"])
end

$srcs = ["io/metrics/metrics.c"]
$VPATH << "$(srcdir)/io/metrics"

# Linux netlink inet_diag: native listener stats without line-by-line parsing of /proc/net/tcp.
# Compile on Linux; the C code is guarded by #ifdef __linux__ internally.
if RbConfig::CONFIG["target_os"].include?("linux")
	have_header("linux/inet_diag.h")  # sets HAVE_LINUX_INET_DIAG_H in extconf.h
	$srcs << "io/metrics/listener.c"
end

if ENV.key?("RUBY_SANITIZE")
	$stderr.puts "Enabling sanitizers..."
	append_cflags(["-fsanitize=address", "-fsanitize=undefined", "-fno-omit-frame-pointer"])
	$LDFLAGS << " -fsanitize=address -fsanitize=undefined"
end

create_header
create_makefile(extension_name)
