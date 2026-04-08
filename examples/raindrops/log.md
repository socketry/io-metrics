# Investigation Log: io-metrics queue_size vs Raindrops queued

## Goal

Try to reproduce a scenario where `io-metrics` reports `queue_size` ≈ 2× what
Raindrops reports for `queued`. Document everything tried.

## Tools

- `investigate.rb` — new script that runs targeted scenarios, dumps raw
  `/proc/net/tcp` and `/proc/net/tcp6` lines for the port, and compares the
  two libraries side-by-side with a ratio.

---

## Background: how each library reads the queue

### Raindrops (`inet_diag` / netlink)

Sends a `TCPDIAG_GETSOCK` netlink request requesting only `TCP_ESTABLISHED | TCP_LISTEN`
sockets. For each response:

- **LISTEN socket**: `stats->queued += r->idiag_rqueue` — accumulates
  `sk_ack_backlog` (accept-queue depth) across *all* matching LISTEN sockets with
  the same address key (important for SO_REUSEPORT).
- **ESTABLISHED socket with `inode == 0`**: skipped — these are connections still
  in the accept queue, not yet returned by `accept()`.
- **ESTABLISHED socket with `inode != 0`**: `stats->active++` — connections that
  are fully accepted and have a real file descriptor.

### io-metrics (`/proc/net/tcp` + `/proc/net/tcp6`)

Reads both proc files in two separate single-pass sweeps.

- **LISTEN row**: `queue_size = rx_queue` (last row for a given address key wins;
  no accumulation). `active_connections` reset to 0.
- **ESTABLISHED rows**: all collected into a list, then attributed to the matching
  listener via `find_matching_listener`. *All* ESTABLISHED entries are counted
  (inode-0 and inode-non-0 alike) in `active_connections`.
- After sweep: `active_connections -= queue_size` (to subtract the in-queue
  connections that are ESTABLISHED but not yet accepted).

The key differences from Raindrops:
1. `queue_size` is **assigned** from the last LISTEN row for a given key, never
   accumulated.
2. ESTABLISHED connections with inode=0 are counted and then subtracted, rather
   than skipped upfront.

---

## Scenarios tested

### Scenario 1: Dual-stack socket (IPV6_V6ONLY=0), 5 IPv4 + 5 IPv6 clients

**Result: both match — ratio 1.0**

The dual-stack socket appears **only** in `/proc/net/tcp6` as `[::]:port`.
IPv4 client-side connections appear in `/proc/net/tcp` (local = client ephemeral
port) but are correctly ignored by `find_matching_listener` because no listener
exists on a client ephemeral port.
IPv4 server-side connections appear in `/proc/net/tcp6` as IPv4-mapped
(`::ffff:127.0.0.1`) with `inode=0`, correctly matched to `[::]:port`.

```
io-metrics: [::]:port  queue=10  active=0
raindrops:  [::]:port  queued=10 active=0
```

**Hypothesis H1 "dual-stack appears in both proc files" is false on this kernel.**

---

### Scenario 2: IPv6-only socket (IPV6_V6ONLY=1), 10 IPv6 clients

**Result: both match — ratio 1.0**

Socket appears only in `/proc/net/tcp6`. Both libraries report identically.

---

### Scenario 3: Two separate sockets — `0.0.0.0:port` (IPv4) + `[::]:port`
(IPv6-only), 5 IPv4 + 5 IPv6 clients

**Result: both match — ratio 1.0**

The two listeners appear on different keys and are reported separately by both
libraries. io-metrics sums them; Raindrops sums them: both arrive at 10.

```
io-metrics: 0.0.0.0:port queue=5 + [::]:port queue=5 = 10
raindrops:  0.0.0.0:port queued=5 + [::]:port queued=5 = 10
```

No cross-contamination between tcp and tcp6. IPv4 server-side connections appear
only in `/proc/net/tcp`; IPv6 server-side connections appear only in `/proc/net/tcp6`.

---

### Scenario 4: SO_REUSEPORT — two IPv6-only sockets on same address, 20 clients

**Result: ⚠️ MAJOR DISCREPANCY — io-metrics queue=4, Raindrops queued=20**

`/proc/net/tcp6` shows *two* LISTEN rows with key `[::]:port`:

```
row 1: inode=X  rx_queue=16   (first socket, got 16 connections)
row 2: inode=Y  rx_queue=4    (second socket, got 4 connections)
```

