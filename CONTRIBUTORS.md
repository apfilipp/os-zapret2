# Contributors

os-zapret2 is maintained by [Umurcan Gorur](https://github.com/ugorur).

Thanks to everyone who has contributed code, testing, or bug reports.

## Code contributors

### [apfilipp](https://github.com/apfilipp)

Authored the bulk of **v1.8.3**, developed in the
[apfilipp/os-zapret2](https://github.com/apfilipp/os-zapret2) fork and merged
here with commit history intact:

- **Asynchronous Blockcheck.** Reworked diagnostics from a blocking configd
  call into a background job (`blockcheck_job.sh`) with start/status/stop,
  single-job locking, live progress polling, persistent logs, and a stricter
  winner parser (`blockcheck_winners.awk`) plus its test suite.
- **QUIC / HTTP-3 support.** Added the QUIC strategy field, the separate UDP
  dvtws2 profile, the matching ipfw divert rule, and a bundled HTTP/3 curl so
  QUIC checks do not depend on the system curl's capabilities.
- **Firewall self-repair.** Added the `repair` action and wired it to the
  `newwanip` event, so ipfw state is rebuilt after a WAN address change
  without restarting dvtws2.
- **Per-strategy stability testing.** Rewrote `test_domain.sh` to test one
  strategy against every resolved address of a domain using an isolated
  dvtws2 instance, leaving the configured service untouched.
- **Package lifecycle fixes.** Reworked the install/deinstall hooks to reload
  the configd worker under its existing supervisor instead of restarting the
  daemon inside the pkg transaction, which could leave configd stopped.

## Upstream projects

- [bol-van/zapret2](https://github.com/bol-van/zapret2) — the DPI bypass
  engine and lua strategy runtime this plugin packages.
- [lexiforest/curl-impersonate](https://github.com/lexiforest/curl-impersonate)
  — source of the bundled HTTP/3 client. See
  `src/share/licenses/os-zapret2/THIRD_PARTY_NOTICES`.
- [OPNsense](https://opnsense.org/) — the firewall platform and plugin
  framework.
