## Example

`metrics_active` / `raindrops_active` count only connections past `accept()` (not the accept backlog). `metrics_queue` / `raindrops_queue` is the backlog on the listen socket.

The script binds an IPv6 socket with dual-stack where supported, opens **5 × IPv4** (`127.0.0.1`) and **5 × IPv6** (`::1`) clients, then reports **per-listener rows**, **IPv4 / IPv6 subtotals**, and **combined sums** for that `ip_port`.

```
Dual-stack listener on port 34507 (IPv4 clients → 127.0.0.1, IPv6 clients → ::1)

--- idle ---
                                    metrics_q  metrics_act | raindrops_q raindrops_act
  IPv4 listeners:
    127.0.0.1:34507                            0            0 |           0            0
  IPv6 listeners:
    [::1]:34507                                0            0 |           0            0
  IPv4 subtotal                                0            0 |           0            0
  IPv6 subtotal                                0            0 |           0            0
  combined (port)                              0            0 |           0            0

--- 10 connected (5 IPv4 + 5 IPv6), no accept ---
  ...
  combined (port)                             10            0 |          10            0

Combined queued counts match at peak (10).
```

Run: `cd examples/raindrops && bundle install --gemfile=gems.rb && ruby compare.rb` (Linux only).