io-metrics behavior:
1. Row 1: creates `[::]:port` listener, `queue_size = 16`
2. Row 2: listener already exists (`||=` skips creation), `queue_size = 4`
   (**overwrites row 1's value**)
3. Counts 20 ESTABLISHED server-side entries → `active_connections = 20`
4. Subtracts: `active = max(20 − 4, 0) = 16`

Result: **queue_size = 4** (should be 20), **active_connections = 16** (should be 0).
Raindrops accumulates correctly: queued = 16 + 4 = **20**.

```
io-metrics: queue=4   active=16   (wrong)
raindrops:  queued=20 active=0    (correct)
```

**This is a confirmed SO_REUSEPORT bug in io-metrics.** The direction is
io-metrics *under*-reporting queue_size, not over-reporting. The active_connections
is severely over-reported because too little was subtracted.

---

### Scenario 4b: SO_REUSEPORT — `0.0.0.0:port` (IPv4) + `[::]:port` (dual-stack),
10 IPv4 clients

**Result: both match — ratio 1.0**

All 10 IPv4 clients connected to the IPv4-only socket (`0.0.0.0`). The
dual-stack socket got 0 connections. Both libraries agree.

No double-counting occurs: connections to `0.0.0.0:port` appear only in
`/proc/net/tcp`; the dual-stack socket in `/proc/net/tcp6` has empty queue.

---

### Scenario 5: Single dual-stack socket, 10 clients, partial accept (4 accepted)

**Result: both match at every stage — ratio 1.0**

```
before accept:   io-metrics queue=10 active=0  | raindrops queued=10 active=0
after 4 accepts: io-metrics queue=6  active=4  | raindrops queued=6  active=4
```

The inode=0 / inode≠0 distinction in Raindrops and the subtract-backlog approach
in io-metrics yield the same results for the single-socket case.

---

## Summary of findings

| Scenario | queue_size match? | active match? | Notes |
|---|---|---|---|
| Dual-stack (IPV6_V6ONLY=0) | ✅ | ✅ | |
| IPv6-only (IPV6_V6ONLY=1) | ✅ | ✅ | |
| Separate IPv4 + IPv6 sockets | ✅ | ✅ | |
| SO_REUSEPORT (2 sockets same addr) | ❌ under-reports | ❌ over-reports | **bug** |
| REUSEPORT mixed families | ✅ | ✅ | all IPv4 went to IPv4 socket |
| Partial accept | ✅ | ✅ | |

---

## Could NOT reproduce 2× queue_size

Despite testing all plausible configurations, **no scenario produced io-metrics
`queue_size` ≈ 2× Raindrops `queued`**. The only discrepancy found goes in the
*opposite* direction: with SO_REUSEPORT, io-metrics **under**-reports queue_size
(last LISTEN row wins instead of summing).

Possible explanations for the original production observation:

1. **Older kernel behaviour**: On some kernels (pre-4.x), a dual-stack
   (`IPV6_V6ONLY=0`) socket may have appeared in *both* `/proc/net/tcp` (as
   `0.0.0.0:port`) and `/proc/net/tcp6` (as `[::]:port`). io-metrics would sum
   both (different keys → different listener entries → both counted), while
   Raindrops via `inet_diag` would see only one socket. Result: io-metrics 2×
   Raindrops. Cannot reproduce on current kernel.

2. **Confusion between queue_size and active_connections**: With SO_REUSEPORT the
   `active_connections` value is severely inflated (see Scenario 4). If the user
   observed a metric labelled "active" or "backlog workers" alongside queue and
   compared totals, the 2× could be an active_connections artefact.

3. **Production-specific race or configuration**: a stale (zombie) LISTEN socket
   left by a recently-killed worker, simultaneous TCP and UNIX listeners on the
   same tracked port, or a framework that binds twice.

---

## Confirmed separate bug: SO_REUSEPORT handling is broken

`gather_tcp_file` assigns (rather than accumulates) `queue_size` for duplicate
LISTEN keys. With N SO_REUSEPORT workers, io-metrics returns only the last
worker's accept-queue depth instead of the sum:

```ruby
# current (wrong for reuseport):
listeners[local_address].queue_size = rx_queue_hex.to_i(16)

# correct:
listeners[local_address].queue_size += rx_queue_hex.to_i(16)
```

The downstream `active_connections` subtraction is also wrong as a consequence
(subtracts one worker's depth instead of the total, leaving phantom "active"
connections).

This is a separate, clearly reproducible bug independent of the original 2×
report.
