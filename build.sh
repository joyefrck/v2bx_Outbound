#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
bash -n "$project_dir/src/helper.sh"
cp "$project_dir/src/helper.sh" "$project_dir/v2bx-socks.sh"
chmod 700 "$project_dir/v2bx-socks.sh"
if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$project_dir/v2bx-socks.sh" | cut -d ' ' -f 1)
else
    digest=$(shasum -a 256 "$project_dir/v2bx-socks.sh" | cut -d ' ' -f 1)
fi
printf '%s  v2bx-socks.sh\n' "$digest" > "$project_dir/SHA256SUMS"
printf '%s\n' "$project_dir/v2bx-socks.sh"
