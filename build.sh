#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "$0")" && pwd)
bash -n "$project_dir/src/helper.sh"
cp "$project_dir/src/helper.sh" "$project_dir/v2bx-socks.sh"
chmod 700 "$project_dir/v2bx-socks.sh"
cat "$project_dir"/src/manager/{common,templates,config,core-install,nodes,menu}.sh > "$project_dir/v2bx-manager.sh"
bash -n "$project_dir/v2bx-manager.sh"
chmod 755 "$project_dir/v2bx-manager.sh"
cp "$project_dir/vendor/v2bx-script/LICENSE" "$project_dir/LICENSE.MPL-2.0"
: > "$project_dir/SHA256SUMS"
for artifact in v2bx-socks.sh v2bx-manager.sh install.sh LICENSE.MPL-2.0; do
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum "$project_dir/$artifact" | cut -d ' ' -f 1)
    else digest=$(shasum -a 256 "$project_dir/$artifact" | cut -d ' ' -f 1); fi
    printf '%s  %s\n' "$digest" "$artifact" >> "$project_dir/SHA256SUMS"
done
printf '%s\n' "$project_dir/v2bx-manager.sh" "$project_dir/v2bx-socks.sh"
