// Released under the MIT License.
// Copyright, 2026, by Samuel Williams.
//
// Native Linux listener statistics using netlink NETLINK_INET_DIAG.
//
// This is the same kernel interface used by `ss(8)` and Raindrops. It is
// significantly faster than parsing /proc/net/tcp* because:
//   - Single syscall round-trip per address family.
//   - No string parsing or hex decoding.
//   - Kernel-filtered: only the states we request are returned.
//
// The inet_diag protocol sends one netlink message per socket. LISTEN rows
// carry the accept-queue depth (idiag_rqueue). Connection rows carry the
// local address/port that identifies their listener. A single bitmask request
// covers all TCP states of interest; the kernel guarantees LISTEN rows are
// delivered before the connections that belong to them.

#include "extconf.h"

#if defined(HAVE_LINUX_INET_DIAG_H) || defined(__linux__)

#include "listener.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/inet_diag.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

// States we request from the kernel in a single dump.
#define IO_METRICS_STATES \
	((1 << TCP_LISTEN)     | \
	 (1 << TCP_ESTABLISHED)| \
	 (1 << TCP_CLOSE_WAIT) | \
	 (1 << TCP_FIN_WAIT1)  | \
	 (1 << TCP_FIN_WAIT2)  | \
	 (1 << TCP_TIME_WAIT))

// Receive buffer: sized for ~400 sockets per recv() call. The kernel sends
// multiple messages per recv() in a multi-part netlink response.
#define IO_METRICS_RECEIVE_BUFFER_SIZE 65536

// ── Listener table helpers ────────────────────────────────────────────────

static struct IO_Metrics_Listener *find_or_create_listener(
	struct IO_Metrics_State *state,
	uint8_t family,
	const uint8_t *address,
	uint16_t port  // host byte order
) {
	size_t address_length = (family == AF_INET) ? 4 : 16;
	
	for (int index = 0; index < state->count; index++) {
		struct IO_Metrics_Listener *listener = &state->listeners[index];
		if (listener->family == family && listener->port == port &&
		    memcmp(listener->address, address, address_length) == 0) {
			return listener;
		}
	}
	
	if (state->count >= IO_METRICS_MAX_LISTENERS) return NULL;
	
	struct IO_Metrics_Listener *listener = &state->listeners[state->count++];
	memset(listener, 0, sizeof(*listener));
	listener->family = family;
	listener->port   = port;
	memcpy(listener->address, address, address_length);
	return listener;
}

// Match a connection's local address/port to its listener.
// Prefers exact match; falls back to wildcard (0.0.0.0:port or [::]:port).
static struct IO_Metrics_Listener *find_listener(
	struct IO_Metrics_State *state,
	uint8_t family,
	const uint8_t *address,
	uint16_t port  // host byte order
) {
	static const uint8_t zeros[16] = {0};
	size_t address_length = (family == AF_INET) ? 4 : 16;
	struct IO_Metrics_Listener *wildcard = NULL;
	
	for (int index = 0; index < state->count; index++) {
		struct IO_Metrics_Listener *listener = &state->listeners[index];
		if (listener->family != family || listener->port != port) continue;
		if (memcmp(listener->address, address, address_length) == 0) return listener;
		if (memcmp(listener->address, zeros, address_length) == 0) wildcard = listener;
	}
	
	return wildcard;
}

// ── inet_diag message processing ─────────────────────────────────────────

static void process_diag_message(
	struct IO_Metrics_State *state,
	const struct inet_diag_msg *message
) {
	uint8_t  family  = message->idiag_family;
	uint16_t port    = ntohs(message->id.idiag_sport);
	const uint8_t *address = (const uint8_t *)message->id.idiag_src;
	
	switch (message->idiag_state) {
		case TCP_LISTEN: {
			struct IO_Metrics_Listener *listener =
				find_or_create_listener(state, family, address, port);
			if (listener) listener->queued_count += message->idiag_rqueue;
			break;
		}
		case TCP_ESTABLISHED: {
			// inode == 0 means the socket is in the accept queue but has not
			// yet been accept()-ed. Those are already reflected in queued_count.
			if (message->idiag_inode == 0) break;
			struct IO_Metrics_Listener *listener = find_listener(state, family, address, port);
			if (listener) listener->active_count++;
			break;
		}
		case TCP_CLOSE_WAIT: {
			struct IO_Metrics_Listener *listener = find_listener(state, family, address, port);
			if (listener) listener->close_wait_count++;
			break;
		}
		case TCP_FIN_WAIT1:
		case TCP_FIN_WAIT2: {
			struct IO_Metrics_Listener *listener = find_listener(state, family, address, port);
			if (listener) listener->fin_wait_count++;
			break;
		}
		case TCP_TIME_WAIT: {
			struct IO_Metrics_Listener *listener = find_listener(state, family, address, port);
			if (listener) listener->time_wait_count++;
			break;
		}
	}
}

