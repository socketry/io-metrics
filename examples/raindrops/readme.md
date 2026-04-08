# Raindrops Comparison Example

This example compares TCP listen-queue metrics between `io-metrics` and [Raindrops](https://yhbt.net/raindrops/), demonstrating that both libraries report equivalent statistics from the Linux kernel.

## Purpose

The `compare.rb` script validates that `IO::Metrics::Listener.capture` produces the same results as `Raindrops::Linux.tcp_listener_stats`. Both libraries:

- Use kernel TCP stats (Raindrops via inet_diag; io-metrics via /proc/net/tcp)
- Report **queued** connections (accept backlog waiting to be accepted)
- Report **active** connections (established connections past `accept()`)

`metrics_active` / `raindrops_active` count only connections past `accept()` (not the accept backlog). `metrics_queue` / `raindrops_queue` is the backlog on the listen socket.

## Running the Example

From the repository root:

```bash
cd examples/raindrops
bundle install
bundle exec ruby compare.rb
```

Or from any directory using `BUNDLE_GEMFILE`:

```bash
BUNDLE_GEMFILE=examples/raindrops/gems.rb bundle exec ruby examples/raindrops/compare.rb
```

**Note:** This example requires Linux, as it relies on Linux-specific TCP statistics interfaces.

## How It Works

The script binds an IPv6 socket with dual-stack where supported, opens **5 × IPv4** (`127.0.0.1`) and **5 × IPv6** (`::1`) clients, then reports **per-listener rows**, **IPv4 / IPv6 subtotals**, and **combined sums** for that `ip_port`.

The test sequence demonstrates:
1. **Idle state** - Server listening with no connections
2. **Connected clients** - 10 clients connected but not yet accepted
3. **Partial accept** - 4 connections accepted, 6 still queued
4. **Cleanup** - All clients closed

## Example Output

```
> bundle exec ./compare.rb
Dual-stack listener on port 37997 (IPv4 clients → 127.0.0.1, IPv6 clients → ::1)

--- idle ---
                                        metrics_q  metrics_act |  raindrops_q raindrops_act
  IPv4 listeners:
    (none)
  IPv6 listeners:
    [::]:37997                                  0            0 |            0            0
  IPv4 subtotal                                 0            0 |            0            0
  IPv6 subtotal                                 0            0 |            0            0
  combined (port)                               0            0 |            0            0

--- 10 connected (5 IPv4 + 5 IPv6), no accept ---
                                        metrics_q  metrics_act |  raindrops_q raindrops_act
  IPv4 listeners:
    (none)
  IPv6 listeners:
    [::]:37997                                 10            0 |           10            0
  IPv4 subtotal                                 0            0 |            0            0
  IPv6 subtotal                                10            0 |           10            0
  combined (port)                              10            0 |           10            0

--- accepted 4 ---
                                        metrics_q  metrics_act |  raindrops_q raindrops_act
  IPv4 listeners:
    (none)
  IPv6 listeners:
    [::]:37997                                  6            4 |            6            4
  IPv4 subtotal                                 0            0 |            0            0
  IPv6 subtotal                                 6            4 |            6            4
  combined (port)                               6            4 |            6            4

--- all clients closed ---
                                        metrics_q  metrics_act |  raindrops_q raindrops_act
  IPv4 listeners:
    (none)
  IPv6 listeners:
    [::]:37997                                  6            0 |            6            0
  IPv4 subtotal                                 0            0 |            0            0
  IPv6 subtotal                                 6            0 |            6            0
  combined (port)                               6            0 |            6            0

Combined queued counts match at peak (10).
```

Run: `cd examples/raindrops && bundle install --gemfile=gems.rb && ruby compare.rb` (Linux only).
