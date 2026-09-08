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
        m_secret "${prompt}（回车保留，当前值隐藏）" || return 1
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
    m_ask '协议：1. Shadowsocks  2. VLESS  3. VMess  4. Hysteria  5. Hysteria2  6. Trojan  7. TUIC  8. AnyTLS（回车保留）' || return 1
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
    m_ask '证书模式：1. none（含 Reality）  2. HTTP  3. DNS  4. 已有证书 file  5. 自签 self（回车保留）' || return 1
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
        m_secret 'DNS 环境参数 JSON（隐藏输入，回车保留）' || return 1
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
        printf '%s\n' '修改所选节点（其他配置保留）：' '1. 面板地址' '2. 面板 API Key' '3. 节点 ID' \
            '4. 节点协议' '5. TLS / 证书' '6. 监听地址' '7. 出站源地址' '0. 完成修改' '9. 取消全部修改'
        m_ask '请选择修改项' || return 1; choice=$M_REPLY
        case $choice in
            1) m_node_field ApiHost '面板地址';; 2) m_node_field ApiKey '面板 API Key' true;;
            3) m_node_field NodeID '节点 ID';; 4) m_edit_protocol;; 5) m_edit_tls;;
            6) m_node_field ListenIP '监听 IP 地址';; 7) m_node_field SendIP '出站源 IP 地址';;
            0) break;; 9) return 2;; *) m_error '请选择菜单中的数字。'; return 1;;
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
    local count index core_ref M_NODE_CORE='' candidate="$N_STAGE/new-node" api_host='' api_key='' kind file
    count=$(jq '.Cores|length' "$N_STAGE/config.json") || return 1
    printf '选择新增节点使用的内核：\n'
    jq -r '.Cores|to_entries[]|"\(.key+1). \(.value.Name // .value.Type|@json)（\(.value.Type)）"' "$N_STAGE/config.json"
    printf '0. 创建另一种内核\n'
    m_ask '请选择内核序号' || return 1
    [[ $M_REPLY =~ ^[0-9]{1,6}$ ]] && ((10#$M_REPLY<=count)) || return 1
    index=$((10#$M_REPLY-1))
    if ((index>=0)); then
        M_NODE_CORE=$(jq -r --argjson i "$index" '.Cores[$i].Type' "$N_STAGE/config.json")
        core_ref=$(jq -r --argjson i "$index" '.Cores[$i]|if (.Name // "")=="" then .Type else .Name end' "$N_STAGE/config.json")
        case $M_NODE_CORE in xray|sing|hysteria2) ;; *) m_error '该内核暂不支持新增向导。'; return 1;; esac
    fi
    mkdir "$candidate" || return 1
    m_panel && m_node || return 1
    api_key=''; M_REPLY=''
    if ((index>=0)); then
        jq --arg ref "$core_ref" '.Core=$ref' "$candidate/nodes.jsonl" > "$N_STAGE/node.after" || return 1
    else
        cp "$candidate/nodes.jsonl" "$N_STAGE/node.after" || return 1
        kind=$(jq -r .Core "$N_STAGE/node.after")
        # Existing named cores are explicitly selectable above; never duplicate refs.
        jq -e --arg ref "$kind" 'all(.Cores[]; (if (.Name // "")=="" then .Type else .Name end)!=$ref)' "$N_STAGE/config.json" >/dev/null || {
            m_error '此内核已存在，请返回并选择已有内核。'; return 1;
        }
        jq -n --arg kind "$kind" --arg root "$M_CONFIG" '
          if $kind=="xray" then {Type:$kind,Log:{Level:"error",ErrorPath:($root+"/error.log")},OutboundConfigPath:($root+"/custom_outbound.json"),RouteConfigPath:($root+"/route.json")}
          elif $kind=="sing" then {Type:$kind,Log:{Level:"error",Timestamp:true},NTP:{Enable:false,Server:"time.apple.com",ServerPort:0},OriginalPath:($root+"/sing_origin.json")}
          else {Type:$kind,Log:{Level:"error"}} end' > "$N_STAGE/new-core.json" || return 1
        write_route_templates "$candidate" || return 1
        local required=()
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
        mv "$N_STAGE/config.next" "$N_STAGE/config.json"
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
m_nodes_save() {
    local i changed=false
    cp "$N_STAGE/config.json" "$N_STAGE/0.after" || return 1
    for ((i=0;i<${#N_PATHS[@]};i++)); do
        if [[ -f $N_STAGE/$i.absent ]]; then
            [[ ! -e ${N_PATHS[$i]} && ! -L ${N_PATHS[$i]} ]] || { m_error '配置文件已被其他操作创建，未覆盖。'; return 1; }
            changed=true
        else
            [[ ! -L ${N_PATHS[$i]} ]] && cmp -s "$N_STAGE/$i.before" "${N_PATHS[$i]}" || { m_error '配置已被其他操作修改，未覆盖。'; return 1; }
            cmp -s "$N_STAGE/$i.before" "$N_STAGE/$i.after" || changed=true
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
        else [[ ! -L ${N_PATHS[$i]} ]] && cmp -s "$N_STAGE/$i.before" "${N_PATHS[$i]}" || return 1; fi
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
    printf '%s\n' '节点配置管理' '1. 修改现有节点' '2. 新增节点' '3. 删除节点' '0. 返回'
    m_ask '请选择操作' || exit 1
    case $M_REPLY in
        0) exit 0;;
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
        *) m_error '请选择 0、1、2 或 3。'; exit 1;;
    esac
    m_nodes_validate && m_nodes_save
)
