#!/usr/bin/env bash
# V2bX Integrated Manager - MPL-2.0; see vendor/v2bx-script/UPSTREAM.md.
set -uo pipefail
MANAGER_VERSION=3.5.1
M_CONFIG=/etc/V2bX
M_BINARY=/usr/local/V2bX
M_UNIT=/etc/systemd/system/V2bX.service
M_HELPER=/usr/local/bin/v2bx-socks
M_SELF=/usr/bin/V2bX

m_paint() {
    local tone=$1
    # Muted blue-grey body text, without bold white prompts.
    case $tone in 37|'1;37')
        if [[ ${TERM:-} == *256color* || ${COLORTERM:-} == truecolor || ${COLORTERM:-} == 24bit ]]; then
            tone='38;5;109'
        else tone=36; fi;;
    esac
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        printf '\033[%sm%s\033[0m' "$tone" "$2"
    else printf '%s' "$2"; fi
}
m_line() { m_paint "$1" "$2"; printf '\n'; }
m_section() { printf '\n'; m_line '1;36' "  ── $1 ──"; }
m_option() { m_paint '1;36' "  $1. "; m_line 37 "$2"; }
m_choose() {
    local title=$1 prompt=$2 option index=1
    shift 2
    m_section "$title"
    for option in "$@"; do m_option "$index" "$option"; index=$((index+1)); done
    m_ask "$prompt"
}
m_protocol_options() {
    m_choose '节点协议' "$1" Shadowsocks VLESS VMess Hysteria Hysteria2 Trojan TUIC AnyTLS
}
m_banner() {
    printf '\n'
    m_line '1;36' '  +--------------------------------------+'
    m_line '1;36' '  |   >_  V2bX  /  NETWORK CONTROL       |'
    m_line '1;36' '  +--------------------------------------+'
    m_line 37 "  节点连接世界 · 出口由你掌控    v${MANAGER_VERSION}"
}
m_error() { m_line '1;31' "未完成：$*" >&2; return 1; }
m_ask() { m_paint '1;36' '  › ' >&9; m_paint '1;37' "$1：" >&9; IFS= read -r M_REPLY <&9; }
m_confirm() { m_ask "$1 [y/N]" && [[ $M_REPLY == [yY] ]]; }
m_secret() { m_ask "$1"; }
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
m_apt_dependencies() (
    local distro=$1 version=$2 stage=''
    local packages=(jq curl unzip ca-certificates iproute2 util-linux coreutils socat cron)
    local options=(-o APT::Update::Error-Mode=any -o Acquire::Retries=2
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
    if apt-get "${options[@]}" update &&
       apt-get "${options[@]}" install -y --no-remove --no-install-recommends "${packages[@]}"; then
        return 0
    fi
    if [[ $distro != debian || $version != 11 ]]; then
        m_error 'APT 依赖安装失败；请检查上方报错并修复软件源后重试。'; return 1
    fi
    m_line 33 'Debian 11 依赖安装失败；改用临时官方软件源及安全更新快照。'
    m_line 33 'Debian 11 已结束官方 LTS；使用 2026-08-31 安全更新快照，仍验证签名。'
    m_line 37 '此操作不覆盖 /etc/apt 的软件源配置；不使用已撤下的 backports。'
    stage=$(mktemp -d "${TMPDIR:-/tmp}/v2bx-apt.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    chmod 755 "$stage" || return 1
    mkdir -p "$stage/lists/partial" || return 1
    # Bullseye LTS ended 2026-08-31; its last security index expired 2026-09-07.
    # Pin both the security index and its package pool. The live CDN can return
    # 404 for APT's percent-encoded package URLs even while its index still exists.
    # The validity exception applies only to this snapshot, never to all APT sources.
    cat > "$stage/sources.list" <<'SOURCES'
deb https://deb.debian.org/debian bullseye main
deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20260831T235959Z/ bullseye-security main
SOURCES
    chmod 644 "$stage/sources.list" || return 1
    options+=(-o "Dir::Etc::sourcelist=$stage/sources.list" -o Dir::Etc::sourceparts=-
        -o "Dir::State::lists=$stage/lists")
    if ! apt-get "${options[@]}" update; then
        m_error '临时官方软件源更新失败，请检查网络、系统时间和上方 APT 报错。'; return 1
    fi
    apt-get "${options[@]}" install -y --no-remove --no-install-recommends "${packages[@]}" || {
        m_error '依赖安装失败，未继续安装 V2bX 内核。'; return 1;
    }
)
m_dependencies() {
    local c missing=false
    for c in jq curl unzip ss ip flock sha256sum systemd-run; do command -v "$c" >/dev/null 2>&1 || missing=true; done
    [[ $missing == true ]] || return 0
    printf '正在安装运行依赖（Bash、jq、curl 和系统工具，不需要 Python）……\n'
    if command -v apt-get >/dev/null 2>&1; then
        local ID='' VERSION_ID=''
        source /etc/os-release
        m_apt_dependencies "$ID" "$VERSION_ID" || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq curl unzip ca-certificates iproute util-linux coreutils socat cronie
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release && yum install -y jq curl unzip ca-certificates iproute util-linux coreutils socat cronie
    else m_error '无法安装依赖。'; return 1; fi
    for c in jq curl unzip ss ip flock sha256sum systemd-run; do command -v "$c" >/dev/null 2>&1 || return 1; done
}
m_installed() { [[ -x $M_BINARY/V2bX ]]; }
m_need_install() { m_installed || { m_error '请先使用菜单 11 安装 V2bX。'; return 1; }; }
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
