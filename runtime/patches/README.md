# Compatibility changes to official modules

These files are **modified source**, not pristine upstream release binaries. Each
entry in `index.json` records the exact module version, original file checksum,
and replacement checksum. `cores.lock.json` pins the entire index. The build
verifies both checksums, copies modules privately, and leaves GOMODCACHE intact.
New files have a null upstream checksum. Original licences are in `licenses/`;
the complete corresponding module sources and licences accompany every release.

Changes maintained by this repository (2026-09-14):

- sing-box inbounds and protocol libraries: complete authentication snapshots
  with stable user-name identities, including user deletion. Snapshot publication
  is synchronized with handshake reads. This replaces the old fork-only
  AddUsers/DelUsers interfaces without restarting shared listeners.
- sing-box route/network.go: atomic startup flag read by interface-monitor callbacks.
- Xray TLS configuration: synchronized publication of immutable certificate
  snapshots during certificate/OCSP refresh. Network requests happen outside the
  publication lock, so handshakes are not held behind OCSP requests.
- AnyTLS session stream: atomically publish the close error observed by concurrent readers and writers.
- V2bX-side connection tracking, revocation and traffic changes live in
  `runtime/core/sing/` and `runtime/common/counter/`, not in a hidden fork.

Upstream updates require reviewing and rebasing these changes. A changed original
file checksum is a build failure; a new official version is never silently
substituted for the reviewed dependency. `build-info` exposes replacements and the
patch-index digest instead of describing this as an unmodified official binary.
