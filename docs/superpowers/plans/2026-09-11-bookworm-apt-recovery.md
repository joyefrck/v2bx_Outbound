# Debian 12 过期镜像源恢复

截图中的安装器和管理工具下载成功；`bookworm-updates`、`bookworm-backports` 的镜像索引过期导致 APT 停止。当前依赖恢复仅支持 Debian 11，Debian 12 直接退出。

2026-09-11 核对官方 bookworm-updates InRelease 的有效期为 2026-09-17。恢复采用临时官方主源、更新源和安全源，沿用隔离索引目录及退出清理，不覆盖系统源，不禁用 Debian 12 的有效期或签名检查。Debian 11 分支保持历史快照策略。

实施：补充 Debian 12 更新/安装失败后的回退测试，以及回退失败仍停止的测试；修改 common.sh 并构建发布文件。添加 AMD64 Debian 12 CI：加载一个已经过期的官方签名快照源，验证 APT 拒绝它、自动回退后真实安装依赖，并确认源配置不变。通过后发布 3.5.2。
