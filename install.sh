#!/usr/bin/env bash
# Installs the helper command only; does not modify V2bX or restart services.
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
    local url=$1 output=$2
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 90 --retry 2 --output "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --timeout=30 --tries=3 -q -O "$output" "$url"
    else
        install_error '请先安装 curl 或 wget。'
    fi
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
main() {
    case ${1:-} in
        --help|-h)
            printf '%s\n' 'V2bX SOCKS 助手安装器' '用法：bash install.sh' \
                '安装 / 更新 /usr/local/bin/v2bx-socks，然后运行 v2bx-socks。' \
                '需要 Linux、root 和 curl 或 wget；不安装 Python，不修改节点配置。'
            return 0;;
        '') ;;
        *) install_error '不支持此参数，请使用 bash install.sh --help。'; return 1;;
    esac
    [[ $EUID == 0 ]] || { install_error '请使用 root 用户运行。'; return 1; }
    [[ $(uname -s) == Linux ]] || { install_error '本安装器用于 Linux V2bX 服务器。'; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { install_error '缺少系统工具 sha256sum。'; return 1; }
    umask 077
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    install_helper /usr/local/bin/v2bx-socks "$DOWNLOAD_BASE"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
