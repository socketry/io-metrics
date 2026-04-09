# IO::Metrics

Extract I/O metrics from the host system, specifically listen queue statistics.

[![Development Status](https://github.com/socketry/io-metrics/workflows/Test/badge.svg)](https://github.com/socketry/io-metrics/actions?workflow=Test)

## Usage

Please see the [project documentation](https://socketry.github.io/io-metrics/) for more details.

  - [Getting Started](https://socketry.github.io/io-metrics/guides/getting-started/index) - This guide explains how to use `io-metrics` to capture listener queue statistics from the host operating system.

## Releases

Please see the [project releases](https://socketry.github.io/io-metrics/releases/index) for all releases.

### v0.2.1

  - Fixed `queue_size` under-reporting when multiple `SO_REUSEPORT` sockets share the same address — queue depths are now accumulated across all sockets rather than overwritten by the last one.
  - **Linux** `Listener#active_connections` for TCP no longer counts sockets that are still in the kernel accept queue (those remain in `queue_size`). Counts now match the usual “past `accept()`” meaning and align with tools such as Raindrops’ `ListenStats#active`.

### v0.2.0

  - **Breaking** `IO::Metrics::Listener.capture` returns an `Array` of `Listener` rows instead of a `Hash` keyed by address string.
  - Each `Listener` has `address` (`Addrinfo` for TCP or Unix), `queue_size`, and `active_connections`. `Listener.zero` sets `address` to `nil`. JSON uses `Addrinfo#inspect_sockaddr` for `address`, or `null` when absent.

## Contributing

We welcome contributions to this project.

1.  Fork it.
2.  Create your feature branch (`git checkout -b my-new-feature`).
3.  Commit your changes (`git commit -am 'Add some feature'`).
4.  Push to the branch (`git push origin my-new-feature`).
5.  Create new Pull Request.

### Running Tests

To run the test suite:

``` shell
bundle exec sus
```

### Making Releases

To make a new release:

``` shell
bundle exec bake gem:release:patch # or minor or major
```

### Developer Certificate of Origin

In order to protect users of this project, we require all contributors to comply with the [Developer Certificate of Origin](https://developercertificate.org/). This ensures that all contributions are properly licensed and attributed.

### Community Guidelines

This project is best served by a collaborative and respectful environment. Treat each other professionally, respect differing viewpoints, and engage constructively. Harassment, discrimination, or harmful behavior is not tolerated. Communicate clearly, listen actively, and support one another. If any issues arise, please inform the project maintainers.
