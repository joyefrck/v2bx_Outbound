#!/usr/bin/env bash
# V2bX SOCKS Helper 2.0 - Bash + jq + curl. No Python runtime required.
set -uo pipefail

VERSION=2.0.1
TASK_DIR='' TX_DIR='' ATOMIC_TMP=''
TX_ARMED=false TTY_MODE=''
CONFIG_PATH='' WORK_DIR='' BACKUP_ROOT=''
FILES=()

say() { printf '%s\n' "$*"; }
fail() { printf '未完成：%s\n' "$*" >&2; return 1; }
ask() {
    local prompt=$1 default=${2:-}
    printf '%s' "$prompt" >&9
    [[ -z $default ]] || printf ' [%s]' "$default" >&9
    printf '：' >&9
    IFS= read -r REPLY <&9 || return 1
    [[ -n $REPLY ]] || REPLY=$default
}
confirm() { ask "$1（输入 y 确认，回车取消）" && [[ $REPLY == y || $REPLY == Y ]]; }
secret_read() {
    local result=0
    TTY_MODE=$(stty -g <&9) || return 1
    stty -echo <&9 || return 1
    printf '%s：' "$1" >&9
    IFS= read -r REPLY <&9 || result=$?
    stty "$TTY_MODE" <&9
    TTY_MODE=''
    printf '\n' >&9
    return "$result"
}

