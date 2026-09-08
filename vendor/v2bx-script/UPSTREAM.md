# Upstream source

Source: https://github.com/wyx2685/V2bX-script
Commit: c532ec57a67d7544c700f3f438c09dffcd0b1313
Retrieved: 2026-09-08
License: Mozilla Public License 2.0 (LICENSE in this directory).

These files are unmodified reference copies, not executed by the integrated manager.
The installation layout, menu/commands, configuration defaults and routing templates
are adapted in src/manager/*.sh under MPL-2.0. Local changes add staged installation,
shared configuration generation, JSON encoding, rollback, and optional SOCKS management.
Runtime scripts are built from src; they never fetch these upstream scripts.