// ── Netlink I/O ──────────────────────────────────────────────────────────

static int send_inet_diag_request(int socket_fd, uint8_t family, uint32_t states)
{
	struct {
		struct nlmsghdr      netlink_header;
		struct inet_diag_req diag_request;
	} request;
	
	memset(&request, 0, sizeof(request));
	request.netlink_header.nlmsg_len   = sizeof(request);
	request.netlink_header.nlmsg_type  = TCPDIAG_GETSOCK;
	request.netlink_header.nlmsg_flags = NLM_F_ROOT | NLM_F_MATCH | NLM_F_REQUEST;
	request.netlink_header.nlmsg_pid   = getpid();
	request.netlink_header.nlmsg_seq   = 1;
	request.diag_request.idiag_family  = family;
	request.diag_request.idiag_states  = states;
	
	struct sockaddr_nl netlink_address;
	memset(&netlink_address, 0, sizeof(netlink_address));
	netlink_address.nl_family = AF_NETLINK;
	
	return (sendto(socket_fd, &request, sizeof(request), 0,
	               (struct sockaddr *)&netlink_address, sizeof(netlink_address)) < 0) ? -1 : 0;
}

// Process responses, ignoring any socket whose idiag_family does not match
// the requested family. This prevents IPv4-mapped IPv6 entries (returned by
// some kernels in an AF_INET6 dump) from being double-counted against AF_INET
// listeners.
static int recv_inet_diag_responses(int socket_fd, struct IO_Metrics_State *state, uint8_t family)
{
	char receive_buffer[IO_METRICS_RECEIVE_BUFFER_SIZE];
	
	for (;;) {
		ssize_t received_length = recv(socket_fd, receive_buffer, sizeof(receive_buffer), 0);
		if (received_length < 0) {
			if (errno == EINTR) continue;
			return -1;
		}
		if (received_length == 0) return 0;
		
		struct nlmsghdr *netlink_header = (struct nlmsghdr *)receive_buffer;
		while (NLMSG_OK(netlink_header, (unsigned int)received_length)) {
			if (netlink_header->nlmsg_type == NLMSG_DONE)  return 0;
			if (netlink_header->nlmsg_type == NLMSG_ERROR) return -1;
			if (netlink_header->nlmsg_type == TCPDIAG_GETSOCK) {
				struct inet_diag_msg *message = (struct inet_diag_msg *)NLMSG_DATA(netlink_header);
				/* Only process entries that belong to the queried address family. */
				if (message->idiag_family == family)
					process_diag_message(state, message);
			}
			netlink_header = NLMSG_NEXT(netlink_header, received_length);
		}
	}
}

// Capture all listener stats for one address family.
static int capture_family(struct IO_Metrics_State *state, uint8_t family)
{
	int socket_fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_INET_DIAG);
	if (socket_fd < 0) return -1;
	
	int status = send_inet_diag_request(socket_fd, family, IO_METRICS_STATES);
	if (status == 0) status = recv_inet_diag_responses(socket_fd, state, family);
	
	close(socket_fd);
	return status;
}

// ── Ruby object creation ─────────────────────────────────────────────────

static VALUE listener_to_ruby(
	const struct IO_Metrics_Listener *listener,
	VALUE listener_class
) {
	char ip_string[INET6_ADDRSTRLEN];
	if (listener->family == AF_INET) {
		struct in_addr ipv4_address;
		memcpy(&ipv4_address, listener->address, 4);
		inet_ntop(AF_INET, &ipv4_address, ip_string, sizeof(ip_string));
	} else {
		struct in6_addr ipv6_address;
		memcpy(&ipv6_address, listener->address, 16);
		inet_ntop(AF_INET6, &ipv6_address, ip_string, sizeof(ip_string));
	}
	
	/* Addrinfo is from the socket extension; look it up by name to avoid
	 * depending on ext/socket/rubysocket.h which is not part of the public API. */
	VALUE addrinfo_class = rb_const_get(rb_cObject, rb_intern("Addrinfo"));
	VALUE addrinfo = rb_funcall(
		addrinfo_class, rb_intern("tcp"), 2,
		rb_str_new_cstr(ip_string), INT2NUM(listener->port)
	);
	
	return rb_struct_new(
		listener_class,
		addrinfo,
		UINT2NUM(listener->queued_count),
		UINT2NUM(listener->active_count),
		UINT2NUM(listener->close_wait_count),
		UINT2NUM(listener->fin_wait_count),
		UINT2NUM(listener->time_wait_count),
		NULL
	);
}

