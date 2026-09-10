#!/usr/bin/env bash
# V2bX Integrated Manager - MPL-2.0; see vendor/v2bx-script/UPSTREAM.md.
set -uo pipefail
MANAGER_VERSION=3.5.2
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
    if [[ $distro != debian || ( $version != 11 && $version != 12 ) ]]; then
        m_error 'APT 依赖安装失败；请检查上方报错并修复软件源后重试。'; return 1
    fi
    m_line 33 "Debian ${version} 依赖安装失败；改用临时官方软件源。"
    if [[ $version == 11 ]]; then
        m_line 33 'Debian 11 已结束官方 LTS；使用 2026-08-31 安全更新快照，仍验证签名。'
    else
        m_line 37 '使用 bookworm 官方主源、更新源和安全源；继续验证签名及索引有效期。'
    fi
    m_line 37 '此操作不覆盖 /etc/apt 的软件源配置；临时源不加载 backports 或第三方源。'
    stage=$(mktemp -d "${TMPDIR:-/tmp}/v2bx-apt.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    chmod 755 "$stage" || return 1
    mkdir -p "$stage/lists/partial" || return 1
    if [[ $version == 11 ]]; then
        # Bullseye LTS ended 2026-08-31; pin its security index and package pool.
        # The validity exception applies only to this retired snapshot.
        cat > "$stage/sources.list" <<'SOURCES'
deb https://deb.debian.org/debian bullseye main
deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20260831T235959Z/ bullseye-security main
SOURCES
    else
        # Bookworm is still maintained. Never disable its freshness checks to
        # work around a stale mirror; use current official indexes instead.
        cat > "$stage/sources.list" <<'SOURCES'
deb https://deb.debian.org/debian bookworm main
deb https://deb.debian.org/debian bookworm-updates main
deb https://deb.debian.org/debian-security bookworm-security main
SOURCES
    fi
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
# Derived from wyx2685/V2bX-script initconfig.sh; MPL-2.0. See vendor/v2bx-script.
write_route_templates() {
    local target=$1 ipv6_support dnsstrategy
    # 创建 custom_outbound.json 文件
    cat <<EOF > ${target}/custom_outbound.json
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv4v6"
        }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF
    [[ $? == 0 ]] || return 1

    # 创建 route.json 文件
    cat <<EOF > ${target}/route.json
{
    "domainStrategy": "AsIs",
    "rules": [
        {
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
        {
            "outboundTag": "block",
            "domain": [
                "regexp:(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
                "regexp:(.+.|^)(360|so).(cn|com)",
                "regexp:(Subject|HELO|SMTP)",
                "regexp:(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
                "regexp:(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
                "regexp:(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
                "regexp:(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
                "regexp:(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
                "regexp:(.+.|^)(360).(cn|com|net)",
                "regexp:(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
                "regexp:(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
                "regexp:(.*.||)(netvigator|torproject).(com|cn|net|org)",
                "regexp:(..||)(visa|mycard|gash|beanfun|bank).",
                "regexp:(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
                "regexp:(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
                "regexp:(.*.||)(mycard).(com|tw)",
                "regexp:(.*.||)(gash).(com|tw)",
                "regexp:(.bank.)",
                "regexp:(.*.||)(pincong).(rocks)",
                "regexp:(.*.||)(taobao).(com)",
                "regexp:(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
                "regexp:(flows|miaoko).(pages).(dev)"
            ]
        },
        {
            "outboundTag": "block",
            "ip": [
                "127.0.0.1/32",
                "10.0.0.0/8",
                "fc00::/7",
                "fe80::/10",
                "172.16.0.0/12"
            ]
        },
        {
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF
    [[ $? == 0 ]] || return 1
    ipv6_support=$(check_ipv6_support)
    dnsstrategy="ipv4_only"
    if [ "$ipv6_support" -eq 1 ]; then
        dnsstrategy="prefer_ipv4"
    fi
    # 创建 sing_origin.json 文件
    cat <<EOF > ${target}/sing_origin.json
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "address": "1.1.1.1"
      }
    ],
    "strategy": "$dnsstrategy"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "$dnsstrategy"
      }
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "block"
      },
      {
        "domain_regex": [
            "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
            "(.+.|^)(360|so).(cn|com)",
            "(Subject|HELO|SMTP)",
            "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
            "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
            "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
            "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
            "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
            "(.+.|^)(360).(cn|com|net)",
            "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
            "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
            "(.*.||)(netvigator|torproject).(com|cn|net|org)",
            "(..||)(visa|mycard|gash|beanfun|bank).",
            "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
            "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
            "(.*.||)(mycard).(com|tw)",
            "(.*.||)(gash).(com|tw)",
            "(.bank.)",
            "(.*.||)(pincong).(rocks)",
            "(.*.||)(taobao).(com)",
            "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
            "(flows|miaoko).(pages).(dev)"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct",
        "network": [
          "udp","tcp"
        ]
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF
    [[ $? == 0 ]] || return 1

    # 创建 hy2config.yaml 文件
    cat <<EOF > ${target}/hy2config.yaml
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
resolver:
  type: system
acl:
  inline:
    - direct(geosite:google)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF
    [[ $? == 0 ]] || return 1
}
# Shared node wizard, adapted from upstream initconfig.sh (MPL-2.0).
m_panel() {
    m_section '面板连接'
    m_ask '请输入面板网址（https://example.com）' || return 1
    [[ $M_REPLY =~ ^https?://[^[:space:]]+$ ]] || { m_error '面板地址须以 http:// 或 https:// 开头。'; return 1; }
    api_host=$M_REPLY
    m_secret '请输入面板对接 API Key（直接显示）' || return 1
    [[ -n $M_REPLY ]] || return 1
    api_key=$M_REPLY; M_REPLY=''
}
m_node() {
    local core node_id protocol reality=n tls=n certmode=none domain=example.com fast=true listen=0.0.0.0 certfile keyfile provider='' dnsenv='{}'
    if [[ -n ${M_NODE_CORE:-} ]]; then core=$M_NODE_CORE
    else
        m_choose '节点核心' '请选择节点核心 [1-3]' 'Xray' 'sing-box' '独立 Hysteria2' || return 1
        case $M_REPLY in 1) core=xray;; 2) core=sing;; 3) core=hysteria2;; *) m_error '请选择 1、2 或 3。'; return 1;; esac
    fi
    m_ask '请输入节点 Node ID（正整数）' || return 1
    [[ $M_REPLY =~ ^[1-9][0-9]{0,9}$ ]] || { m_error 'Node ID 必须为正整数。'; return 1; }
    node_id=$M_REPLY
    if [[ $core == hysteria2 ]]; then protocol=hysteria2
    else
        m_protocol_options '请选择协议 [1-8]' || return 1
        case $M_REPLY in 1) protocol=shadowsocks;; 2) protocol=vless;; 3) protocol=vmess;; 4) protocol=hysteria;; 5) protocol=hysteria2;; 6) protocol=trojan;; 7) protocol=tuic;; 8) protocol=anytls;; *) return 1;; esac
        if [[ $core == xray && $protocol != shadowsocks && $protocol != vless && $protocol != vmess && $protocol != trojan ]]; then
            m_error '此协议请使用 sing-box 或独立 Hysteria2 内核。'; return 1
        fi
    fi
    if [[ $protocol == vless ]]; then m_ask '是否为 Reality 节点？[y/N]' || return 1; reality=$M_REPLY; fi
    case $protocol in hysteria|hysteria2|tuic|anytls) tls=y; fast=false;; esac
    if [[ $reality != [yY] && $tls != y ]]; then m_ask '是否配置 TLS？[y/N]' || return 1; tls=$M_REPLY; fi
    certfile="$M_CONFIG/fullchain.cer"; keyfile="$M_CONFIG/cert.key"
    if [[ $reality != [yY] && $tls == [yY] ]]; then
        m_choose 'TLS 证书' '请选择证书模式 [1-4]' 'HTTP 自动申请' 'DNS 自动申请' '已有证书（file）' '自签证书（self）' || return 1
        case $M_REPLY in 1) certmode=http;; 2) certmode=dns;; 3) certmode=file;; 4) certmode=self;; *) return 1;; esac
        m_ask '请输入证书域名' || return 1; domain=$M_REPLY
        [[ -n $domain ]] || return 1
        if [[ $certmode == file ]]; then
            m_ask '证书文件绝对路径' || return 1; certfile=$M_REPLY
            m_ask '私钥文件绝对路径' || return 1; keyfile=$M_REPLY
            [[ $certfile == /* && $keyfile == /* && -f $certfile && -f $keyfile ]] || { m_error '证书和私钥文件必须存在。'; return 1; }
        elif [[ $certmode == dns ]]; then
            m_ask 'DNS Provider（例如 cloudflare）' || return 1; provider=$M_REPLY
            m_secret 'DNS 环境参数 JSON（例如 {"CF_DNS_API_TOKEN":"…"}，直接显示）' || return 1
            dnsenv=$M_REPLY; M_REPLY=''
            printf '%s' "$dnsenv" | jq -e 'type=="object" and all(.[]; type=="string")' >/dev/null 2>&1 || return 1
        fi
    fi
    [[ $core != sing || $(check_ipv6_support) != 1 ]] || listen=::
    # All strings, including secrets, enter jq through stdin, never process arguments.
    printf '%s\n' "$core" "$api_host" "$api_key" "$node_id" "$protocol" "$certmode" "$domain" "$listen" "$fast" "$certfile" "$keyfile" "$provider" "$dnsenv" "$M_CONFIG" |
        jq -Rs 'split("\n") as $v |
        {Core:$v[0],ApiHost:$v[1],ApiKey:$v[2],NodeID:($v[3]|tonumber),NodeType:$v[4],Timeout:30,
         ListenIP:$v[7],SendIP:"0.0.0.0",DeviceOnlineMinTraffic:200,MinReportTraffic:0,
         CertConfig:{CertMode:$v[5],RejectUnknownSni:false,CertDomain:$v[6],CertFile:$v[9],KeyFile:$v[10],
            Email:"v2bx@github.com",Provider:$v[11],DNSEnv:($v[12]|fromjson)}} |
        if .Core=="xray" then .+{EnableProxyProtocol:false,EnableUot:true,EnableTFO:true,DNSType:"UseIPv4"}
        elif .Core=="sing" then .+{TCPFastOpen:($v[8]=="true"),SniffEnabled:true}
        else .+{ListenIP:"",Hysteria2ConfigPath:($v[13]+"/hy2config.yaml")} end' >> "$candidate/nodes.jsonl" || return 1
    m_line 32 "  ✓ 节点已填写 · ID ${node_id} · ${core} / ${protocol}"
}
m_collect_nodes() {
    local candidate=$1 api_host='' api_key='' fixed=n node_number=1
    m_panel || return 1
    m_ask '后续节点是否共用面板地址与 API Key？[y/N]' || return 1; fixed=$M_REPLY
    while true; do
        m_section "第 ${node_number} 个节点"
        m_node || return 1
        m_ask '是否继续添加节点？[y/N]' || return 1
        [[ $M_REPLY == [yY] ]] || break
        node_number=$((node_number+1))
        [[ $fixed == [yY] ]] || m_panel || return 1
    done
    api_key=''; M_REPLY=''
}
m_core_filter() {
    cat <<'JQ'
def core_config($root):
    if .=="xray" then {Type:.,Log:{Level:"error",ErrorPath:($root+"/error.log")},
      OutboundConfigPath:($root+"/custom_outbound.json"),RouteConfigPath:($root+"/route.json")}
    elif .=="sing" then {Type:.,Log:{Level:"error",Timestamp:true},
      NTP:{Enable:false,Server:"time.apple.com",ServerPort:0},OriginalPath:($root+"/sing_origin.json")}
    else {Type:.,Log:{Level:"error"}} end;
JQ
}
m_build_config() {
    local candidate=$1
    m_collect_nodes "$candidate" || return 1
    { m_core_filter; printf '%s\n' '{Log:{Level:"error",Output:""},Nodes:.,Cores:([.[].Core]|unique|map(core_config($root)))}'; } > "$candidate/cores.jq" || return 1
    jq -s --arg root "$M_CONFIG" -f "$candidate/cores.jq" "$candidate/nodes.jsonl" > "$candidate/config.json" || return 1
    rm "$candidate/cores.jq"
    rm "$candidate/nodes.jsonl"
    write_route_templates "$candidate"
}
# Save all overwritten files, including absence and original ownership/mode.
m_snapshot() {
    local dir=$1 file
    mkdir -m 700 "$dir" || return 1
    for file in "${M_FILES[@]}"; do
        [[ ! -L $M_CONFIG/$file && ( ! -e $M_CONFIG/$file || -f $M_CONFIG/$file ) ]] || return 1
        if [[ -e $M_CONFIG/$file ]]; then cp -p "$M_CONFIG/$file" "$dir/$file" || return 1
        else touch "$dir/$file.absent" || return 1; fi
    done
}
m_restore_files() {
    local dir=$1 file ok=true
    for file in "${M_FILES[@]}"; do
        if [[ -f $dir/$file.absent ]]; then rm -f "$M_CONFIG/$file" || ok=false
        else cp -p "$dir/$file" "$M_CONFIG/$file" || ok=false; fi
    done
    [[ $ok == true ]]
}
m_generate() (
    umask 077
    m_need_install && m_lock && m_standard_config || exit 1
    stage=''; backup=''; armed=false; was_active=false; file=''
    M_FILES=(config.json custom_outbound.json route.json sing_origin.json hy2config.yaml)
    stage=$(mktemp -d "$M_CONFIG/.manager-config.XXXXXX") || exit 1
    m_config_cleanup() {
        local code=$?
        trap - EXIT; trap '' HUP INT TERM
        if [[ $armed == true ]]; then
            if systemctl stop V2bX && m_restore_files "$backup"; then
                if [[ $was_active == true ]]; then systemctl start V2bX || true; fi
                printf '生成配置未完成，已恢复原文件。备份：%s\n' "$backup"
            else printf '恢复不完整，请保持服务停止并检查备份：%s\n' "$backup" >&2; fi
            code=1
        fi
        rm -rf "$stage"
        exit "$code"
    }
    trap m_config_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    m_section '◇ 节点配置向导'
    m_line 33 '  ! 将重新生成节点、出站和路由文件，重置相关 SOCKS 规则。'
    m_line 37 '  沿用上游默认拦截规则；原文件及权限会完整备份。'
    m_confirm '继续生成配置？' || exit 2
    m_build_config "$stage" || exit 1
    for file in config.json custom_outbound.json route.json sing_origin.json; do jq -e . "$stage/$file" >/dev/null || exit 1; done
    m_section '保存与应用'
    m_confirm '确认保存配置并重启整个 V2bX 服务？' || exit 2
    [[ ! -L $M_CONFIG/manager-backups ]] || exit 1
    mkdir -p "$M_CONFIG/manager-backups" && chmod 700 "$M_CONFIG/manager-backups" || exit 1
    backup="$M_CONFIG/manager-backups/config-$(date +%Y%m%d-%H%M%S)-${stage##*.}"
    m_snapshot "$backup" || exit 1
    systemctl is-active --quiet V2bX && was_active=true
    armed=true
    systemctl stop V2bX || exit 1
    for file in "${M_FILES[@]}"; do install -m 600 "$stage/$file" "$M_CONFIG/$file" || exit 1; done
    systemctl start V2bX && m_health || { m_diagnose; exit 1; }
    armed=false
    m_line '1;32' '  ✓ 节点配置已保存，服务运行检查通过。'
    m_line 36 "  备份：${backup}"
)
# Installation layout adapted from upstream install.sh (MPL-2.0).
m_arch() {
    case $(uname -m) in x86_64|amd64) printf 64;; aarch64|arm64) printf arm64-v8a;; s390x) printf s390x;; *) return 1;; esac
}
m_prepare_core() {
    local stage=$1 version=${2:-} arch file entry
    arch=$(m_arch) || return 1
    if [[ -z $version ]]; then
        m_fetch 'https://api.github.com/repos/wyx2685/V2bX/releases/latest' "$stage/release.json" || return 1
        version=$(jq -er '.tag_name' "$stage/release.json") || return 1
    fi
    [[ $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { m_error '版本号无效。'; return 1; }
    printf '正在下载 V2bX %s（%s）……\n' "$version" "$arch"
    m_fetch "https://github.com/wyx2685/V2bX/releases/download/$version/V2bX-linux-$arch.zip" "$stage/core.zip" || return 1
    unzip -tq "$stage/core.zip" >/dev/null || return 1
    unzip -Z1 "$stage/core.zip" > "$stage/entries" || return 1
    while IFS= read -r entry; do
        [[ $entry != /* && $entry != ../* && $entry != */../* && $entry != *\\* ]] || return 1
    done < "$stage/entries"
    mkdir "$stage/new" || return 1
    unzip -q "$stage/core.zip" -d "$stage/new" || return 1
    [[ -z $(find "$stage/new" -type l -print -quit) ]] || { m_error '发布包包含符号链接。'; return 1; }
    for file in V2bX geoip.dat geosite.dat; do [[ -s $stage/new/$file ]] || return 1; done
    chmod 755 "$stage/new/V2bX" || return 1
    "$stage/new/V2bX" version >/dev/null || { m_error '下载的 V2bX 无法运行。'; return 1; }
}
m_write_unit() {
    cat > "$1" <<UNIT
[Unit]
Description=V2bX Service
After=network.target nss-lookup.target
Wants=network.target
[Service]
User=root
Group=root
Type=simple
LimitNOFILE=999999
WorkingDirectory=$M_BINARY
ExecStart=$M_BINARY/V2bX server
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
UNIT
}
m_install_core() (
    umask 077
    stage=''; backup=''; armed=false; existed=false; was_active=false; unit_existed=false; swapped=false; file=''
    M_FILES=(geoip.dat geosite.dat)
    m_lock || exit 1
    m_installed && existed=true
    if [[ $existed == true ]]; then m_standard_config || exit 1; fi
    [[ ! -L $M_BINARY && ! -L $M_UNIT ]] || exit 1
    stage=$(mktemp -d "${M_BINARY%/*}/.v2bx-core.XXXXXX") || exit 1
    m_core_cleanup() {
        local code=$?
        trap - EXIT; trap '' HUP INT TERM
        if [[ $armed == true ]]; then
            local restored=true
            systemctl stop V2bX || restored=false
            if [[ $swapped == true ]]; then rm -rf "$M_BINARY" || restored=false; fi
            if [[ -d $stage/old ]]; then mv "$stage/old" "$M_BINARY" || restored=false; fi
            m_restore_files "$backup/config" || restored=false
            if [[ $unit_existed == true ]]; then cp -p "$backup/unit" "$M_UNIT" || restored=false
            else systemctl disable V2bX >/dev/null 2>&1 || true; rm -f "$M_UNIT" || restored=false; fi
            systemctl daemon-reload || restored=false
            if [[ $restored == true ]]; then
                [[ $was_active != true ]] || systemctl start V2bX || restored=false
            fi
            if [[ $restored == true ]]; then printf '安装 / 更新失败，已恢复原文件和服务状态。\n'
            else printf '恢复未完成，保留现场：%s；备份：%s\n' "$stage" "$backup" >&2; exit 1; fi
            code=1
        fi
        [[ -z $stage ]] || rm -rf "$stage"
        exit "$code"
    }
    trap m_core_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    m_prepare_core "$stage" "${1:-}" || exit 1
    # Existing configurations, credentials and service units are preserved on updates.
    [[ ! -L $M_CONFIG/manager-backups ]] || exit 1
    mkdir -p "$M_CONFIG/manager-backups" && chmod 700 "$M_CONFIG/manager-backups" || exit 1
    backup=$(mktemp -d "$M_CONFIG/manager-backups/core-$(date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
    m_snapshot "$backup/config" || exit 1
    if [[ -f $M_UNIT ]]; then cp -p "$M_UNIT" "$backup/unit" || exit 1; unit_existed=true; fi
    if [[ -d $M_BINARY ]]; then cp -a "$M_BINARY" "$backup/binary" || exit 1; fi
    systemctl is-active --quiet V2bX && was_active=true
    if [[ $unit_existed != true ]]; then m_write_unit "$stage/V2bX.service" || exit 1; fi
    armed=true
    if [[ $existed == true || $unit_existed == true ]]; then systemctl stop V2bX || exit 1; fi
    if [[ -d $M_BINARY ]]; then mv "$M_BINARY" "$stage/old" || exit 1; fi
    mv "$stage/new" "$M_BINARY" || exit 1
    swapped=true
    for file in "${M_FILES[@]}"; do install -m 600 "$M_BINARY/$file" "$M_CONFIG/$file" || exit 1; done
    if [[ $unit_existed != true ]]; then
        install -m 644 "$stage/V2bX.service" "$M_UNIT" && systemctl daemon-reload && systemctl enable V2bX || exit 1
    fi
    if [[ $was_active == true ]]; then systemctl start V2bX && m_health || exit 1; fi
    armed=false
    printf 'V2bX 二进制安装 / 更新完成。备份：%s\n' "$backup"
)
m_install_flow() {
    if m_installed; then printf '检测到已有 V2bX，保留现有节点配置与服务状态。\n'; return 0; fi
    m_install_core "${1:-}" || return 1
    if m_confirm '是否现在填写面板和节点配置？'; then
        local code=0
        m_generate || code=$?
        if [[ $code == 2 ]]; then printf '已取消节点配置，以后运行 v2bx generate。\n'; return 0; fi
        [[ $code == 0 ]] || return "$code"
        # Cancelled wizard leaves no usable config and must not offer SOCKS.
        [[ -f $M_CONFIG/config.json ]] || { printf '尚未配置节点，以后运行 v2bx generate。\n'; return 0; }
        m_offer_socks
    else printf '安装完成，节点尚未配置。以后运行 v2bx generate；完成后可运行 v2bx socks。\n'; fi
}
# Incremental guided node management. Derived configuration conventions: MPL-2.0.
m_node_tag() {
    jq -er 'if (.Name // "")!="" then .Name else "["+.ApiHost+"]-"+(.NodeType|ascii_downcase)+":"+(.NodeID|tostring) end' "$1"
}
m_node_list() {
    jq -r '.Nodes|to_entries[]|"\(.key+1). 名称：\(.value.Name // "未命名" | @json) | 面板：\(.value.ApiHost|@json) | ID：\(.value.NodeID) | 协议：\(.value.NodeType|@json) | 内核：\(.value.Core|@json)"' "$1"
}
m_select_node() {
    local count
    count=$(jq '.Nodes|length' "$1") || return 1
    ((count>0)) || { m_error '当前没有节点，请先选择新增节点。'; return 1; }
    m_node_list "$1" || return 1
    m_ask '请选择要处理的节点序号（0 返回）' || return 1
    [[ $M_REPLY != 0 ]] || return 2
    [[ $M_REPLY =~ ^[1-9][0-9]{0,5}$ ]] && ((M_REPLY<=count)) || { m_error '节点序号无效。'; return 1; }
    N_INDEX=$((M_REPLY-1))
    jq --argjson i "$N_INDEX" '.Nodes[$i]' "$1" > "$N_STAGE/node.before" || return 1
    printf '已选择列表中的第 %s 个节点：\n' "$((N_INDEX+1))"
    jq -r '{Nodes:[.]}' "$N_STAGE/node.before" > "$N_STAGE/selected.json" || return 1
    jq -r '"名称：\(.Name // "未命名"|@json) | 面板：\(.ApiHost|@json) | ID：\(.NodeID) | 协议：\(.NodeType|@json) | 内核：\(.Core|@json)"' "$N_STAGE/node.before"
    m_confirm '确认处理这个节点？' || return 2
}
m_node_core() {
    jq -e --slurpfile node "$N_STAGE/node.before" '
      [.Cores[]|select((if (.Name // "")=="" then .Type else .Name end)==$node[0].Core)] |
      if length==1 then .[0] else error("ambiguous core") end' "$N_STAGE/config.json" > "$N_STAGE/core.json" 2>/dev/null || {
        m_error '所选节点的内核不存在或不唯一。'; return 1;
    }
    N_KIND=$(jq -r '.Type' "$N_STAGE/core.json")
    case $N_KIND in xray|sing|hysteria2) ;; *) m_error '该内核暂不支持引导修改。'; return 1;; esac
}
m_node_set() {
    # The value may be secret: pass over stdin, not through argv.
    local key=$1 value=$2 kind=${3:-string}
    printf '%s' "$value" | jq -Rs --arg key "$key" --arg kind "$kind" --slurpfile node "$N_STAGE/node.after" '
      . as $v | $node[0] | setpath($key|split("."); if $kind=="number" then ($v|tonumber) else $v end)
    ' > "$N_STAGE/node.next" && mv "$N_STAGE/node.next" "$N_STAGE/node.after"
}
m_node_field() {
    local key=$1 prompt=$2 secret=${3:-false} current
    current=$(jq -r --arg key "$key" 'getpath($key|split(".")) // ""' "$N_STAGE/node.after") || return 1
    if [[ $secret == true ]]; then
        m_secret "${prompt}（直接显示，回车保留）" || return 1
    else
        printf '当前值：%s\n' "$(printf '%s' "$current" | jq -Rs .)"
        m_ask "${prompt}（回车保留）" || return 1
    fi
    [[ -n $M_REPLY ]] || return 0
    case $key in
        ApiHost) [[ $M_REPLY =~ ^https?://[^[:space:]]+$ ]] || { m_error '面板地址格式无效。'; return 1; };;
        NodeID) [[ $M_REPLY =~ ^[1-9][0-9]{0,9}$ ]] || { m_error 'Node ID 必须为正整数。'; return 1; };;
    esac
    m_node_set "$key" "$M_REPLY" "$([[ $key == NodeID ]] && printf number || printf string)" || return 1
    M_REPLY=''
}
m_edit_protocol() {
    local proto
    printf '当前协议：%s\n' "$(jq -r '.NodeType|@json' "$N_STAGE/node.after")"
    m_protocol_options '请选择协议 [1-8]（回车保留）' || return 1
    [[ -n $M_REPLY ]] || return 0
    case $M_REPLY in 1) proto=shadowsocks;; 2) proto=vless;; 3) proto=vmess;; 4) proto=hysteria;; 5) proto=hysteria2;; 6) proto=trojan;; 7) proto=tuic;; 8) proto=anytls;; *) return 1;; esac
    case "$N_KIND:$proto" in
        xray:shadowsocks|xray:vless|xray:vmess|xray:trojan|sing:*|hysteria2:hysteria2) ;;
        *) m_error '此协议与当前内核不兼容。'; return 1;;
    esac
    m_node_set NodeType "$proto"
}
m_edit_tls() {
    local mode
    printf '当前证书模式：%s\n' "$(jq -r '.CertConfig.CertMode // "none"|@json' "$N_STAGE/node.after")"
    m_choose 'TLS 证书' '请选择证书模式 [1-5]（回车保留）' 'none（含 Reality）' HTTP DNS '已有证书 file' '自签 self' || return 1
    case $M_REPLY in '') return 0;; 1) mode=none;; 2) mode=http;; 3) mode=dns;; 4) mode=file;; 5) mode=self;; *) return 1;; esac
    m_node_set CertConfig.CertMode "$mode" || return 1
    [[ $mode != none ]] || return 0
    m_node_field CertConfig.CertDomain '证书域名' || return 1
    if [[ $mode == file ]]; then
        m_node_field CertConfig.CertFile '证书文件绝对路径' && m_node_field CertConfig.KeyFile '私钥文件绝对路径' || return 1
        local path
        for path in CertFile KeyFile; do
            path=$(jq -r --arg key "$path" '.CertConfig[$key] // ""' "$N_STAGE/node.after")
            [[ $path == /* && -f $path ]] || { m_error '证书或私钥文件不存在。'; return 1; }
        done
    elif [[ $mode == dns ]]; then
        m_node_field CertConfig.Provider 'DNS Provider' || return 1
        m_secret 'DNS 环境参数 JSON（直接显示，回车保留）' || return 1
        if [[ -n $M_REPLY ]]; then
            printf '%s' "$M_REPLY" | jq -e 'type=="object" and all(.[]; type=="string")' >/dev/null 2>&1 || return 1
            printf '%s' "$M_REPLY" | jq --slurpfile node "$N_STAGE/node.after" '. as $env | $node[0] | .CertConfig.DNSEnv=$env' > "$N_STAGE/node.next" &&
                mv "$N_STAGE/node.next" "$N_STAGE/node.after" || return 1
            M_REPLY=''
        fi
    fi
}
m_edit_existing() {
    local choice old_tag new_tag
    m_node_core || return 1
    cp "$N_STAGE/node.before" "$N_STAGE/node.after" || return 1
    while true; do
        m_section '修改所选节点'
        m_option 1 '面板地址'; m_option 2 '面板 API Key'; m_option 3 '节点 ID'
        m_option 4 '节点协议'; m_option 5 'TLS / 证书'; m_option 6 '监听地址'; m_option 7 '出站源地址'
        m_option 8 '完成修改'; m_option 9 '取消全部修改'
        m_ask '请选择修改项' || return 1; choice=$M_REPLY
        case $choice in
            1) m_node_field ApiHost '面板地址';; 2) m_node_field ApiKey '面板 API Key' true;;
            3) m_node_field NodeID '节点 ID';; 4) m_edit_protocol;; 5) m_edit_tls;;
            6) m_node_field ListenIP '监听 IP 地址';; 7) m_node_field SendIP '出站源 IP 地址';;
            8) break;; 9) return 2;; *) m_error '请选择菜单中的数字。'; return 1;;
        esac || return 1
    done
    if jq -e --slurpfile before "$N_STAGE/node.before" '.==$before[0]' "$N_STAGE/node.after" >/dev/null; then
        printf '没有修改，未保存或重启。\n'; return 3
    fi
    old_tag=$(m_node_tag "$N_STAGE/node.before") && new_tag=$(m_node_tag "$N_STAGE/node.after") || return 1
    # V2bX's Name is the stable inbound tag. Freeze the previous effective tag when
    # changing panel/ID/protocol, so existing SOCKS and custom node rules keep matching.
    if [[ $old_tag != "$new_tag" ]]; then m_node_set Name "$old_tag" || return 1; fi
    jq --argjson i "$N_INDEX" --slurpfile node "$N_STAGE/node.after" '.Nodes[$i]=$node[0]' "$N_STAGE/config.json" > "$N_STAGE/config.next" &&
        mv "$N_STAGE/config.next" "$N_STAGE/config.json"
}
# Track an original once; all new/changed files are published in the same transaction.
m_node_track() {
    local path=$1 i
    [[ $path == /* && $path != *'/../'* && ! -L $path && ( ! -e $path || -f $path ) && -d ${path%/*} ]] || return 1
    for ((i=0;i<${#N_PATHS[@]};i++)); do
        if [[ ${N_PATHS[$i]} == "$path" ]]; then N_FILE_INDEX=$i; return 0; fi
    done
    N_FILE_INDEX=${#N_PATHS[@]}; N_PATHS+=("$path")
    if [[ -f $path ]]; then
        cp -p "$path" "$N_STAGE/$N_FILE_INDEX.before" || return 1
        cp "$path" "$N_STAGE/$N_FILE_INDEX.after" || return 1
    else touch "$N_STAGE/$N_FILE_INDEX.absent" || return 1; fi
}
m_add_existing_core() {
    local candidate="$N_STAGE/new-nodes" kind file count position ref choice total
    local required=()
    mkdir "$candidate" || return 1
    printf '使用与菜单 2 相同的节点填写向导；完成后只追加新节点，保留原有节点和出口配置。\n'
    m_collect_nodes "$candidate" || return 1
    jq -s . "$candidate/nodes.jsonl" > "$candidate/batch.json" || return 1
    total=$(jq length "$candidate/batch.json") || return 1
    for ((position=0;position<total;position++)); do
        jq --argjson i "$position" '.[$i]' "$candidate/batch.json" > "$N_STAGE/node.after" || return 1
        kind=$(jq -r .Core "$N_STAGE/node.after") || return 1
        jq --arg kind "$kind" '[.Cores[]|select(.Type==$kind)]' "$N_STAGE/config.json" > "$candidate/matches.json" || return 1
        count=$(jq length "$candidate/matches.json") || return 1
        if ((count>0)); then
            choice=0
            if ((count>1)); then
                printf '第 %s 个新节点有多个 %s 内核可用，请选择要引用的已有内核：\n' "$((position+1))" "$kind"
                jq -r 'to_entries[]|"\(.key+1). \(.value.Name // .value.Type|@json)"' "$candidate/matches.json"
                m_ask '请选择内核序号' || return 1
                [[ $M_REPLY =~ ^[1-9][0-9]{0,5}$ ]] && ((M_REPLY<=count)) || return 1
                choice=$((M_REPLY-1))
            fi
            ref=$(jq -r --argjson i "$choice" '.[$i]|if (.Name // "")=="" then .Type else .Name end' "$candidate/matches.json") || return 1
            m_node_set Core "$ref" || return 1
        else
            jq -e --arg ref "$kind" 'all(.Cores[]; (if (.Name // "")=="" then .Type else .Name end)!=$ref)' "$N_STAGE/config.json" >/dev/null || {
                m_error '已有其他内核使用相同名称，未修改配置。'; return 1;
            }
            { m_core_filter; printf '%s\n' '$kind|core_config($root)'; } > "$candidate/core.jq" || return 1
            jq -n --arg root "$M_CONFIG" --arg kind "$kind" -f "$candidate/core.jq" > "$N_STAGE/new-core.json" || return 1
            write_route_templates "$candidate" || return 1
            case $kind in xray) required=(custom_outbound.json route.json);; sing) required=(sing_origin.json);; hysteria2) required=(hy2config.yaml);; esac
            for file in "${required[@]}"; do
                if [[ ! -e $M_CONFIG/$file ]]; then
                    m_node_track "$M_CONFIG/$file" || return 1
                    cp "$candidate/$file" "$N_STAGE/$N_FILE_INDEX.after" || return 1
                else
                    [[ -f $M_CONFIG/$file && ! -L $M_CONFIG/$file ]] || return 1
                fi
            done
            jq --slurpfile core "$N_STAGE/new-core.json" '.Cores+=[$core[0]]' "$N_STAGE/config.json" > "$N_STAGE/config.next" &&
                mv "$N_STAGE/config.next" "$N_STAGE/config.json" || return 1
        fi
        jq --slurpfile node "$N_STAGE/node.after" '.Nodes+=[$node[0]]' "$N_STAGE/config.json" > "$N_STAGE/config.next" &&
            mv "$N_STAGE/config.next" "$N_STAGE/config.json" || return 1
    done
    # Enforce the append-only contract before the transaction can publish anything.
    jq -e --slurpfile before "$N_STAGE/0.before" '
      $before[0] as $old |
      .Nodes[:($old.Nodes|length)]==$old.Nodes and
      .Cores[:($old.Cores|length)]==$old.Cores and
      del(.Nodes,.Cores)==($old|del(.Nodes,.Cores))
    ' "$N_STAGE/config.json" >/dev/null || { m_error '原配置保留检查未通过，未保存。'; return 1; }
    printf '本次新增 %s 个节点，原有节点全部保留。\n' "$total"
}
m_delete_node_rules() {
    local tag managed ref path role i
    m_node_core || return 1
    [[ $N_KIND == hysteria2 ]] && return 0
    tag=$(m_node_tag "$N_STAGE/node.before") || return 1
    if command -v sha256sum >/dev/null 2>&1; then managed="v2bx-socks-$(printf '%s' "$tag" | sha256sum | cut -c1-12)"
    else managed="v2bx-socks-$(printf '%s' "$tag" | shasum -a 256 | cut -c1-12)"; fi
    for role in out route; do
        if [[ $N_KIND == sing ]]; then ref=$(jq -r '.OriginalPath // ""' "$N_STAGE/core.json")
        elif [[ $role == out ]]; then ref=$(jq -r '.OutboundConfigPath // ""' "$N_STAGE/core.json")
        else ref=$(jq -r '.RouteConfigPath // ""' "$N_STAGE/core.json"); fi
        [[ -n $ref ]] || continue
        path=$ref; [[ $path == /* ]] || path="$M_BINARY/$path"
        [[ -e $path ]] || { m_error '节点引用的路由 / 出站文件缺失。'; return 1; }
        m_node_track "$path" || return 1; i=$N_FILE_INDEX
        jq --arg tag "$tag" --arg managed "$managed" --arg kind "$N_KIND" --arg role "$role" '
          def managed_out: .tag==$managed or .tag==($managed+"-udp");
          def remove_rules($ik;$ok):
            map(if .[$ok]==$managed or .[$ok]==($managed+"-udp") then
                  if .[$ik]==[$tag] then empty else error("shared managed rule") end
                elif $kind=="sing" and .=={inbound:[$tag],network:"udp",action:"reject"} then empty else . end);
          if $kind=="sing" then
            if $role=="out" then (if has("outbounds") then .outbounds |= map(select(managed_out|not)) else . end)
            else (if (.route // {}|has("rules")) then .route.rules |= remove_rules("inbound";"outbound") else . end) end
          elif $role=="out" then map(select(managed_out|not))
          else (if has("rules") then .rules |= remove_rules("inboundTag";"outboundTag") else . end) end
        ' "$N_STAGE/$i.after" > "$N_STAGE/rules.next" 2>/dev/null || { m_error 'SOCKS 规则存在共享或格式异常，未删除节点。'; return 1; }
        mv "$N_STAGE/rules.next" "$N_STAGE/$i.after" || return 1
    done
}
m_nodes_validate() {
    jq -e '
      def tag: if (.Name // "")!="" then .Name else "["+.ApiHost+"]-"+(.NodeType|ascii_downcase)+":"+(.NodeID|tostring) end;
      . as $m | (.Nodes|type)=="array" and (.Cores|type)=="array" and
      ([.Nodes[]|tag]|length)==([.Nodes[]|tag]|unique|length) and
      ([.Nodes[]|[.ApiHost,(.NodeType|ascii_downcase),.NodeID]]|length)==([.Nodes[]|[.ApiHost,(.NodeType|ascii_downcase),.NodeID]]|unique|length) and
      all(.Nodes[]; . as $n | (.NodeID|type)=="number" and .NodeID>0 and .NodeID==(.NodeID|floor) and
        ([ $m.Cores[]|select((if (.Name // "")=="" then .Type else .Name end)==$n.Core)]|length)==1)
    ' "$N_STAGE/config.json" >/dev/null 2>&1 || { m_error '节点 ID、节点标识重复，或内核引用无效；未保存。'; return 1; }
}
m_nodes_rollback() {
    local i ok=true
    systemctl stop V2bX || return 1
    for ((i=0;i<${#N_PATHS[@]};i++)); do
        if [[ -f $N_STAGE/$i.absent ]]; then rm -f "${N_PATHS[$i]}" || ok=false
        else cp -p "$N_STAGE/$i.before" "${N_PATHS[$i]}" || ok=false; fi
    done
    [[ $ok == true ]] || return 1
    [[ $N_WAS_ACTIVE != true ]] || systemctl start V2bX || return 1
}
# sha256sum is already a required runtime tool; cmp is not present on some
# minimal hosts. Return 0 for equal content, 1 for different content, 2 on error.
m_node_files_equal() {
    local before after
    before=$(sha256sum < "$1") && after=$(sha256sum < "$2") || return 2
    before=${before%% *}; after=${after%% *}
    [[ $before =~ ^[a-f0-9]{64}$ && $after =~ ^[a-f0-9]{64}$ ]] || return 2
    [[ $before == "$after" ]]
}
m_node_check_original() {
    local code=0
    if [[ -L $2 ]]; then code=1
    else m_node_files_equal "$1" "$2" || code=$?; fi
    case $code in
        0) return 0;;
        1) m_error '配置已被其他操作修改，未覆盖。';;
        *) m_error '无法读取或校验配置文件，未覆盖。';;
    esac
    return 1
}
m_nodes_save() {
    local i code changed=false
    cp "$N_STAGE/config.json" "$N_STAGE/0.after" || return 1
    for ((i=0;i<${#N_PATHS[@]};i++)); do
        if [[ -f $N_STAGE/$i.absent ]]; then
            [[ ! -e ${N_PATHS[$i]} && ! -L ${N_PATHS[$i]} ]] || { m_error '配置文件已被其他操作创建，未覆盖。'; return 1; }
            changed=true
        else
            m_node_check_original "$N_STAGE/$i.before" "${N_PATHS[$i]}" || return 1
            code=0; m_node_files_equal "$N_STAGE/$i.before" "$N_STAGE/$i.after" || code=$?
            case $code in
                0) ;;
                1) changed=true;;
                *) m_error '无法读取或校验待保存配置，未保存。'; return 1;;
            esac
        fi
    done
    [[ $changed == true ]] || { printf '没有修改，未保存或重启。\n'; return 0; }
    if [[ $(jq '.Nodes|length' "$N_STAGE/config.json") == 0 ]]; then
        printf '将删除最后一个节点并停止 V2bX 服务。\n'
    else printf '保存后会重启整个 V2bX 服务，现有连接会短暂中断。\n'; fi
    m_confirm '确认备份并应用此次节点操作？' || return 0
    # Recheck after the user prompt: other tools need not honour this lock.
    for ((i=0;i<${#N_PATHS[@]};i++)); do
        if [[ -f $N_STAGE/$i.absent ]]; then [[ ! -e ${N_PATHS[$i]} && ! -L ${N_PATHS[$i]} ]] || return 1
        else m_node_check_original "$N_STAGE/$i.before" "${N_PATHS[$i]}" || return 1; fi
    done
    [[ ! -L $M_CONFIG/manager-backups ]] || return 1
    mkdir -p "$M_CONFIG/manager-backups" && chmod 700 "$M_CONFIG/manager-backups" || return 1
    N_BACKUP=$(mktemp -d "$M_CONFIG/manager-backups/nodes-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
    for ((i=0;i<${#N_PATHS[@]};i++)); do
        if [[ -f $N_STAGE/$i.absent ]]; then touch "$N_BACKUP/$i.absent" || return 1
        else cp -p "$N_STAGE/$i.before" "$N_BACKUP/$i.before" || return 1; fi
    done
    printf '%s\n' "${N_PATHS[@]}" | jq -Rs 'split("\n")|map(select(length>0))' > "$N_BACKUP/paths.json" || return 1
    systemctl is-active --quiet V2bX && N_WAS_ACTIVE=true
    N_ARMED=true
    systemctl stop V2bX || return 1
    for ((i=0;i<${#N_PATHS[@]};i++)); do
        install -m 600 "$N_STAGE/$i.after" "${N_PATHS[$i]}" || return 1
    done
    if [[ $(jq '.Nodes|length' "$N_STAGE/config.json") != 0 ]]; then
        systemctl start V2bX && m_health || { m_diagnose; return 1; }
    fi
    N_ARMED=false
    printf '节点操作已完成。备份：%s\n' "$N_BACKUP"
}
m_edit() (
    umask 077
    m_need_install && m_lock && m_standard_config || exit 1
    [[ -f $M_CONFIG/config.json ]] || { m_error '尚无主配置，请先运行 v2bx generate。'; exit 1; }
    N_STAGE=$(mktemp -d "$M_CONFIG/.manager-nodes.XXXXXX") || exit 1
    N_PATHS=(); N_ARMED=false; N_WAS_ACTIVE=false; N_BACKUP=''; N_INDEX=0; N_KIND=''
    m_nodes_cleanup() {
        local code=$?
        trap - EXIT; trap '' INT TERM HUP
        if [[ $N_ARMED == true ]]; then
            if m_nodes_rollback; then printf '节点操作失败，已恢复原配置和服务状态。\n'
            else printf '恢复未完成，请检查备份：%s\n' "$N_BACKUP" >&2; fi
            code=1
        fi
        rm -rf "$N_STAGE"
        exit "$code"
    }
    trap m_nodes_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    m_node_track "$M_CONFIG/config.json" || exit 1
    cp "$N_STAGE/0.before" "$N_STAGE/config.json" || exit 1
    m_section '节点配置管理'
    m_option 1 '修改现有节点'; m_option 2 '新增节点'; m_option 3 '删除节点'; m_option 4 '返回'
    m_ask '请选择操作' || exit 1
    case $M_REPLY in
        4) exit 0;;
        1|3)
            action=$M_REPLY
            code=0; m_select_node "$N_STAGE/config.json" || code=$?
            [[ $code != 2 ]] || exit 0; [[ $code == 0 ]] || exit "$code"
            if [[ $action == 1 ]]; then
                code=0; m_edit_existing || code=$?
                [[ $code != 2 && $code != 3 ]] || exit 0; [[ $code == 0 ]] || exit "$code"
            else
                # Refuse ambiguous original tags before cleaning any rules.
                m_nodes_validate && m_delete_node_rules || exit 1
                jq --argjson i "$N_INDEX" 'del(.Nodes[$i])' "$N_STAGE/config.json" > "$N_STAGE/config.next" &&
                    mv "$N_STAGE/config.next" "$N_STAGE/config.json" || exit 1
                printf '将删除所选节点及其由 SOCKS 助手生成的出口规则。\n'
            fi;;
        2) m_add_existing_core || exit 1;;
        *) m_error '请选择 1、2、3 或 4。'; exit 1;;
    esac
    m_nodes_validate && m_nodes_save
)
# CLI compatibility adapted from upstream V2bX.sh (MPL-2.0); menu numbers follow display order.
m_update_tools() (
    stage=''; commit=''; base=''; file=''; expected=''
    umask 077
    stage=$(mktemp -d /tmp/v2bx-tools.XXXXXX) || exit 1
    trap 'rm -rf "$stage"' EXIT
    m_fetch 'https://api.github.com/repos/joyefrck/v2bx_Outbound/git/ref/heads/main' "$stage/head.json" || exit 1
    commit=$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' "$stage/head.json") || exit 1
    base="https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/$commit"
    for file in install.sh SHA256SUMS; do m_fetch "$base/$file" "$stage/$file" || exit 1; done
    expected=$(awk '$2=="install.sh" && NF==2 {print $1}' "$stage/SHA256SUMS")
    [[ $expected =~ ^[0-9a-f]{64}$ && $(sha256sum "$stage/install.sh" | cut -d ' ' -f 1) == "$expected" ]] || exit 1
    bash -n "$stage/install.sh" || exit 1
    m_confirm '更新本仓库管理工具与 SOCKS 助手（不更新内核、不重启节点）？' || exit 0
    bash "$stage/install.sh" --tools-only --commit "$commit"
)
m_uninstall() (
    m_need_install && m_lock || exit 1
    m_confirm '卸载 V2bX 并删除所有节点、出口配置和备份？' || exit 0
    systemctl stop V2bX && systemctl disable V2bX || exit 1
    rm -f "$M_UNIT" && systemctl daemon-reload || exit 1
    rm -rf "$M_BINARY" "$M_CONFIG" || exit 1
    printf 'V2bX 已卸载；保留管理工具，可再次运行 v2bx install。\n'
)
m_service() (
    m_need_install && m_lock || exit 1
    systemctl "$1" V2bX || exit 1
    case $1 in start|restart) m_health || { m_diagnose; exit 1; };; esac
)
m_bbr() (
    m_confirm '运行上游菜单原有 BBR 工具（可能更新系统内核）？' || exit 0
    file=$(mktemp /tmp/v2bx-bbr.XXXXXX) || exit 1
    trap 'rm -f "$file"' EXIT
    m_fetch 'https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh' "$file" && bash -n "$file" && bash "$file"
)
m_open_ports() {
    m_confirm '放行所有网络端口（停用防火墙并清空 iptables 规则）？' || return 0
    if command -v ufw >/dev/null; then ufw disable || return 1; fi
    if systemctl is-active --quiet firewalld; then systemctl disable --now firewalld || return 1; fi
    if command -v iptables >/dev/null; then
        iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F || return 1
    fi
}
m_show_status() {
    local state line active='' sub='' load='' enabled='' status='未知（无法读取服务状态）' autostart='未知' tone=33
    if ! m_installed; then
        m_line 33 '  V2bX 状态：未安装'
        return 0
    fi
    if state=$(systemctl show V2bX --property=LoadState,ActiveState,SubState 2>/dev/null); then
        while IFS= read -r line; do
            case $line in LoadState=*) load=${line#*=};; ActiveState=*) active=${line#*=};; SubState=*) sub=${line#*=};; esac
        done <<< "$state"
        if [[ $load == not-found ]]; then
            status='服务未注册'
        elif [[ $sub == auto-restart ]]; then
            status='重启中'
        else
            case $active in
                active) if [[ $sub == running ]]; then status='已运行'; else status='未运行'; fi;;
                inactive) status='未运行';;
                failed) status='启动失败';;
                activating) status='启动中';;
                deactivating) status='停止中';;
                reloading) status='重新加载中';;
            esac
        fi
    fi
    enabled=$(systemctl is-enabled V2bX 2>/dev/null) || :
    case $enabled in
        enabled) autostart='是';;
        enabled-runtime) autostart='否（仅本次运行期间启用）';;
        disabled|static|indirect|masked|masked-runtime|not-found) autostart='否';;
    esac
    case $status in 已运行) tone=32;; 启动失败|服务未注册) tone=31;; esac
    m_line "$tone" "  V2bX 状态：${status}"
    if [[ $autostart == 是 ]]; then tone=32; else tone=33; fi
    m_line "$tone" "  是否开机自启：${autostart}"
}
m_logs() (
    # Catch Ctrl+C in this viewing session so it does not close the parent menu.
    trap ':' INT
    local code
    m_line 37 "正在持续查看最近 100 条及新增日志；按 Ctrl+C ${1:-结束查看}。"
    journalctl -u V2bX -n 100 --no-pager -f
    code=$?
    [[ $code == 130 ]] && return 0
    return "$code"
)
m_menu() {
    local choice
    while true; do
        m_banner
        m_show_status
        m_section '◇ 节点与出口'
        m_option 1 '修改配置（节点管理）'
        m_option 2 '生成节点配置'
        m_option 3 'SOCKS 出口管理'
        m_option 4 '查看 V2bX 状态'
        m_option 5 '查看日志'
        m_section '↻ 服务控制'
        m_option 6 '启动 V2bX'
        m_option 7 '停止 V2bX'
        m_option 8 '重启 V2bX'
        m_option 9 '设置开机自启'
        m_option 10 '取消开机自启'
        m_section '⚙ 安装与维护'
        m_option 11 '安装 V2bX'
        m_option 12 '更新 V2bX 内核'
        m_option 13 '更新管理工具（含 SOCKS 助手）'
        m_option 14 '查看 V2bX 版本'
        m_option 15 '生成 X25519 密钥'
        m_option 16 '安装 BBR'
        m_option 17 '放行所有网络端口'
        m_option 18 '卸载 V2bX'
        printf '\n'; m_option 19 '退出 · 下次见'
        m_ask '请选择 [1-19]' || return 0; choice=$M_REPLY
        case $choice in
            1) m_edit;; 11) m_install_flow;;
            12) m_ask '指定内核版本（回车为最新）' && m_need_install && m_install_core "$M_REPLY";;
            18) m_uninstall;; 6) m_service start;; 7) m_service stop;; 8) m_service restart;;
            4) systemctl status V2bX --no-pager;; 5) m_logs '返回菜单';;
            9) m_service enable;; 10) m_service disable;; 16) m_bbr;;
            14) m_need_install && "$M_BINARY/V2bX" version;; 15) m_need_install && "$M_BINARY/V2bX" x25519;;
            13) m_update_tools && exec bash "$M_SELF";;
            2) m_generate && [[ -f $M_CONFIG/config.json ]] && m_offer_socks;;
            17) m_open_ports;; 19) return 0;; 3) m_socks;; *) m_line 33 '请输入 1-19。';;
        esac
    done
}
m_help() {
    printf '%s\n' 'V2bX 安装与可选 SOCKS 出口管理' \
      'v2bx / V2bX         打开统一菜单' \
      'v2bx install [版本]  安装内核并引导配置；已有安装不重装' \
      'v2bx config         引导修改、新增或删除节点' \
      'v2bx generate       生成节点配置并可选配置 SOCKS' \
      'v2bx socks          打开 SOCKS 出口助手' \
      'v2bx update [版本]   仅更新 V2bX 内核' \
      'v2bx update_shell   更新本仓库管理工具与助手' \
      'v2bx start|stop|restart|status|enable|disable|log|config|uninstall|x25519|version' \
      'v2bx --version      查看管理工具版本；v2bx-socks 保持兼容'
}
m_main() {
    case ${1:-} in --help|-h) m_help; return 0;; --version) printf '%s\n' "$MANAGER_VERSION"; return 0;;
        ''|install|generate|socks|update|update_shell|start|stop|restart|status|enable|disable|log|config|uninstall|x25519|version) ;;
        *) m_help; return 1;; esac
    [[ $EUID == 0 ]] || { m_error '请使用 root 用户运行。'; return 1; }
    m_platform && m_dependencies || return 1
    umask 077
    case ${1:-} in ''|install|generate|socks|update_shell|config|uninstall)
        exec 9<>/dev/tty || { m_error '请在交互终端运行。'; return 1; };; esac
    case ${1:-} in
        '') m_menu;; install) m_install_flow "${2:-}";;
        generate) m_generate && [[ -f $M_CONFIG/config.json ]] && m_offer_socks;;
        socks) m_socks;; update) m_need_install && m_install_core "${2:-}";;
        update_shell) m_update_tools;; start|stop|restart|enable|disable) m_service "$1";;
        status) systemctl status V2bX --no-pager;; log) m_logs;;
        config) m_edit;; uninstall) m_uninstall;; x25519|version) m_need_install && "$M_BINARY/V2bX" "$1";;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then m_main "$@"; fi
