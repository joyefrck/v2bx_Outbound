#!/usr/bin/env bash
# V2bX Integrated Manager - MPL-2.0; see vendor/v2bx-script/UPSTREAM.md.
set -uo pipefail
MANAGER_VERSION=3.2.0
M_CONFIG=/etc/V2bX
M_BINARY=/usr/local/V2bX
M_UNIT=/etc/systemd/system/V2bX.service
M_HELPER=/usr/local/bin/v2bx-socks
M_SELF=/usr/bin/V2bX

m_error() { printf '未完成：%s\n' "$*" >&2; return 1; }
m_ask() { printf '%s：' "$1" >&9; IFS= read -r M_REPLY <&9; }
m_confirm() { m_ask "$1 [y/N]" && [[ $M_REPLY == [yY] ]]; }
m_secret() { printf '%s：' "$1" >&9; IFS= read -rs M_REPLY <&9; local rc=$?; printf '\n' >&9; return "$rc"; }
m_fetch() {
    curl -q --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 300 --retry 2 --output "$2" "$1"
}
m_platform() {
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || { m_error '需要由 systemd 管理的 Linux；暂不支持 Alpine/OpenRC 或普通 Docker。'; return 1; }
    local ID='' ID_LIKE=''
    source /etc/os-release
    case "$ID" in debian|ubuntu|centos|rocky|almalinux|rhel) ;; *) m_error '第一版支持 Debian/Ubuntu、CentOS/Rocky/Alma 系列。'; return 1;; esac
    case $(uname -m) in x86_64|amd64|aarch64|arm64|s390x) ;; *) m_error '不支持此 CPU 架构。'; return 1;; esac
}
m_dependencies() {
    local c missing=false
    for c in jq curl unzip ss ip flock sha256sum systemd-run; do command -v "$c" >/dev/null 2>&1 || missing=true; done
    [[ $missing == true ]] || return 0
    printf '正在安装运行依赖（Bash、jq、curl 和系统工具，不需要 Python）……\n'
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y --no-install-recommends jq curl unzip ca-certificates iproute2 util-linux coreutils socat cron
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq curl unzip ca-certificates iproute util-linux coreutils socat cronie
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release && yum install -y jq curl unzip ca-certificates iproute util-linux coreutils socat cronie
    else m_error '无法安装依赖。'; return 1; fi
    for c in jq curl unzip ss ip flock sha256sum systemd-run; do command -v "$c" >/dev/null 2>&1 || return 1; done
}
m_installed() { [[ -x $M_BINARY/V2bX ]]; }
m_need_install() { m_installed || { m_error '请先使用菜单 1 安装 V2bX。'; return 1; }; }
m_health() {
    bash -c '
        source "$1"
        discover || exit 1
        initial=$(service_state | property NRestarts) || exit 1
        for ((i=0;i<30;i++)); do
            state=$(service_state) || exit 1
            [[ $(printf "%s\n" "$state" | property NRestarts) == "$initial" ]] || exit 1
            [[ $(printf "%s\n" "$state" | property SubState) != auto-restart ]] || exit 1
            if healthy 0; then healthy 5; exit $?; fi
            sleep 1
        done
        exit 1
    ' manager-health "$M_HELPER"
}
m_diagnose() {
    printf '节点尚未确认可用，未进入 SOCKS 配置。请运行 v2bx status / v2bx log 检查面板地址、节点 ID、协议和密钥。\n'
}
# Use the helper's lock and active-job checks, including the interval before a worker takes the lock.
m_lock() {
    [[ ! -L $M_CONFIG && ! -L $M_CONFIG/.v2bx-socks.lock ]] || return 1
    mkdir -p "$M_CONFIG" || return 1
    exec 8>"$M_CONFIG/.v2bx-socks.lock" || return 1
    flock -n 8 || { m_error '另一个配置或管理操作正在执行。'; return 1; }
    bash -c 'source "$1"; CONFIG_PATH="$2/config.json"; check_running_jobs' manager-lock "$M_HELPER" "$M_CONFIG" || return 1
}
m_standard_config() {
    [[ ! -e $M_CONFIG/config.json ]] && return 0
    bash -c 'source "$1"; discover && [[ $CONFIG_PATH == "$2/config.json" ]]' manager-path "$M_HELPER" "$M_CONFIG" || {
        m_error '当前服务或主配置不是标准安装布局，未覆盖。'; return 1;
    }
}
m_socks() { m_need_install && bash "$M_HELPER"; }
m_offer_socks() {
    m_health || { m_diagnose; return 1; }
    if ! jq -e 'any(.Cores[]; .Type=="xray" or .Type=="sing")' "$M_CONFIG/config.json" >/dev/null; then
        printf '当前内核不支持 SOCKS 出口；V2bX 可正常使用。\n'; return 0
    fi
    m_confirm '是否配置 SOCKS 出口？' || { printf '已跳过 SOCKS 出口配置。以后运行 v2bx socks。\n'; return 0; }
    m_socks
}
check_ipv6_support() { if ip -6 addr | grep -q 'inet6'; then printf 1; else printf 0; fi; }
