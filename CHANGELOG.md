# Changelog

All notable changes to os-zapret2 are documented in this file.

## v1.7.2 - 2026-06-25

### Fixed

- **Diverted traffic no longer dropped by pf (the bypass now actually works
  end-to-end).** `configure_ipfw_reinject()` enabled ipfw *after* the
  `pfctl -d; pfctl -e` bounce, which left ipfw registered *behind* pf on the
  outbound IPv4 pfil chain. pf then built no state for dvtws2's reinjected
  packets and dropped the server's return traffic, so even general HTTPS hung
  whenever the service was active. The enable now runs *before* the pf bounce,
  so pf re-registers behind ipfw (`ipfw:default` → `pf:default-out`) and the
  diverted/desynced flow completes. Verified live on OPNsense 26.1 / FreeBSD 14
  (bare-metal PPPoE): blocked domain bypasses, untouched domains keep working.
- Removed the `net.inet.ip.pfil.outbound=ipfw,pf` ordering sysctls — that OID
  does not exist on FreeBSD 14, so it was a silent no-op. The hook order is now
  achieved purely through enable-then-bounce registration ordering.

### Known limitations

- An OPNsense filter reload triggered by unrelated firewall changes can
  re-register pf ahead of ipfw again, silently disabling the bypass until the
  next `configctl zapret restart` / Save & Apply. A self-healing re-assert is
  planned for a future release.

## v1.7.1 - 2026-06-25

### Fixed

- Service start now explicitly enables the ipfw firewall engine
  (`net.inet.ip.fw.enable=1`) in `configure_ipfw_reinject()`. Previously the
  service only ran `kldload ipfw`, which initialises `fw.enable` to 1 *only* on
  the module's first load. On OPNsense ipfw is commonly already resident (e.g.
  after a Diagnostics → Blockcheck run, which loads ipfw and restores
  `fw.enable=0` on exit), so the load short-circuited and the firewall stayed
  disabled. The divert rules were installed but ipfw evaluated nothing, so no
  traffic was ever diverted to dvtws2 and the bypass silently did nothing.

## v1.7.0 - 2026-06-24

### Changed

- Documented the shipped `ipfw divert` + `--sockarg` architecture and clarified why the plugin uses the upstream zapret pfSense-style packet path.
- Updated package metadata for the `1.7.0` release.

### Fixed

- Hardened `setup.sh` so the FreeBSD package repository is always restored after dependency installation.
- Added recovery for stale FreeBSD repository backup files left by interrupted setup runs.
- Made setup tolerate both `git-lite` and `git` package names when installing zapret build dependencies.
- Kept the plugin install clean by continuing to install external dependencies during setup instead of declaring them as package dependencies.

## v1.6.5_3 - 2026-04-16

### Fixed

- Bumped the package revision so the generated asset name matched the release tag.

## v1.6.5_2 - 2026-04-16

### Changed

- Reverted the runtime packet path to upstream zapret's `ipfw` + divert recipe for better LAN NAT behavior.

## v1.6.5_1 - 2026-04-16

### Changed

- Improved blockcheck fallback summaries, persistent logs, run duration reporting, and pf restore handling.

### Fixed

- Prevented diagnostics from silently falling back to `rutracker.org`.
- Fixed diagnostics shell handling issues.

## v1.6.5 - 2026-04-16

### Fixed

- Parsed blockcheck `SUMMARY` headings and made diagnostics complete cleanly even when blockcheck reports no winning strategy.

## v1.6.4 - 2026-04-16

### Fixed

- Bounded DNS lookup timeouts in `test_domain.sh` and improved no-answer diagnostics.

## v1.6.3 - 2026-04-16

### Fixed

- Increased diagnostics PHP and configd timeouts so longer blockcheck runs can finish.

## v1.6.1 - 2026-04-16

### Changed

- Published a cleaned release after history sanitization.

## v1.1.0 - 2026-03-27

### Added

- Added an exclude domains list to keep selected sites out of DPI bypass handling.

## v1.0.0 - 2026-03-26

### Fixed

- Corrected README install instructions to match the actual package format.
