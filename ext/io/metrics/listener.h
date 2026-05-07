// Released under the MIT License.
// Copyright, 2026, by Samuel Williams.

#pragma once

#include <ruby.h>
#include <stdint.h>

// Maximum number of distinct listener sockets to track per capture.
// Web servers rarely bind more than a handful of ports.
#define IO_METRICS_MAX_LISTENERS 256

// Per-listener aggregated connection state counts, populated by a single
// pass over the kernel's inet_diag dump.
struct IO_Metrics_Listener {
	uint8_t  family;       // AF_INET or AF_INET6
	uint16_t port;         // listening port, host byte order
	uint8_t  address[16];  // listening address, network byte order (4 bytes used for IPv4)
	
	uint32_t queued_count;      // accept-queue depth (idiag_rqueue from LISTEN row)
	uint32_t active_count;      // TCP_ESTABLISHED with inode != 0 (accepted, in-flight)
	uint32_t close_wait_count;  // TCP_CLOSE_WAIT
	uint32_t fin_wait_count;    // TCP_FIN_WAIT1 + TCP_FIN_WAIT2
	uint32_t time_wait_count;   // TCP_TIME_WAIT
};

// Collection of all listeners seen in one capture pass.
struct IO_Metrics_State {
	struct IO_Metrics_Listener listeners[IO_METRICS_MAX_LISTENERS];
	int count;
};

void Init_IO_Metrics_Listener(VALUE IO_Metrics);
