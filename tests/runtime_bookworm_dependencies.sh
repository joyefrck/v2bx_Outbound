#!/usr/bin/env bash
# Only run inside a disposable Debian 12 container, never on a production host.
set -euo pipefail
[[ -f /.dockerenv ]] || { echo 'This test requires a disposable Docker container.' >&2; exit 1; }
source /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 ]] || exit 1
[[ $(dpkg --print-architecture) == amd64 ]] || exit 1
project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
# This signed official snapshot has expired. APT must reject it normally, then
# the installer must recover using fresh sources without weakening validation.
printf 'deb https://snapshot.debian.org/archive/debian/20240101T000000Z/ bookworm-updates main\n' >> /etc/apt/sources.list
cp -a /etc/apt/sources.list /etc/apt/sources.list.d "$stage/"
rm -f /var/cache/apt/archives/*.deb
source "$project_dir/src/manager/common.sh"
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
m_apt_dependencies debian 12 2>&1 | tee "$stage/install.log"
grep -F 'is expired' "$stage/install.log"
grep -F 'Debian 12 依赖安装失败；改用临时官方软件源。' "$stage/install.log"
diff -r "$stage/sources.list" /etc/apt/sources.list
diff -r "$stage/sources.list.d" /etc/apt/sources.list.d
for tool in jq curl unzip ss ip flock sha256sum socat cron; do command -v "$tool"; done
jq -e '.working == true' <<< '{"working":true}'
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' jq libjq1
dpkg --audit > "$stage/audit"
[[ ! -s $stage/audit ]] || { cat "$stage/audit"; exit 1; }
printf 'PASS: AMD64 Debian 12 recovered from expired indexes, dependencies installed, sources unchanged.\n'
