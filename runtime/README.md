# Integrated V2bX runtime

This repository builds official Xray, sing-box and Hysteria 2 modules with reviewed compatibility patches. Source provenance is in [UPSTREAM.md](UPSTREAM.md); exact versions are in [cores.lock.json](cores.lock.json).

Build from the repository root with `python3 scripts/build_core.py --output /tmp/core-dist --arch amd64` on native Linux. For cross-compilation add `--build-only`. Do not build the unpatched go.mod directly: use the prepared module file described in [official core documentation](../docs/official-cores.md).

UPSTREAM-README.md is the original historical documentation, retained for attribution. Its old download/build instructions are not this repository's release channel. The old Dockerfile, submodule pointer and self-update URL are deliberately excluded from the maintained distribution.
