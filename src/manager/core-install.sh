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
