# Installation layout adapted from upstream install.sh (MPL-2.0).
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
m_core_version() {
    local output version
    [[ -x $1 ]] || { printf '未安装'; return; }
    output=$("$1" version 2>/dev/null) || { printf '无法读取'; return; }
    version=$(printf '%s\n' "$output" | awk '$1=="V2bX" {print $2; exit}')
    if [[ $version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then printf '%s' "$version"
    else printf '无法识别版本'; fi
}
m_core_file_hash() {
    [[ -f $1 ]] || { printf '不存在'; return; }
    local digest
    digest=$(sha256sum -- "$1") || { printf '无法读取'; return; }
    digest=${digest%% *}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$digest" || printf '无法读取'
}
m_core_tree_hash() (
    [[ -d $1 ]] || { printf '不存在'; exit 0; }
    cd -- "$1" || exit 1
    # Compare all regular payload files, including release files beyond the three
    # mandatory ones. A symbolic link prevents treating the directory as identical.
    [[ -z $(find . -type l -print -quit) ]] || exit 1
    find . -type f -exec sha256sum -- {} + | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1
)
m_core_report_row() {
    local label=$1 before=$2 after=$3 status='已更新' tone=32
    if [[ $before == 无法读取 || $after == 无法读取 ]]; then status='无法确认'; tone=33
    elif [[ $before == "$after" ]]; then status='未变化'; tone=37
    elif [[ $before == 不存在 ]]; then status='已新增'; fi
    m_line "$tone" "  ${label} · ${status}"
    m_line 37 "    文件指纹：${before:0:16} → ${after:0:16}"
}
m_core_report() {
    m_section '内核更新明细（更新前 → 更新后）'
    m_line 37 '  来源：本仓库官方源码适配构建；文件指纹为 SHA256 前 16 位。'
    m_line 37 "  V2bX 版本：${before_version} → $(m_core_version "$M_BINARY/V2bX")"
    m_core_report_row 'V2bX 主程序' "$before_program" "$(m_core_file_hash "$M_BINARY/V2bX")"
    m_core_report_row 'GeoIP IP 规则库（geoip.dat）' "$before_geoip" "$(m_core_file_hash "$M_CONFIG/geoip.dat")"
    m_core_report_row 'GeoSite 域名规则库（geosite.dat）' "$before_geosite" "$(m_core_file_hash "$M_CONFIG/geosite.dat")"
    m_line 37 '    GeoIP / GeoSite 未提供可读版本号，以文件指纹判断内容变化。'
    m_core_report_row '发布包文件集合' "$before_payload" "$(m_core_tree_hash "$M_BINARY" || printf '无法读取')"
    m_core_report_row 'systemd 服务文件' "$before_unit" "$(m_core_file_hash "$M_UNIT")"
    m_line 37 "  管理工具：${MANAGER_VERSION} → ${MANAGER_VERSION}（本次不更新）"
    m_line 37 '  节点、面板和 SOCKS 配置：保留。'
    m_line 36 "  结果：${core_outcome}"
    [[ -z $backup ]] || m_line 37 "  备份：${backup}"
    report_done=true
}
m_install_core() (
    umask 077
    stage=''; backup=''; armed=false; existed=false; was_active=false; unit_existed=false; swapped=false; file=''
    report_ready=false; report_done=false; core_outcome='未应用更新，请检查上方错误。'
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
                [[ $was_active != true ]] || { systemctl start V2bX && m_health; } || restored=false
            fi
            if [[ $restored == true ]]; then
                printf '安装 / 更新失败，已恢复原文件和服务状态。\n'
                core_outcome='更新失败，已回滚至原文件和服务状态。'
            else
                core_outcome='更新失败，恢复未完成，请检查备份。'
                m_core_report
                printf '恢复未完成，保留现场：%s；备份：%s\n' "$stage" "$backup" >&2; exit 1;
            fi
            code=1
        fi
        if [[ $report_ready == true && $report_done != true ]]; then m_core_report; fi
        [[ -z $stage ]] || rm -rf "$stage"
        exit "$code"
    }
    trap m_core_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    before_version=$(m_core_version "$M_BINARY/V2bX")
    before_program=$(m_core_file_hash "$M_BINARY/V2bX")
    before_geoip=$(m_core_file_hash "$M_CONFIG/geoip.dat")
    before_geosite=$(m_core_file_hash "$M_CONFIG/geosite.dat")
    before_unit=$(m_core_file_hash "$M_UNIT")
    before_payload=$(m_core_tree_hash "$M_BINARY" || printf '无法读取')
    report_ready=true
    m_line 37 '将检查已签名内核包和本地配置；更新时保留现用 Geo 数据。'
    m_prepare_core "$stage" "${1:-}" || exit 1
    # Geo datasets are independent. Do not replace custom/current Geo data as
    # a side effect of a runtime update, including old layouts without metadata.
    if [[ $existed == true ]]; then
        for file in "${M_FILES[@]}"; do
            [[ -f $M_CONFIG/$file && ! -L $M_CONFIG/$file ]] || { m_error '现用 Geo 文件缺失，请先修复。'; exit 1; }
            cp -p "$M_CONFIG/$file" "$stage/new/$file" || exit 1
        done
    fi
    m_core_preflight "$stage/new/V2bX" || exit 1
    candidate_payload=$(m_core_tree_hash "$stage/new" || printf '无法读取')
    if [[ $existed == true && -f $M_UNIT && $before_payload =~ ^[0-9a-f]{64}$ &&
          $before_payload == "$candidate_payload" && $before_geoip =~ ^[0-9a-f]{64}$ &&
          $before_geosite =~ ^[0-9a-f]{64}$ &&
          $before_geoip == "$(m_core_file_hash "$stage/new/geoip.dat")" &&
          $before_geosite == "$(m_core_file_hash "$stage/new/geosite.dat")" ]]; then
        core_outcome='无需更新：发布包与本地内容一致，未替换文件、未重启服务。'
        m_core_report
        exit 0
    fi
    # Existing configurations, credentials and service units are preserved on updates.
    [[ ! -L $M_CONFIG/manager-backups ]] || exit 1
    mkdir -p "$M_CONFIG/manager-backups" && chmod 700 "$M_CONFIG/manager-backups" || exit 1
    backup=$(mktemp -d "$M_CONFIG/manager-backups/core-$(date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
    m_snapshot "$backup/config" || exit 1
    if [[ -f $M_UNIT ]]; then cp -p "$M_UNIT" "$backup/unit" || exit 1; unit_existed=true; fi
    if [[ -d $M_BINARY ]]; then cp -a "$M_BINARY" "$backup/binary" || exit 1; fi
    systemctl is-active --quiet V2bX && was_active=true
    if [[ $unit_existed != true ]]; then m_write_unit "$stage/V2bX.service" || exit 1; fi
    jq -n --arg binary_sha "$before_program" --argjson active "$was_active" '{schema:1,binary_sha:$binary_sha,was_active:$active}' > "$backup/core-backup.json" || exit 1
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
    printf '%s\n' "$backup" > "$M_CONFIG/last-core-backup.next" && mv "$M_CONFIG/last-core-backup.next" "$M_CONFIG/last-core-backup" || exit 1
    armed=false
    printf 'V2bX 二进制安装 / 更新完成。备份：%s\n' "$backup"
    if [[ $was_active == true ]]; then core_outcome='已应用发布包，服务已重新启动并通过运行检查。'
    elif [[ $existed == true ]]; then core_outcome='已应用发布包；服务更新前为停止状态，更新后保持停止。'
    else core_outcome='已安装发布包，尚未启动服务。'; fi
    m_core_report
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
