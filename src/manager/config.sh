# Shared node wizard, adapted from upstream initconfig.sh (MPL-2.0).
m_panel() {
    m_ask '请输入面板网址（https://example.com）' || return 1
    [[ $M_REPLY =~ ^https?://[^[:space:]]+$ ]] || { m_error '面板地址须以 http:// 或 https:// 开头。'; return 1; }
    api_host=$M_REPLY
    m_secret '请输入面板对接 API Key（隐藏输入）' || return 1
    [[ -n $M_REPLY ]] || return 1
    api_key=$M_REPLY; M_REPLY=''
}
m_node() {
    local core node_id protocol reality=n tls=n certmode=none domain=example.com fast=true listen=0.0.0.0 certfile keyfile provider='' dnsenv='{}'
    if [[ -n ${M_NODE_CORE:-} ]]; then core=$M_NODE_CORE
    else
        m_ask '节点核心：1. Xray  2. sing-box  3. 独立 Hysteria2' || return 1
        case $M_REPLY in 1) core=xray;; 2) core=sing;; 3) core=hysteria2;; *) m_error '请选择 1、2 或 3。'; return 1;; esac
    fi
    m_ask '请输入节点 Node ID（正整数）' || return 1
    [[ $M_REPLY =~ ^[1-9][0-9]{0,9}$ ]] || { m_error 'Node ID 必须为正整数。'; return 1; }
    node_id=$M_REPLY
    if [[ $core == hysteria2 ]]; then protocol=hysteria2
    else
        m_ask '协议：1. Shadowsocks  2. VLESS  3. VMess  4. Hysteria  5. Hysteria2  6. Trojan  7. TUIC  8. AnyTLS' || return 1
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
        m_ask '证书模式：1. HTTP 自动申请  2. DNS 自动申请  3. 已有证书（file）  4. 自签证书（self）' || return 1
        case $M_REPLY in 1) certmode=http;; 2) certmode=dns;; 3) certmode=file;; 4) certmode=self;; *) return 1;; esac
        m_ask '请输入证书域名' || return 1; domain=$M_REPLY
        [[ -n $domain ]] || return 1
        if [[ $certmode == file ]]; then
            m_ask '证书文件绝对路径' || return 1; certfile=$M_REPLY
            m_ask '私钥文件绝对路径' || return 1; keyfile=$M_REPLY
            [[ $certfile == /* && $keyfile == /* && -f $certfile && -f $keyfile ]] || { m_error '证书和私钥文件必须存在。'; return 1; }
        elif [[ $certmode == dns ]]; then
            m_ask 'DNS Provider（例如 cloudflare）' || return 1; provider=$M_REPLY
            m_secret 'DNS 环境参数 JSON（例如 {"CF_DNS_API_TOKEN":"…"}，隐藏输入）' || return 1
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
        else .+{ListenIP:"",Hysteria2ConfigPath:($v[13]+"/hy2config.yaml")} end' >> "$candidate/nodes.jsonl"
}
m_build_config() {
    local candidate=$1 api_host='' api_key='' fixed=n
    m_panel || return 1
    m_ask '后续节点是否共用面板地址与 API Key？[y/N]' || return 1; fixed=$M_REPLY
    while true; do
        m_node || return 1
        m_ask '是否继续添加节点？[y/N]' || return 1
        [[ $M_REPLY == [yY] ]] || break
        [[ $fixed == [yY] ]] || m_panel || return 1
    done
    api_key=''; M_REPLY=''
    jq -s --arg root "$M_CONFIG" '
      {Log:{Level:"error",Output:""},Nodes:.,Cores:([.[].Core]|unique|map(
        if .=="xray" then {Type:.,Log:{Level:"error",ErrorPath:($root+"/error.log")},
          OutboundConfigPath:($root+"/custom_outbound.json"),RouteConfigPath:($root+"/route.json")}
        elif .=="sing" then {Type:.,Log:{Level:"error",Timestamp:true},NTP:{Enable:false,Server:"time.apple.com",ServerPort:0},OriginalPath:($root+"/sing_origin.json")}
        else {Type:.,Log:{Level:"error"}} end))}' "$candidate/nodes.jsonl" > "$candidate/config.json" || return 1
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
    printf '向导会重新生成节点、出站和路由文件，重置相关 SOCKS 规则；沿用上游默认拦截规则。原文件及权限会完整备份。\n'
    m_confirm '继续生成配置？' || exit 2
    m_build_config "$stage" || exit 1
    for file in config.json custom_outbound.json route.json sing_origin.json; do jq -e . "$stage/$file" >/dev/null || exit 1; done
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
    printf '节点配置已保存，服务运行检查通过。备份：%s\n' "$backup"
)
