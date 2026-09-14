# Use the existing helper job namespace so every node/SOCKS/config operation
# sees queued core workers, including the gap before the worker acquires flock.
m_core_job_submit() (
    local action=$1 target=${2:-} root job unit
    [[ $action == update || $action == rollback ]] || exit 1
    if [[ $action == update && -n $target ]]; then
        [[ $target =~ ^core-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { m_error '版本格式为 core-vX.Y.Z。'; exit 1; }
    fi
    umask 077
    m_need_install && m_lock && m_standard_config || exit 1
    root="$M_CONFIG/socks-helper-jobs"
    [[ ! -L $root ]] || exit 1
    mkdir -p "$root" && chmod 700 "$root" || exit 1
    job=$(mktemp -d "$root/job-$(date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
    unit="v2bx-socks-${job##*/}"
    cp "$M_SELF" "$job/manager.sh" && cp "$M_HELPER" "$job/helper.sh" || exit 1
    chmod 600 "$job/manager.sh" "$job/helper.sh" || exit 1
    jq -n --arg action "$action" --arg target "$target" --arg unit "$unit" \
        --arg binary_sha "$(m_core_file_hash "$M_BINARY/V2bX")" \
        --arg config_sha "$(m_core_file_hash "$M_CONFIG/config.json")" \
        --arg unit_sha "$(m_core_file_hash "$M_UNIT")" \
        '{action:$action,target:$target,unit:$unit,binary_sha:$binary_sha,config_sha:$config_sha,unit_sha:$unit_sha}' > "$job/job.json" || exit 1
    if ! systemd-run --quiet --collect --unit="$unit" --property=Type=exec \
        --property=RuntimeMaxSec=1800 --property=TimeoutStopSec=120 \
        /bin/bash "$job/manager.sh" __core-worker "$job" > "$job/launch.log" 2>&1; then
        if ! bash -c 'source "$1"; job_active "$2"' core-launch "$M_HELPER" "$job" && [[ ! -f $job/result.json ]]; then
            printf '{"status":"failed","exit_code":1}\n' > "$job/result.json"
            m_error '后台内核任务启动失败，未修改服务。'; exit 1
        fi
    fi
    printf '%s\n' "$job" > "$M_CONFIG/last-core-job.next" && mv "$M_CONFIG/last-core-job.next" "$M_CONFIG/last-core-job" || exit 1
    exec 8>&-
    m_line 32 '已交给 systemd 后台处理，SSH 断开不会中止更新。'
    m_line 37 '查看结果：v2bx core-job；查看版本：v2bx core-versions'
)
m_core_job_show() {
    local job
    [[ -f $M_CONFIG/last-core-job && ! -L $M_CONFIG/last-core-job ]] || { printf '暂无内核后台任务。\n'; return 0; }
    IFS= read -r job < "$M_CONFIG/last-core-job" || return 1
    [[ ${job%/*} == "$M_CONFIG/socks-helper-jobs" && ${job##*/} == job-* && ! -L $job ]] || return 1
    bash -c 'source "$1"; show_job "$2"' core-show "$M_HELPER" "$job"
}
m_core_job_worker() (
    local job=$1 action target
    [[ $EUID == 0 && ${job%/*} == "$M_CONFIG/socks-helper-jobs" && ${job##*/} == job-* &&
       -d $job && ! -L $job && -O $job && $(stat -c %a "$job") == 700 && ! -L $job/job.json ]] || exit 1
    umask 077
    exec > "$job/output.log" 2>&1
    m_core_job_finish() {
        local code=$?
        trap - EXIT
        jq -n --arg status "$([[ $code == 0 ]] && printf succeeded || printf failed)" --argjson code "$code" \
            '{status:$status,exit_code:$code}' > "$job/result.next" && mv "$job/result.next" "$job/result.json"
        exit "$code"
    }
    trap m_core_job_finish EXIT
    # Ignore hangups. systemd termination reaches the installer rollback trap.
    trap '' HUP
    M_HELPER="$job/helper.sh"
    [[ ! -L $M_CONFIG/.v2bx-socks.lock ]] || exit 1
    exec 8>"$M_CONFIG/.v2bx-socks.lock" || exit 1
    flock -w 30 8 || { m_error '无法取得共享配置锁。'; exit 1; }
    # Already owns the same lock for the full download/preflight/apply lifecycle.
    m_lock() { :; }
    [[ $(m_core_file_hash "$M_CONFIG/config.json") == "$(jq -er '.config_sha' "$job/job.json")" &&
       $(m_core_file_hash "$M_BINARY/V2bX") == "$(jq -er '.binary_sha' "$job/job.json")" &&
       $(m_core_file_hash "$M_UNIT") == "$(jq -er '.unit_sha' "$job/job.json")" ]] || {
        m_error '提交后台任务后配置、程序或服务发生变化，未应用。'; exit 1;
    }
    action=$(jq -er '.action' "$job/job.json") && target=$(jq -r '.target' "$job/job.json") || exit 1
    case $action in update) m_install_core "$target";; rollback) m_core_rollback "$target";; *) exit 1;; esac
)
m_core_rollback() (
    local target=${1:-} expected stage='' armed=false moved=false active=false failed=false
    umask 077
    m_need_install && m_lock && m_standard_config || exit 1
    if [[ -z $target ]]; then
        [[ -f $M_CONFIG/last-core-backup && ! -L $M_CONFIG/last-core-backup ]] || { m_error '没有可回滚的内核备份。'; exit 1; }
        IFS= read -r target < "$M_CONFIG/last-core-backup" || exit 1
    fi
    [[ ${target%/*} == "$M_CONFIG/manager-backups" && ${target##*/} == core-* && -d $target && ! -L $target &&
       -f $target/core-backup.json && ! -L $target/core-backup.json && -d $target/binary &&
       -z $(find "$target/binary" -type l -print -quit) ]] || { m_error '备份路径或结构无效。'; exit 1; }
    expected=$(jq -er '.binary_sha|select(test("^[0-9a-f]{64}$"))' "$target/core-backup.json") || exit 1
    [[ $(m_core_file_hash "$target/binary/V2bX") == "$expected" ]] || { m_error '备份二进制摘要不符。'; exit 1; }
    stage=$(mktemp -d "${M_BINARY%/*}/.v2bx-rollback.XXXXXX") || exit 1
    m_core_rollback_cleanup() {
        local code=$?
        trap - EXIT; trap '' HUP INT TERM
        if [[ $armed == true ]]; then
            systemctl stop V2bX || failed=true
            if [[ $moved == true ]]; then
                rm -rf "$M_BINARY" || failed=true
                mv "$stage/current" "$M_BINARY" || failed=true
            fi
            if [[ $active == true ]]; then systemctl start V2bX && m_health || failed=true; fi
            if [[ $failed == true ]]; then printf '恢复失败，保留现场：%s\n' "$stage" >&2; exit 1; fi
            printf '回滚验证失败，已恢复操作前内核。\n'
            code=1
        fi
        rm -rf "$stage"
        exit "$code"
    }
    trap m_core_rollback_cleanup EXIT
    trap 'exit 143' TERM HUP
    trap 'exit 130' INT
    cp -a "$target/binary" "$stage/new" || exit 1
    if [[ -f $stage/new/core-manifest.json ]]; then
        m_core_preflight "$stage/new/V2bX" || exit 1
    else
        # Legacy binaries have no offline checker; keep current configuration
        # and rely on the same service health/automatic recovery transaction.
        "$stage/new/V2bX" version >/dev/null || exit 1
    fi
    [[ $(m_core_file_hash "$M_BINARY/V2bX") != "$expected" ]] || { printf '当前已是备份内核，无需重启。\n'; exit 0; }
    systemctl is-active --quiet V2bX && active=true
    armed=true
    systemctl stop V2bX || exit 1
    mv "$M_BINARY" "$stage/current" || exit 1
    moved=true
    mv "$stage/new" "$M_BINARY" || exit 1
    if [[ $active == true ]]; then systemctl start V2bX && m_health || exit 1; fi
    armed=false
    printf '内核已回滚至 %s；当前节点、SOCKS、Geo 数据和服务启停状态保留。\n' "$(m_core_version "$M_BINARY/V2bX")"
)
m_core_menu() {
    local choice
    m_need_install || return 1
    m_core_versions
    m_choose '内核维护' '请选择 [1-4]' '后台更新到最新已验证内核' '查看上次后台任务结果' '回滚到上次更新前内核' '返回主菜单' || return 0
    choice=$M_REPLY
    case $choice in
        1) m_core_job_submit update;;
        2) m_core_job_show;;
        3) m_core_job_submit rollback;;
        4) return 0;;
        *) m_error '请输入 1-4。';;
    esac
    m_ask '按回车返回菜单' || return 0
}