hash_file() {
    if [[ ! -f $1 || -L $1 ]]; then return 1; fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 -- "$1" | cut -d ' ' -f 1
    fi
}
hash_text() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-12
}
metadata() { stat -c '%a %u %g' "$1" 2>/dev/null || stat -f '%Lp %u %g' "$1"; }
safe_path() { [[ $1 == /* && $1 != *'/../'* && $1 != */.. && $1 =~ ^/[A-Za-z0-9_./+-]+$ && ! -L $1 && -f $1 ]]; }
valid_json() { jq -e -s 'length == 1' "$1" >/dev/null 2>&1; }
flush_file() {
    # GNU sync accepts a file; other platforms are used only for development tests.
    if [[ $(uname -s) == Linux ]]; then sync -f "$1"; fi
}
atomic_copy() {
    local src=$1 dest=$2 mode=${3:-600} owner=${4:-}
    [[ ! -L $dest && -d ${dest%/*} ]] || return 1
    ATOMIC_TMP=$(mktemp "${dest%/*}/.v2bx-socks.XXXXXX") || return 1
    if ! cp "$src" "$ATOMIC_TMP" || ! chmod "$mode" "$ATOMIC_TMP"; then
        rm -f "$ATOMIC_TMP"; ATOMIC_TMP=''; return 1
    fi
    if [[ -n $owner ]] && ! chown "$owner" "$ATOMIC_TMP"; then
        rm -f "$ATOMIC_TMP"; ATOMIC_TMP=''; return 1
    fi
    flush_file "$ATOMIC_TMP" || return 1
    mv -f "$ATOMIC_TMP" "$dest" || return 1
    ATOMIC_TMP=''
    flush_file "${dest%/*}"
}

service_state() {
    systemctl show V2bX.service --property=LoadState,ActiveState,SubState,MainPID,NRestarts,ExecStart,WorkingDirectory 2>/dev/null
}
property() { sed -n "s/^$1=//p"; }
discover() {
    local state cmd arg path=/etc/V2bX/config.json i=2
    local args=()
    state=$(service_state) || { fail '无法读取 systemd 服务。'; return 1; }
    [[ $(printf '%s\n' "$state" | property LoadState) == loaded ]] || { fail '请先用原脚本安装并配置 V2bX。'; return 1; }
    cmd=$(printf '%s\n' "$state" | property ExecStart)
    [[ $cmd == *'argv[]='* ]] || { fail '服务启动命令不受支持。'; return 1; }
    cmd=${cmd#*argv\[\]=}; cmd=${cmd%% ;*}
    read -r -a args <<< "$cmd"
    [[ ${#args[@]} -ge 2 && ${args[0]##*/} == V2bX && ${args[1]} == server ]] || { fail '服务未使用标准 V2bX 启动方式。'; return 1; }
    while (( i < ${#args[@]} )); do
        arg=${args[$i]}
        case $arg in
            -c|--config) i=$((i+1)); (( i < ${#args[@]} )) || return 1; path=${args[$i]} ;;
            --config=*) path=${arg#*=} ;;
            -w|--watch|--watch=true|--watch=false) ;;
            *) fail '服务含非标准启动参数，助手不自动修改。'; return 1 ;;
        esac
        i=$((i+1))
    done
    WORK_DIR=$(printf '%s\n' "$state" | property WorkingDirectory)
    [[ -n $WORK_DIR ]] || WORK_DIR=/
    [[ $path == /* ]] || path="$WORK_DIR/$path"
    safe_path "$path" && valid_json "$path" || { fail '主配置不是普通标准 JSON 文件，或路径含特殊字符。'; return 1; }
    CONFIG_PATH=$path
    BACKUP_ROOT=${CONFIG_PATH%/*}/socks-helper-backups
}
diagnosis() {
    if journalctl -u V2bX.service -n 60 --no-pager -o cat 2>/dev/null | grep -Fq 'Server does not exist'; then
        say '面板返回 Server does not exist：请检查节点 ID、协议和面板通信密钥。'
    else
        say 'V2bX 尚未稳定运行或没有节点监听，请先通过原 V2bX 菜单检查。'
    fi
}
healthy() {
    local seconds=${1:-5} state pid identity='' current i
    for ((i=0; i<=seconds; i++)); do
        state=$(service_state) || return 1
        [[ $(printf '%s\n' "$state" | property ActiveState) == active && $(printf '%s\n' "$state" | property SubState) == running ]] || return 1
        pid=$(printf '%s\n' "$state" | property MainPID)
        [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
        current="$pid:$(printf '%s\n' "$state" | property NRestarts)"
        [[ -z $identity || $identity == "$current" ]] || return 1
        identity=$current
        ss -H -lntup 2>/dev/null | grep -Eq "pid=$pid," || return 1
        (( i == seconds )) || sleep 1
    done
}
service_stop() { systemctl stop V2bX.service >/dev/null 2>&1; }
service_start_check() {
    local initial state i
    systemctl start V2bX.service >/dev/null 2>&1 || return 1
    initial=$(service_state | property NRestarts) || return 1
    for ((i=0; i<35; i++)); do
        state=$(service_state) || return 1
        [[ $(printf '%s\n' "$state" | property NRestarts) == "$initial" ]] || return 1
        [[ $(printf '%s\n' "$state" | property SubState) != auto-restart ]] || return 1
        if healthy 0; then healthy 15; return $?; fi
        sleep 1
    done
    return 1
}

validate_endpoint() {
    jq -e '
      (.host|type=="string") and (.host|length>0 and length<=253) and
      (.host|test("^[A-Za-z0-9][A-Za-z0-9.-]*$|^[0-9a-fA-F:]+$")) and
      (.port|type=="number") and (.port>=1 and .port<=65535 and .port==(.port|floor)) and
      (.username|type=="string") and (.password|type=="string") and
      ((.username=="") == (.password=="")) and
      ([.username,.password]|all(.[]; utf8bytelength<=255 and (test("[\\x00-\\x1f\\x7f]")|not))) and
      (.udp|type=="boolean")
    ' "$1" >/dev/null 2>&1
}
probe_socks() {
    local endpoint=$1 url=${2:-https://api.ipify.org} result
    validate_endpoint "$endpoint" || { fail 'SOCKS 地址、端口或账号格式不正确。'; return 1; }
    # URL-encode credentials, then quote the whole URL for curl config syntax.
    # Neither password nor proxy URL is placed in process arguments.
    if ! jq -r '
      "proxy = " + ("socks5h://" +
      (if .username=="" then "" else (.username|@uri)+":"+(.password|@uri)+"@" end) +
      (if (.host|contains(":")) then "["+.host+"]" else .host end) + ":"+(.port|tostring)|@json)
    ' "$endpoint" | curl -q --config - --noproxy '' --silent --show-error --fail \
        --connect-timeout 8 --max-time 15 --max-filesize 256 --url "$url" \
        > "$TASK_DIR/exit-ip" 2> "$TASK_DIR/curl-error"; then
        fail 'SOCKS 测试未通过，请检查地址、账号、IP 白名单和网络。'; return 1
    fi
    result=$(cat "$TASK_DIR/exit-ip")
    if ! printf '%s' "$result" | jq -Re '
      (test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$") and (split(".")|all(.[]; tonumber>=0 and tonumber<=255))) or
      (test("^[0-9a-fA-F:]+$") and contains(":"))' >/dev/null 2>&1; then
        fail '出口查询未返回有效 IP 地址，未保存配置。'; return 1
    fi
    say "SOCKS TCP / HTTPS 测试通过，当前出口 IP：$result"
    say '请与你购买的出口信息核对；这不代表 UDP 或客户端完整链路已验证。'
}
ask_endpoint() {
    local host port user password=''
    say '请分别填写 SOCKS5 地址、端口和认证信息。'
    ask 'SOCKS 地址（只填 IP 或域名）' || return 1; host=$REPLY
    host=${host#[}; host=${host%]}
    ask 'SOCKS 端口' 1080 || return 1; port=$REPLY
    [[ $port =~ ^[0-9]{1,5}$ ]] || { fail '端口应为 1—65535 的整数。'; return 1; }
    ask '用户名（无认证 / IP 白名单直接回车）' || return 1; user=$REPLY
    if [[ -n $user ]]; then
        secret_read '密码（输入时不显示）' || return 1
        password=$REPLY; REPLY=''
    fi
    # jq consumes fields over stdin; do not pass credentials using --arg.
    printf '%s\n' "$host" "$port" "$user" "$password" | jq -Rn '
      [inputs] | {host:.[0],port:(.[1]|tonumber),username:.[2],password:.[3],udp:false}
    ' > "$TASK_DIR/endpoint.json" || return 1
    unset password user
    probe_socks "$TASK_DIR/endpoint.json"
}

build_candidate() {
    local index=$1 endpoint=$2 ci ref other i
    cp "$CONFIG_PATH" "$TASK_DIR/config.before" || return 1
    CONFIG_SHA=$(hash_file "$TASK_DIR/config.before") || return 1
    jq -e --argjson n "$index" '
      . as $m | .Nodes[$n] as $node |
      if ($node|type)!="object" then error("node") else
      [.Cores|to_entries[]|select((if (.value.Name // "")=="" then .value.Type else .value.Name end)==$node.Core)] as $cs |
      if ($cs|length)!=1 then error("core") else
      {index:$cs[0].key,kind:$cs[0].value.Type,core:$cs[0].value,node:$node,
       tag:(if ($node.Name // "")!="" then $node.Name else "["+$node.ApiHost+"]-"+($node.NodeType|ascii_downcase)+":"+($node.NodeID|tostring) end)} end end
    ' "$TASK_DIR/config.before" > "$TASK_DIR/selection.json" 2>/dev/null || { fail '节点或内核标识不明确。'; return 1; }
    CORE_KIND=$(jq -r '.kind' "$TASK_DIR/selection.json")
    ci=$(jq -r '.index' "$TASK_DIR/selection.json")
    NODE_TAG=$(jq -r '.tag' "$TASK_DIR/selection.json")
    [[ $CORE_KIND == xray || $CORE_KIND == sing ]] || { fail '仅支持 Xray / sing-box 内核。'; return 1; }
    jq -e --slurpfile s "$TASK_DIR/selection.json" '
      [.Nodes[] | (if (.Name // "")!="" then .Name else "["+.ApiHost+"]-"+(.NodeType|ascii_downcase)+":"+(.NodeID|tostring) end) | select(.==$s[0].tag)] | length==1
    ' "$TASK_DIR/config.before" >/dev/null 2>&1 || { fail '多个节点的入站标识相同，不能安全区分。'; return 1; }
    TAG="v2bx-socks-$(printf '%s' "$NODE_TAG" | hash_text)"
    FILES=()
    if [[ $CORE_KIND == xray ]]; then
        ref=$(jq -r '.core.OutboundConfigPath // ""' "$TASK_DIR/selection.json"); FILES+=("$ref")
        ref=$(jq -r '.core.RouteConfigPath // ""' "$TASK_DIR/selection.json"); FILES+=("$ref")
    else
        ref=$(jq -r '.core.OriginalPath // ""' "$TASK_DIR/selection.json"); FILES+=("$ref")
    fi
    for ((i=0;i<${#FILES[@]};i++)); do
        ref=${FILES[$i]}
        [[ -n $ref ]] || { fail '内核尚未配置出站文件路径，请先使用原脚本生成节点配置。'; return 1; }
        [[ $ref == /* ]] || ref="$WORK_DIR/$ref"
        safe_path "$ref" && valid_json "$ref" && [[ $ref != "$CONFIG_PATH" ]] || { fail '出站或路由不是普通标准 JSON 文件。'; return 1; }
        FILES[$i]=$ref
        cp "$ref" "$TASK_DIR/$i.before" || return 1
        # Refuse aliases shared with another core, even if it uses a different field.
        while IFS= read -r other; do
            [[ -n $other ]] || continue
            [[ $other == /* ]] || other="$WORK_DIR/$other"
            [[ $other != "$ref" ]] || { fail '多个内核共用出站文件，助手不自动修改。'; return 1; }
        done < <(jq -r --argjson ci "$ci" '.Cores|to_entries[]|select(.key!=$ci)|.value|[.OriginalPath,.OutboundConfigPath,.RouteConfigPath,.DnsConfigPath,.InboundConfigPath][]|select(type=="string" and length>0)' "$TASK_DIR/config.before")
    done
    [[ ${#FILES[@]} == 1 || ${FILES[0]} != "${FILES[1]}" ]] || { fail '出站与路由不能共用同一文件。'; return 1; }
    if [[ $CORE_KIND == xray ]]; then
        jq -n --slurpfile out "$TASK_DIR/0.before" --slurpfile route "$TASK_DIR/1.before" '{out:$out[0],route:$route[0]}' > "$TASK_DIR/input.json" || return 1
    else
        jq '{origin:.,out:(.outbounds // []),route:(.route // {})}' "$TASK_DIR/0.before" > "$TASK_DIR/input.json" || return 1
    fi
    transform_filter > "$TASK_DIR/transform.jq"
    if ! jq --slurpfile endpoint "$endpoint" --slurpfile selection "$TASK_DIR/selection.json" \
        --arg tag "$TAG" -f "$TASK_DIR/transform.jq" "$TASK_DIR/input.json" \
        > "$TASK_DIR/generated.json" 2> "$TASK_DIR/transform-error"; then
        fail '现有路由不适合自动修改：请确认没有复杂分流、负载均衡、重复出站标识或无效 DNS 设置。'; return 1
    fi
    if [[ $CORE_KIND == xray ]]; then
        jq '.out' "$TASK_DIR/generated.json" > "$TASK_DIR/0.after" || return 1
        jq '.route' "$TASK_DIR/generated.json" > "$TASK_DIR/1.after" || return 1
    else
        jq '.origin' "$TASK_DIR/generated.json" > "$TASK_DIR/0.after" || return 1
    fi
}
transform_filter() {
cat <<'JQ'
def require($ok): if $ok then . else error("unsupported configuration") end;
. as $input | $selection[0] as $s | $endpoint[0] as $e |
($s.kind=="sing") as $sing | $s.tag as $in |
(if $sing then "outbound" else "outboundTag" end) as $ok |
(if $sing then "inbound" else "inboundTag" end) as $ik |
(if $sing then "type" else "protocol" end) as $pk |
require((.out|type)=="array" and (.route|type)=="object") |
require(all(.out[]; type=="object")) |
require((.route.balancers // [] | length)==0) |
require(([.out[].tag|select(.!=null)]|length)==([.out[].tag|select(.!=null)]|unique|length)) |
[.out[]|select(.[$pk]=="block" or .[$pk]=="blackhole")|.tag] as $blocks |
(.out|any(.tag==$tag)) as $managed |
(.route.rules // []) as $rules | require(($rules|type)=="array" and all($rules[];type=="object")) |
require(all($rules[]; if .[$ok]==$tag or .[$ok]==($tag+"-udp") then .[$ik]==[$in] else true end)) |
[$rules[] | select(.[$ok]!=$tag and .[$ok]!=($tag+"-udp")) |
 select(($sing and $managed and .=={inbound:[$in],network:"udp",action:"reject"})|not)] as $kept |
def pass_rule:
 . as $r | ($blocks|index($r[$ok]))!=null or
 ($sing and (.action=="reject" or .action=="sniff")) or
 ((.[$ok] // "" | startswith("v2bx-socks-")) and (.[$ik]|type)=="array" and (.[$ik]|index($in))==null);
def fallback:
 ((keys - (if $sing then ["outbound","network","action"] else ["outboundTag","network","type"] end))|length)==0 and
 (.[$ok]|type)=="string" and (.[$ok]|length)>0 and
 ((has("network")|not) or ((.network | if type=="string" then split(",") else . end | sort)==["tcp","udp"])) and
 (.action // "route")=="route" and ($sing or (.type // "field")=="field");
[$kept|to_entries[]|select(.value|pass_rule|not)] as $terminal |
require(($terminal|length)==0 or (($terminal|length)==1 and $terminal[0].key==($kept|length)-1 and ($terminal[0].value|fallback))) |
(if ($terminal|length)==0 then ($kept|length) else $terminal[0].key end) as $at |
([if $e.udp then empty elif $sing then {inbound:[$in],network:"udp",action:"reject"}
 else {type:"field",inboundTag:[$in],network:"udp",outboundTag:($tag+"-udp")} end,
 if $sing then {inbound:[$in],action:"route",outbound:$tag}
 else {type:"field",inboundTag:[$in],network:"tcp,udp",outboundTag:$tag} end]) as $new |
.route.rules=($kept[:$at]+$new+$kept[$at:]) |
.out=[.out[]|select(.tag!=$tag and .tag!=($tag+"-udp"))] |
if (.out|length)==0 then .out=[if $sing then {tag:"v2bx-socks-default",type:"direct"} else {tag:"v2bx-socks-default",protocol:"freedom"} end] else . end |
if $sing then
 {type:"socks",tag:$tag,server:$e.host,server_port:$e.port,version:"5"} as $base |
 ($base + (if $e.username=="" then {} else {username:$e.username,password:$e.password} end) +
 (if $e.udp then {} else {network:"tcp"} end)) as $out |
 (if ($e.host|test("^[0-9.]+$|:")) or .route.default_domain_resolver then $out else
  [.origin.dns.servers[]? | select(.tag and .type!="fakeip" and .address!="fakeip") | .tag] as $dns |
  if ($dns|length)==0 then error("no DNS resolver") else $out+{domain_resolver:{server:$dns[0],strategy:"prefer_ipv4"}} end end) as $resolved |
 .out+=[$resolved] | .origin.outbounds=.out | .origin.route=.route
else
 ({address:$e.host,port:$e.port} + (if $e.username=="" then {} else {users:[{user:$e.username,pass:$e.password}]} end)) as $server |
 .out += [{tag:$tag,protocol:"socks",settings:{servers:[$server]}}] |
 if $e.udp then . else .out += [{tag:($tag+"-udp"),protocol:"blackhole"}] end
end
JQ
}

check_drift() {
    local i current
    current=$(hash_file "$CONFIG_PATH") || return 1
    [[ $current == "$CONFIG_SHA" ]] || return 1
    for ((i=0;i<${#FILES[@]};i++)); do
        [[ $(hash_file "${FILES[$i]}") == "$(hash_file "$TASK_DIR/$i.before")" ]] || return 1
    done
}
tx_status() {
    jq --arg status "$1" '.status=$status' "$TX_DIR/manifest.json" > "$TASK_DIR/manifest.next" || return 1
    atomic_copy "$TASK_DIR/manifest.next" "$TX_DIR/manifest.json"
}
tx_prepare() {
    local i mode file_uid file_gid before after mode_decimal
    [[ ! -L $BACKUP_ROOT ]] || return 1
    mkdir -p "$BACKUP_ROOT" && chmod 700 "$BACKUP_ROOT" || return 1
    TX_DIR=$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
    jq -n --arg config "$CONFIG_PATH" --arg sha "$CONFIG_SHA" \
        --slurpfile s "$TASK_DIR/selection.json" \
        '{schema:2,status:"prepared",config:$config,config_sha:$sha,label:($s[0].kind+" / 节点 "+($s[0].node.NodeID|tostring)),files:[]}' \
        > "$TASK_DIR/manifest.next" || return 1
    for ((i=0;i<${#FILES[@]};i++)); do
        read -r mode file_uid file_gid < <(metadata "${FILES[$i]}")
        [[ $mode =~ ^[0-7]+$ && $file_uid =~ ^[0-9]+$ && $file_gid =~ ^[0-9]+$ ]] || return 1
        mode_decimal=$((8#$mode))
        before=$(hash_file "$TASK_DIR/$i.before") && after=$(hash_file "$TASK_DIR/$i.after") || return 1
        atomic_copy "$TASK_DIR/$i.before" "$TX_DIR/$i.bak" || return 1
        jq --arg path "${FILES[$i]}" --arg before "$before" --arg after "$after" --arg backup "$i.bak" \
            --argjson mode "$mode_decimal" --argjson uid "$file_uid" --argjson gid "$file_gid" \
            '.files += [{path:$path,before:$before,after:$after,backup:$backup,mode:$mode,uid:$uid,gid:$gid}]' \
            "$TASK_DIR/manifest.next" > "$TASK_DIR/manifest.add" || return 1
        mv "$TASK_DIR/manifest.add" "$TASK_DIR/manifest.next" || return 1
    done
    atomic_copy "$TASK_DIR/manifest.next" "$TX_DIR/manifest.json"
}
restore_check() {
    local interrupted=${1:-false} path before after backup mode file_uid file_gid current expected_config
    jq -e '
      (.schema==1 or .schema==2) and (.files|type=="array" and length>0) and
      all(.files[]; (.path|type=="string") and (.backup|test("^[0-9]+\\.bak$")) and
          (.mode|type=="number") and (.uid|type=="number") and (.gid|type=="number"))
    ' "$TX_DIR/manifest.json" >/dev/null 2>&1 || { fail '备份格式不正确。'; return 1; }
    expected_config=$(jq -r '.config_sha // ""' "$TX_DIR/manifest.json")
    if [[ -n $expected_config && $(hash_file "$CONFIG_PATH") != "$expected_config" ]]; then fail '主配置已被其他操作修改，不能自动恢复旧备份。'; return 1; fi
    while IFS=$'\t' read -r path before after backup mode file_uid file_gid; do
        safe_path "$path" || return 1
        current=$(hash_file "$path") || return 1
        if [[ $current != "$after" && ( $interrupted != true || $current != "$before" ) ]]; then
            fail "配置已被其他操作改动，拒绝覆盖：$path"; return 1
        fi
        [[ $(hash_file "$TX_DIR/$backup") == "$before" ]] || { fail '备份不完整或已损坏。'; return 1; }
    done < <(jq -r '.files[]|[.path,.before,.after,.backup,.mode,.uid,.gid]|@tsv' "$TX_DIR/manifest.json")
}
restore_files() {
    local path backup mode file_uid file_gid octal
    while IFS=$'\t' read -r path backup mode file_uid file_gid; do
        printf -v octal '%o' "$mode"
        atomic_copy "$TX_DIR/$backup" "$path" "$octal" "$file_uid:$file_gid" || return 1
    done < <(jq -r '.files[]|[.path,.backup,.mode,.uid,.gid]|@tsv' "$TX_DIR/manifest.json")
}
rollback() {
    local status
    [[ -n $TX_DIR && -f $TX_DIR/manifest.json ]] || return 0
    status=$(jq -r '.status' "$TX_DIR/manifest.json") || return 1
    [[ $status != applied && $status != rolled_back && $status != cancelled && $status != restored ]] || { TX_DIR=''; TX_ARMED=false; return 0; }
    service_stop || { fail "无法停止服务，请从菜单 3 恢复备份：$TX_DIR"; return 1; }
    if [[ $status == prepared ]]; then
        tx_status cancelled || return 1
        say '未写入配置，已取消本次应用。'
    elif restore_check true && restore_files && tx_status rolled_back; then
        say '已恢复修改前的配置。'
    else
        tx_status recovery_required || true
        fail "自动恢复未完成，服务保持停止。请核对配置并通过菜单 3 恢复：$TX_DIR"; return 1
    fi
    service_start_check || say '原配置已保留，但服务尚未稳定运行，请检查面板和节点。'
    TX_DIR=''
    TX_ARMED=false
}
apply_candidate() {
    local i
    check_drift || { fail '填写期间配置发生变化，请重新进入菜单。'; return 1; }
    tx_prepare || { fail '无法完成备份，未写入节点配置。'; TX_DIR=''; return 1; }
    TX_ARMED=true
    if ! service_stop || ! check_drift || ! tx_status writing; then rollback; return 1; fi
    for ((i=0;i<${#FILES[@]};i++)); do
        if ! atomic_copy "$TASK_DIR/$i.after" "${FILES[$i]}"; then rollback; return 1; fi
    done
    if ! tx_status checking || ! service_start_check; then
        say '服务未通过启动检查，正在恢复原配置。'
        rollback; return 1
    fi
    tx_status applied || { rollback; return 1; }
    say "配置已保存，服务已持续运行并有节点监听。备份：$TX_DIR"
    TX_DIR=''
    TX_ARMED=false
    say '请用客户端连接该节点，确认出口 IP 与 SOCKS 测试一致。'
}

backup_list() {
    local manifest status
    BACKUPS=()
    [[ -d $BACKUP_ROOT && ! -L $BACKUP_ROOT ]] || return 0
    for manifest in "$BACKUP_ROOT"/*/manifest.json; do
        [[ -f $manifest && ! -L $manifest ]] || continue
        status=$(jq -r '.status' "$manifest") || return 1
        case $status in restored|rolled_back|cancelled) continue;; esac
        BACKUPS+=("${manifest%/*}")
    done
}
pending_check() {
    local dir
    backup_list || return 1
    [[ ${#BACKUPS[@]} -gt 0 ]] || return 0
    for dir in "${BACKUPS[@]}"; do
        [[ $(jq -r '.status' "$dir/manifest.json") == applied ]] || { fail '发现未完成的操作，请先选择 3 恢复备份。'; return 1; }
    done
}
restore_menu() {
    local i n interrupted=false selected status
    TX_ARMED=false
    backup_list || return 1
    [[ ${#BACKUPS[@]} -gt 0 ]] || { say '暂无可恢复的备份。'; return 0; }
    for ((i=${#BACKUPS[@]}-1;i>=0;i--)); do
        n=$((${#BACKUPS[@]}-i)); selected=${BACKUPS[$i]}
        printf '%s. %s · %s\n' "$n" "${selected##*/}" "$(jq -r '.label // .status' "$selected/manifest.json")"
    done
    ask '选择备份序号' 1 || return 1
    [[ $REPLY =~ ^[1-9][0-9]*$ && ${#REPLY} -le 4 ]] || return 1
    n=$((10#$REPLY)); ((n<=${#BACKUPS[@]})) || return 1
    TX_DIR=${BACKUPS[$((${#BACKUPS[@]}-n))]}
    status=$(jq -r '.status' "$TX_DIR/manifest.json")
    [[ $status == applied ]] || interrupted=true
    if ! restore_check "$interrupted"; then TX_DIR=''; return 1; fi
    if ! confirm '恢复此备份并短暂重启整个 V2bX 服务'; then TX_DIR=''; return 0; fi
    TX_ARMED=true
    if ! service_stop; then TX_DIR=''; return 1; fi
    if ! restore_check "$interrupted"; then service_start_check || true; TX_DIR=''; return 1; fi
    if ! tx_status restoring || ! restore_files || ! tx_status restored; then
        tx_status recovery_required || true
        fail "恢复尚未完成，服务保持停止。重新运行并选择 3 继续恢复：$TX_DIR"
        TX_DIR=''; return 1
    fi
    TX_DIR=''
    TX_ARMED=false
    if service_start_check; then say '备份已恢复，服务已运行。'; else say '备份已恢复，但原服务未正常运行，请检查面板和节点。'; fi
}
show_status() {
    local state
    state=$(service_state) || return 1
    say "主配置：$CONFIG_PATH"
    say "服务：$(printf '%s\n' "$state" | property ActiveState) / $(printf '%s\n' "$state" | property SubState)"
    jq -r '.Nodes[]|"节点 ID \(.NodeID) · \(.NodeType) · 内核 \(.Core)"' "$CONFIG_PATH"
    [[ $(printf '%s\n' "$state" | property SubState) == running ]] || diagnosis
}
configure_menu() {
    local count index answer
    pending_check || return 1
    count=$(jq '.Nodes|length' "$CONFIG_PATH") || return 1
    jq -r '.Nodes|to_entries[]|"\(.key+1). 节点 ID \(.value.NodeID) · \(.value.NodeType) · \(.value.Core)"' "$CONFIG_PATH"
    if [[ $count == 1 ]]; then ask '选择节点前面的序号' 1; else ask '选择节点前面的序号'; fi || return 1
    [[ $REPLY =~ ^[1-9][0-9]*$ && ${#REPLY} -le 4 ]] || { fail '请输入节点前面的数字序号。'; return 1; }
    index=$((10#$REPLY-1)); ((index<count)) || return 1
    say '正在检查当前 V2bX 服务……'
    healthy 5 || { diagnosis; say '可先用菜单 2 单独测试 SOCKS。'; return 1; }
    ask_endpoint || return 1
    say 'SOCKS 是否明确支持 UDP？'
    say '1. 不支持 / 不确定：只代理 TCP，阻断 UDP'
    say '2. 支持：TCP 和 UDP 都经 SOCKS'
    ask '请选择' 1 || return 1; answer=$REPLY
    [[ $answer == 1 || $answer == 2 ]] || return 1
    jq --arg value "$answer" '.udp=($value=="2")' "$TASK_DIR/endpoint.json" > "$TASK_DIR/endpoint.next" && mv "$TASK_DIR/endpoint.next" "$TASK_DIR/endpoint.json" || return 1
    build_candidate "$index" "$TASK_DIR/endpoint.json" || return 1
    say "即将配置：$(jq -r '.kind+" / 节点 "+(.node.NodeID|tostring)' "$TASK_DIR/selection.json")"
    jq -r '"SOCKS 接入：\(.host):\(.port)；认证："+(if .username=="" then "无账号 / IP 白名单" else "账号密码（不显示）" end)' "$TASK_DIR/endpoint.json"
    say '仅改变所选节点出口；保留拦截规则。生效时整个 V2bX 服务会短暂重启。'
    say '普通 SOCKS 不加密；如服务商提供加密隧道，请通过隧道接入。'
    confirm '确认备份、保存并生效' || { say '已取消，未修改配置。'; return 0; }
    healthy 0 || { fail '现有服务状态已变化，请先检查。'; return 1; }
    say '正在备份、应用并检查服务，请勿关闭窗口……'
    apply_candidate
}

cleanup() {
    local code=$?
    trap - EXIT
    trap '' INT TERM HUP
    [[ -z $TTY_MODE ]] || stty "$TTY_MODE" <&9
    if [[ $TX_ARMED == true && -n $TX_DIR ]]; then rollback || true; fi
    [[ -z $ATOMIC_TMP ]] || rm -f "$ATOMIC_TMP"
    if [[ -n $TASK_DIR && $TASK_DIR == */v2bx-socks.* && -d $TASK_DIR ]]; then rm -rf "$TASK_DIR"; fi
    exit "$code"
}
help_text() {
    cat <<'HELP'
V2bX 中文 SOCKS 出口助手 2.0（轻量版）
安装后使用：v2bx-socks
只读查看：v2bx-socks --status
手动上传脚本后使用：bash v2bx-socks.sh
依赖：Bash、jq、curl，以及 Linux 自带的 systemd/coreutils 工具。
菜单：按节点配置 SOCKS、只测试出口、恢复备份、查看状态。
确认保存才修改出站；生效时短暂重启整个 V2bX 服务。
无需 Python，不会安装、升级或重装 V2bX。
HELP
}
main() {
    local item missing=() choice
    case ${1:-} in --help|-h) help_text; return 0;; --version) say "$VERSION"; return 0;; ''|--status) ;; *) help_text; return 1;; esac
    [[ $EUID == 0 ]] || { fail '请使用 root 用户运行。'; return 1; }
    for item in systemctl ss flock sha256sum stat sync; do command -v "$item" >/dev/null 2>&1 || { fail "缺少系统工具：$item"; return 1; }; done
    for item in jq curl; do command -v "$item" >/dev/null 2>&1 || missing+=("$item"); done
    if [[ ${#missing[@]} -gt 0 ]]; then
        [[ $# == 0 ]] || { fail '缺少 jq 或 curl，请不带参数运行，按提示安装。'; return 1; }
        exec 9<>/dev/tty || return 1
        say "缺少工具：${missing[*]}"
        confirm '安装这些轻量工具' || return 0
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y --no-install-recommends "${missing[@]}" ca-certificates || return 1
        elif command -v dnf >/dev/null 2>&1; then dnf install -y "${missing[@]}" ca-certificates || return 1
        elif command -v yum >/dev/null 2>&1; then yum install -y "${missing[@]}" ca-certificates || return 1
        else fail '请先安装 jq 和 curl。'; return 1; fi
    fi
    discover || return 1
    if [[ ${1:-} == --status ]]; then show_status; return $?; fi
    umask 077
    TASK_DIR=$(mktemp -d /tmp/v2bx-socks.XXXXXX) || return 1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    exec 9<>/dev/tty || { fail '请通过交互 SSH 终端运行。'; return 1; }
    [[ ! -L ${CONFIG_PATH%/*}/.v2bx-socks.lock ]] || return 1
    exec 8>"${CONFIG_PATH%/*}/.v2bx-socks.lock" || return 1
    flock -n 8 || { fail '另一个出口助手正在运行，请先关闭它。'; return 1; }
    while true; do
        say ''; say "V2bX SOCKS 出口助手 $VERSION（轻量版）"
        say '1. 配置 / 更换一个节点的 SOCKS 出口'
        say '2. 只测试 SOCKS（不改配置）'
        say '3. 恢复修改前的配置'
        say '4. 查看节点与服务状态'
        say '0. 退出'
        ask '请选择' 0 || return 1; choice=$REPLY
        case $choice in
            0) return 0;; 1) configure_menu || true;; 2) ask_endpoint || true;;
            3) restore_menu || true;; 4) show_status || true;; *) say '请输入菜单中的数字。';;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