// ── Ruby API ─────────────────────────────────────────────────────────────

// IO::Metrics::Listener::Native.supported? -> true
static VALUE IO_Metrics_Listener_Native_supported_p(VALUE self)
{
	return Qtrue;
}

// IO::Metrics::Listener::Native.capture(addresses: nil) -> Array<IO::Metrics::Listener>
//
// Returns an Array of IO::Metrics::Listener structs for all listening TCP
// sockets (IPv4 and IPv6). When +addresses+ is an Array of strings, only
// listeners whose "ip:port" or "[ip6]:port" key appears in that array are
// included.
static VALUE IO_Metrics_Listener_Native_capture(int argc, VALUE *argv, VALUE self)
{
	VALUE options = Qnil;
	rb_scan_args(argc, argv, ":", &options);
	
	VALUE addresses = Qnil;
	if (!NIL_P(options)) {
		addresses = rb_hash_lookup(options, ID2SYM(rb_intern("addresses")));
	}
	
	struct IO_Metrics_State state;
	memset(&state, 0, sizeof(state));
	
	if (capture_family(&state, AF_INET) < 0) {
		rb_sys_fail("IO_Metrics_Listener_Native_capture: AF_INET");
	}
	if (capture_family(&state, AF_INET6) < 0) {
		rb_sys_fail("IO_Metrics_Listener_Native_capture: AF_INET6");
	}
	
	// Build a lowercase address filter hash for O(1) lookup.
	VALUE address_filter = Qnil;
	if (!NIL_P(addresses) && RB_TYPE_P(addresses, T_ARRAY)) {
		address_filter = rb_hash_new();
		long address_count = RARRAY_LEN(addresses);
		for (long index = 0; index < address_count; index++) {
			VALUE lowercase_address = rb_funcall(RARRAY_AREF(addresses, index), rb_intern("downcase"), 0);
			rb_hash_aset(address_filter, lowercase_address, Qtrue);
		}
	}
	
	VALUE IO_Metrics          = rb_const_get(rb_cIO, rb_intern("Metrics"));
	VALUE IO_Metrics_Listener = rb_const_get(IO_Metrics, rb_intern("Listener"));
	VALUE ruby_array          = rb_ary_new_capa(state.count);
	
	for (int index = 0; index < state.count; index++) {
		const struct IO_Metrics_Listener *listener = &state.listeners[index];
		
		if (!NIL_P(address_filter)) {
			char key[INET6_ADDRSTRLEN + 8];
			char ip_string[INET6_ADDRSTRLEN];
			if (listener->family == AF_INET) {
				struct in_addr ipv4_address; memcpy(&ipv4_address, listener->address, 4);
				inet_ntop(AF_INET, &ipv4_address, ip_string, sizeof(ip_string));
				snprintf(key, sizeof(key), "%s:%u", ip_string, listener->port);
			} else {
				struct in6_addr ipv6_address; memcpy(&ipv6_address, listener->address, 16);
				inet_ntop(AF_INET6, &ipv6_address, ip_string, sizeof(ip_string));
				snprintf(key, sizeof(key), "[%s]:%u", ip_string, listener->port);
			}
			VALUE lowercase_key = rb_funcall(rb_str_new_cstr(key), rb_intern("downcase"), 0);
			if (NIL_P(rb_hash_lookup(address_filter, lowercase_key))) continue;
		}
		
		rb_ary_push(ruby_array, listener_to_ruby(listener, IO_Metrics_Listener));
	}
	
	return ruby_array;
}

// ── Init ─────────────────────────────────────────────────────────────────

void Init_IO_Metrics_Listener(VALUE IO_Metrics)
{
	VALUE IO_Metrics_Listener = rb_const_get(IO_Metrics, rb_intern("Listener"));
	
	VALUE IO_Metrics_Listener_Native =
		rb_define_class_under(IO_Metrics_Listener, "Native", rb_cObject);
	
	rb_define_singleton_method(IO_Metrics_Listener_Native, "supported?",
		IO_Metrics_Listener_Native_supported_p, 0);
	rb_define_singleton_method(IO_Metrics_Listener_Native, "capture",
		IO_Metrics_Listener_Native_capture, -1);
}

#endif /* HAVE_LINUX_INET_DIAG_H || __linux__ */
