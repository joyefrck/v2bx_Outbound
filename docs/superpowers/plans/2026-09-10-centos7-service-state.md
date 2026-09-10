# CentOS 7.9 服务状态查询兼容修复

截图在生成配置的 `m_health -> discover -> service_state` 链路报“无法读取 systemd 服务”，随后回滚。

核对 RHEL 7.9 源码：`src/core/dbus-service.c` 没有导出 `NRestarts`；`src/systemctl/systemctl.c` 的 `show_one` 对显式请求但不存在的属性返回 `-ENXIO`。旧脚本显式查询此属性，并丢弃 stderr，因此有效的服务信息也被视为查询失败。

来源：
- https://github.com/redhat-plumbers/systemd-rhel7/blob/rhel-7.9/src/systemctl/systemctl.c
- https://github.com/redhat-plumbers/systemd-rhel7/blob/rhel-7.9/src/core/dbus-service.c
- https://github.com/redhat-plumbers/systemd-rhel7/blob/rhel-7.9/src/core/dbus-execute.h

修复仅调整服务属性查询与稳定性检查：读取可用属性后过滤，保留真实命令失败；用旧版已有的 `ExecMainStartTimestampMonotonic` 加强没有重启计数时的观察。继续检查 PID、运行状态和监听端口，不改变节点配置、系统服务和回滚流程。

新增模拟 RHEL 7.9 属性行为的回归测试，覆盖发现服务、管理器完整健康入口、字段过滤、旧版进程重启和 D-Bus 错误。先复现旧代码失败，再验证修复及完整测试。此模拟回归不等同于用户 CentOS 7.9 服务器实测；已请求该服务器的只读诊断输出。
