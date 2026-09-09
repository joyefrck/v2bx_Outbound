#!/usr/bin/env bash
# Unified bootstrap. Installs verified management tools, then guides first installation.
set -euo pipefail

INSTALL_STAGE=''
DOWNLOAD_BASE='https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/main'

install_error() { printf '安装未完成：%s\n' "$*" >&2; return 1; }
cleanup_install() {
    if [[ -n $INSTALL_STAGE && -d $INSTALL_STAGE ]]; then
        rm -f -- "$INSTALL_STAGE/v2bx-socks.sh" "$INSTALL_STAGE/SHA256SUMS"
        rmdir -- "$INSTALL_STAGE" 2>/dev/null || true
    fi
}
download_file() {
    local url=$1 output=$2 endpoint=$1 fallback='' downloader retry_index
    local accept='application/vnd.github+json' downloaded
    if command -v curl >/dev/null 2>&1; then
        downloader=curl
    elif command -v wget >/dev/null 2>&1; then
        downloader=wget
    else
        install_error '请先安装 curl 或 wget。'; return 1
    fi
    # Never fall back to a moving branch: payloads and checksums must use one commit.
    if [[ $url =~ ^https://raw\.githubusercontent\.com/joyefrck/v2bx_Outbound/([0-9a-f]{40})/([A-Za-z0-9._/-]+)$ ]]; then
        fallback="https://api.github.com/repos/joyefrck/v2bx_Outbound/contents/${BASH_REMATCH[2]}?ref=${BASH_REMATCH[1]}"
    fi
    while :; do
        for ((retry_index=1;retry_index<=4;retry_index++)); do
            printf '正在下载（%s/4）：%s\n' "$retry_index" "$endpoint" >&2
            downloaded=false
            if [[ $downloader == curl ]]; then
                if curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
                    --connect-timeout 15 --max-time 90 --header "Accept: $accept" \
                    --output "$output" "$endpoint"; then downloaded=true; fi
            else
                # Retry HTTP failures here; older wget versions do not retry 503 by default.
                if wget --https-only --timeout=30 --tries=1 --header "Accept: $accept" \
                    -O "$output" "$endpoint"; then downloaded=true; fi
            fi
            if [[ $downloaded == true && -s $output ]]; then return 0; fi
            rm -f -- "$output" || return 1
            if ((retry_index < 4)); then
                printf '下载未成功，%s 秒后重试。\n' "$((retry_index * 2))" >&2
                sleep "$((retry_index * 2))" || return 1
            fi
        done
        [[ -n $fallback ]] || break
        printf 'Raw 下载失败，切换 GitHub 官方 API（同一提交）。\n' >&2
        endpoint=$fallback; fallback=''; accept='application/vnd.github.raw+json'
    done
    install_error "下载失败：${url}；请稍后重试或检查服务器到 GitHub 的连接。"
}
install_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 -- "$1" | cut -d ' ' -f 1
    fi
}
install_helper() {
    local destination=$1 base=$2 expected actual
    [[ ! -L $destination && ( ! -e $destination || -f $destination ) ]] || {
        install_error '目标命令不是普通文件，请先检查 /usr/local/bin/v2bx-socks。'; return 1;
    }
    if [[ -e $destination ]] && ! head -n 2 "$destination" | grep -Fq '# V2bX SOCKS Helper '; then
        install_error '同名命令已存在且不是本助手，未覆盖。'; return 1
    fi
    mkdir -p -- "${destination%/*}" || return 1
    INSTALL_STAGE=$(mktemp -d "${destination%/*}/.v2bx-socks-install.XXXXXX") || return 1
    if ! download_file "$base/v2bx-socks.sh" "$INSTALL_STAGE/v2bx-socks.sh" ||
       ! download_file "$base/SHA256SUMS" "$INSTALL_STAGE/SHA256SUMS"; then
        install_error '下载失败，原助手保持不变；请检查 GitHub 连接后重试。'; return 1
    fi
    expected=$(awk '$2=="v2bx-socks.sh" && NF==2 {print $1}' "$INSTALL_STAGE/SHA256SUMS") || return 1
    actual=$(install_hash "$INSTALL_STAGE/v2bx-socks.sh") || return 1
    if [[ ! $expected =~ ^[0-9a-f]{64}$ || $actual != "$expected" ]]; then
        install_error '文件校验失败，原助手保持不变；请重新运行安装命令。'; return 1
    fi
    if ! bash -n "$INSTALL_STAGE/v2bx-socks.sh"; then
        install_error '脚本语法检查失败，原助手保持不变。'; return 1
    fi
    chmod 755 "$INSTALL_STAGE/v2bx-socks.sh" || return 1
    mv -f -- "$INSTALL_STAGE/v2bx-socks.sh" "$destination" || return 1
    printf '安装 / 更新完成：%s\n运行 v2bx-socks，按中文提示配置出口。\n' "$destination"
}
resolve_commit() {
    local head
    head=$(mktemp) || return 1
    if ! download_file 'https://api.github.com/repos/joyefrck/v2bx_Outbound/git/ref/heads/main' "$head"; then rm -f "$head"; return 1; fi
    # Bootstrap must also work before jq is installed. Git ref responses contain one sha.
    RESOLVED_COMMIT=$(sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' "$head")
    rm -f "$head"
    [[ $RESOLVED_COMMIT =~ ^[0-9a-f]{40}$ ]]
}
replace_tool_file() {
    local source=$1 destination=$2 pending
    pending=$(mktemp "${destination%/*}/.v2bx-replace.XXXXXX") || return 1
    if ! cp -p "$source" "$pending" || ! mv -f "$pending" "$destination"; then
        rm -f "$pending"; return 1
    fi
}
install_tools() (
    manager=$1; helper=$2; alias=$3; license=$4; base=$5
    stage=''; file=''; digest=''; name=''; i=0; armed=false
    targets=("$manager" "$helper" "$license") artifacts=(v2bx-manager.sh v2bx-socks.sh LICENSE.MPL-2.0)
    absent=(); changed=(); link_created=false
    umask 077
    for file in "${targets[@]}"; do
        [[ ! -L $file && ( ! -e $file || -f $file ) ]] || { install_error "目标不是普通文件：$file"; exit 1; }
        mkdir -p "${file%/*}" || exit 1
    done
    if [[ -f $manager ]] && ! head -n 8 "$manager" | grep -Eq 'V2bX Integrated Manager|red='; then
        install_error '同名管理命令不是本工具或上游管理脚本，未覆盖。'; exit 1
    fi
    if [[ -f $helper ]] && ! head -n 2 "$helper" | grep -Fq '# V2bX SOCKS Helper '; then exit 1; fi
    if [[ -e $alias || -L $alias ]]; then
        [[ -L $alias && ( $(readlink "$alias") == "$manager" || $(readlink "$alias") == V2bX ) ]] || {
            install_error 'v2bx 命令已存在且不是标准别名，未覆盖。'; exit 1;
        }
    fi
    stage=$(mktemp -d "${manager%/*}/.v2bx-tools.XXXXXX") || exit 1
    tools_cleanup() {
        local code=$? j
        trap - EXIT; trap '' INT TERM HUP
        if [[ $armed == true ]]; then
            for j in "${changed[@]}"; do
                if [[ ${absent[$j]} == true ]]; then rm -f "${targets[$j]}" || code=1
                else replace_tool_file "$stage/old-$j" "${targets[$j]}" || { printf '恢复失败，保留备份：%s\n' "$stage" >&2; exit 1; }; fi
            done
            [[ $link_created != true ]] || rm -f "$alias"
            code=1
        fi
        rm -rf "$stage"
        exit "$code"
    }
    trap tools_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    download_file "$base/SHA256SUMS" "$stage/SHA256SUMS" || exit 1
    for ((i=0;i<${#artifacts[@]};i++)); do
        name=${artifacts[$i]}
        download_file "$base/$name" "$stage/$name" || exit 1
        digest=$(awk -v name="$name" '$2==name && NF==2 {print $1}' "$stage/SHA256SUMS")
        [[ $digest =~ ^[0-9a-f]{64}$ && $(install_hash "$stage/$name") == "$digest" ]] || {
            install_error "文件校验失败：${name}；保留原工具。"; exit 1;
        }
        case $name in *.sh) bash -n "$stage/$name" || exit 1; chmod 755 "$stage/$name" || exit 1;; *) chmod 644 "$stage/$name" || exit 1;; esac
        absent[$i]=true
        if [[ -f ${targets[$i]} ]]; then cp -p "${targets[$i]}" "$stage/old-$i" || exit 1; absent[$i]=false; fi
    done
    head -n 2 "$stage/v2bx-manager.sh" | grep -Fq '# V2bX Integrated Manager' || exit 1
    head -n 2 "$stage/v2bx-socks.sh" | grep -Fq '# V2bX SOCKS Helper ' || exit 1
    # All payloads validated before the first replacement. mv is atomic per target;
    # the trap restores the complete previous set if a later replacement fails.
    armed=true
    for ((i=0;i<${#artifacts[@]};i++)); do
        changed+=("$i")
        replace_tool_file "$stage/${artifacts[$i]}" "${targets[$i]}" || exit 1
    done
    if [[ ! -L $alias ]]; then ln -s "$manager" "$alias" || exit 1; link_created=true; fi
    armed=false
    printf '统一管理工具已安装 / 更新。运行 v2bx；原 v2bx-socks 命令仍可使用。\n'
)
main() {
    local mode=interactive commit=''
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                printf '%s\n' 'V2bX 安装与可选 SOCKS 出口统一安装器' '用法：bash install.sh [--helper-only|--tools-only]' \
                    '默认安装管理工具，首次安装 V2bX 并引导节点配置；已有 V2bX 则打开菜单。' \
                    '--helper-only  仅安装 / 更新 SOCKS 助手，不重启服务。' \
                    '--tools-only   仅安装 / 更新管理工具与助手，不更新 V2bX 内核。'
                return 0;;
            --helper-only) mode=helper;; --tools-only) mode=tools;;
            --commit) [[ $# -ge 2 ]] || return 1; commit=$2; shift;;
            *) install_error '不支持此参数，请使用 --help。'; return 1;;
        esac
        shift
    done
    [[ $EUID == 0 && $(uname -s) == Linux ]] || { install_error '请在 Linux 服务器上以 root 运行。'; return 1; }
    if [[ $mode != helper ]]; then
        [[ -d /run/systemd/system ]] || { install_error '需要 systemd；不支持 Alpine/OpenRC 或普通 Docker。'; return 1; }
        local ID=''
        source /etc/os-release
        case $ID in debian|ubuntu|centos|rocky|almalinux|rhel) ;; *) install_error '暂不支持此系统。'; return 1;; esac
    fi
    command -v sha256sum >/dev/null 2>&1 || return 1
    command -v flock >/dev/null 2>&1 || return 1
    exec 7>/run/lock/v2bx-tools.lock
    flock -n 7 || { install_error '另一个安装 / 更新正在执行。'; return 1; }
    if [[ -z $commit ]]; then resolve_commit || { install_error '无法获取仓库提交，请检查 GitHub 连接。'; return 1; }; commit=$RESOLVED_COMMIT; fi
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || return 1
    DOWNLOAD_BASE="https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/$commit"
    umask 077
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ $mode == helper ]]; then install_helper /usr/local/bin/v2bx-socks "$DOWNLOAD_BASE"; return $?; fi
    install_tools /usr/bin/V2bX /usr/local/bin/v2bx-socks /usr/bin/v2bx /usr/local/share/v2bx-manager/LICENSE "$DOWNLOAD_BASE" || return 1
    exec 7>&-
    [[ $mode != tools ]] || return 0
    if [[ -x /usr/local/V2bX/V2bX ]]; then bash /usr/bin/V2bX
    else bash /usr/bin/V2bX install; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
