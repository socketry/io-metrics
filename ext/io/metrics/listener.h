// Released under the MIT License.
// Copyright, 2026, by Samuel Williams.

#pragma once

#include <ruby.h>
#include <stdint.h>

// Maximum number of distinct listener sockets to track per capture. Web servers rarely bind more than a handful of ports.
#define IO_METRICS_MAX_LISTENERS 256

// Per-listener aggregated connection state counts, populated by a single pass over the kernel's inet_diag dump.
struct IO_Metrics_Listener {
	
	// AF_INET or AF_INET6
	uint8_t family;
	
	// listening port, host byte order
	uint16_t port;
	
	// listening address, network byte order (4 bytes used for IPv4)
	uint8_t address[16];
	
	// accept-queue depth (idiag_rqueue from LISTEN row)
	uint32_t queued_count;
	
	// TCP_ESTABLISHED with inode != 0 (accepted, in-flight)
	uint32_t active_count;
	
	// TCP_CLOSE_WAIT
	uint32_t close_wait_count;
	
	// TCP_FIN_WAIT1 + TCP_FIN_WAIT2
	uint32_t fin_wait_count;
	
	// TCP_TIME_WAIT
	uint32_t time_wait_count;
};

// Collection of all listeners seen in one capture pass. hash_slots maps keys (family, port, 16-byte address) to listener indices using open addressing (-1 = empty); hash_capacity doubles when load would exceed one half.
struct IO_Metrics_State {
	struct IO_Metrics_Listener listeners[IO_METRICS_MAX_LISTENERS];
	int count;
	int32_t *hash_slots;
	int hash_capacity;
};

void Init_IO_Metrics_Listener(VALUE IO_Metrics);
