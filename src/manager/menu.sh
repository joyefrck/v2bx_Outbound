# Menu numbers and CLI compatibility adapted from upstream V2bX.sh (MPL-2.0).
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
    local state line active='' sub='' load='' enabled='' status='未知（无法读取服务状态）' autostart='未知'
    if ! m_installed; then
        printf '\nV2bX 状态：未安装\n'
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
    printf '\nV2bX 状态：%s\n是否开机自启：%s\n\n' "$status" "$autostart"
}
m_menu() {
    local choice version
    while true; do
        printf '\nV2bX 安装与 SOCKS 出口管理 %s\n' "$MANAGER_VERSION"
        printf '%s\n' '0. 修改配置（节点管理）' '1. 安装 V2bX' '2. 更新 V2bX 内核' '3. 卸载 V2bX' \
          '4. 启动 V2bX' '5. 停止 V2bX' '6. 重启 V2bX' '7. 查看 V2bX 状态' '8. 查看日志' \
          '9. 设置开机自启' '10. 取消开机自启' '11. 安装 BBR' '12. 查看 V2bX 版本' \
          '13. 生成 X25519 密钥' '14. 更新管理工具（含 SOCKS 助手）' '15. 生成节点配置' \
          '16. 放行所有网络端口' '17. 退出' '18. SOCKS 出口管理'
        m_show_status
        m_ask '请选择 [0-18]' || return 0; choice=$M_REPLY
        case $choice in
            0) m_edit;; 1) m_install_flow;;
            2) m_ask '指定内核版本（回车为最新）' && m_need_install && m_install_core "$M_REPLY";;
            3) m_uninstall;; 4) m_service start;; 5) m_service stop;; 6) m_service restart;;
            7) systemctl status V2bX --no-pager;; 8) journalctl -u V2bX -n 100 --no-pager;;
            9) m_service enable;; 10) m_service disable;; 11) m_bbr;;
            12) m_need_install && "$M_BINARY/V2bX" version;; 13) m_need_install && "$M_BINARY/V2bX" x25519;;
            14) m_update_tools && exec bash "$M_SELF";;
            15) m_generate && [[ -f $M_CONFIG/config.json ]] && m_offer_socks;;
            16) m_open_ports;; 17) return 0;; 18) m_socks;; *) printf '请输入 0-18。\n';;
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
        status) systemctl status V2bX --no-pager;; log) journalctl -u V2bX -e --no-pager -f;;
        config) m_edit;; uninstall) m_uninstall;; x25519|version) m_need_install && "$M_BINARY/V2bX" "$1";;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then m_main "$@"; fi
