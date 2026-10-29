# HY2 Geo Paths Implementation Plan

**Goal:** Make all newly generated standalone HY2 configurations use the manager-maintained Geo databases.

**Architecture:** Add explicit Geo paths in the shared template, using final `M_CONFIG` rather than the temporary candidate directory. Preserve existing ACL rules and existing node configurations; no core runtime change is needed.

**Tech Stack:** Bash, jq, Python unittest, existing V2bX native configuration preflight.

- [x] Add regression tests in `tests/test_hy2_geo_paths.py` for staged generation, usable final paths, template-only calls, escaped paths and append-only node creation. Confirm failures with the original template.
- [x] Update `src/manager/templates.sh` to emit JSON-quoted `acl.geoip` / `acl.geosite`; bump `src/manager/common.sh` to 3.7.2 and rebuild with `bash build.sh`.
- [x] Document existing-node migration limits in `README.md`; preserve the original CN rejection rules and exclude site exceptions.
- [x] Run targeted and full script tests, native runtime preflight and generated-artifact/hash checks; review the diff.
- [x] Add `tests/runtime_hy2_geo.py` to the dual-architecture core CI. Start actual HY2 against a loopback panel after deleting its stage, with invalid databases in a different cwd and external downloads disabled.

**Local validation:** The four new regressions failed before the template fix and pass after it. All 220 script tests completed (208 passed, 12 Linux/systemd environment skips). The existing native configuration/startup checks and the new HY2 startup regression passed using a locally built runtime with fixture Geo assets. Shell syntax, reproducible build output, SHA256 manifest and diff whitespace checks passed. These results do not claim completion of Linux CI or a core release.

**Delivery:** Commit only this change to `main`, push `origin/main` and verify the remote commit and CI status. Leave unrelated untracked files untouched. No other production node updates or core releases are included.
