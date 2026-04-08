# Releases

## Unreleased

  - Fixed `queue_size` under-reporting when multiple `SO_REUSEPORT` sockets share the same address — queue depths are now accumulated across all sockets rather than overwritten by the last one.

## v0.2.0

  - **Breaking** `IO::Metrics::Listener.capture` returns an `Array` of `Listener` rows instead of a `Hash` keyed by address string.
  - Each `Listener` has `address` (`Addrinfo` for TCP or Unix), `queue_size`, and `active_connections`. `Listener.zero` sets `address` to `nil`. JSON uses `Addrinfo#inspect_sockaddr` for `address`, or `null` when absent.
