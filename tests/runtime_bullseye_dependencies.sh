#!/usr/bin/env bash
# Run only inside a disposable Debian 11 container; never on a production host.
set -euo pipefail
[[ -f /.dockerenv ]] || { echo 'This test requires a disposable Docker container.' >&2; exit 1; }
source /etc/os-release
[[ $ID == debian && $VERSION_ID == 11 ]] || exit 1
[[ $(dpkg --print-architecture) == amd64 ]] || { echo 'This regression requires native AMD64.' >&2; exit 1; }
project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
# Reproduce the obsolete mirror entry without changing any host configuration.
printf '\ndeb https://deb.debian.org/debian bullseye-backports main\n' >> /etc/apt/sources.list
cp -a /etc/apt/sources.list "$stage/sources.before"
rm -f /var/cache/apt/archives/*.deb
source "$project_dir/src/manager/common.sh"
export DEBIAN_FRONTEND=noninteractive
m_apt_dependencies debian 11
cmp "$stage/sources.before" /etc/apt/sources.list
for tool in jq curl unzip ss ip flock sha256sum socat cron; do command -v "$tool"; done
jq -e '.working == true' <<< '{"working":true}'
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' jq libjq1
dpkg --audit > "$stage/audit"
[[ ! -s $stage/audit ]] || { cat "$stage/audit"; exit 1; }
printf 'PASS: AMD64 Debian 11 dependencies installed, jq works, original sources unchanged.\n'
