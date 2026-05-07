# Releases

## v0.4.1

  - Fix parsing of IPv6 addresses on Darwin.

## v0.4.0

  - Introduce native Linux implementation using `NETLINK_INET_DIAG`. On Linux with the `linux/inet_diag.h` kernel header available, listener stats are collected via a single netlink round-trip instead of parsing `/proc/net/tcp`. Falls back to the pure-Ruby implementation automatically if the extension cannot be built.

## v0.3.1

  - Introduce `Listener#fin_wait_count`: connections in `FIN_WAIT1` or `FIN_WAIT2` state — server has sent FIN (initiated close) and is waiting for the peer to finish closing. Symmetric counterpart to `close_wait_count`.
  - Introduce `Listener#time_wait_count`: connections in `TIME_WAIT` state — both sides have closed; the kernel holds the socket for \~60s (2×MSL) to absorb delayed packets. High counts indicate fast connection churn.
  - Fix `parse_address` for IPv6 listeners: replace non-existent `Addrinfo.parse` with an explicit `[ipv6addr].port` pattern match.

## v0.3.0

  - **Breaking** Rename `Listener` fields: `queue_size` → `queued_count`, `active_connections` → `active_count`.
  - Introduce `Listener#close_wait_count`: number of accepted connections in `CLOSE_WAIT` state (peer has closed; application still processing).

## v0.2.1

  - Fixed `queue_size` under-reporting when multiple `SO_REUSEPORT` sockets share the same address — queue depths are now accumulated across all sockets rather than overwritten by the last one.
  - **Linux** `Listener#active_connections` for TCP no longer counts sockets that are still in the kernel accept queue (those remain in `queue_size`). Counts now match the usual “past `accept()`” meaning and align with tools such as Raindrops’ `ListenStats#active`.

## v0.2.0

  - **Breaking** `IO::Metrics::Listener.capture` returns an `Array` of `Listener` rows instead of a `Hash` keyed by address string.
  - Each `Listener` has `address` (`Addrinfo` for TCP or Unix), `queue_size`, and `active_connections`. `Listener.zero` sets `address` to `nil`. JSON uses `Addrinfo#inspect_sockaddr` for `address`, or `null` when absent.
