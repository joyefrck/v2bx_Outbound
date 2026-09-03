# GitHub 安装入口

把现有轻量版 SOCKS 出口助手发布到用户指定的公开仓库 `joyefrck/v2bx_Outbound`，让不同服务器都能下载安装。仓库初始为空，使用其默认分支 `main`。

保留独立的 `v2bx-socks.sh`，新增 `install.sh`。安装器从此仓库下载脚本及 SHA256 校验文件，校验完整性与 Bash 语法后原子替换 `/usr/local/bin/v2bx-socks`。失败保留原助手。安装器只安装命令，不接触 V2bX 配置或服务；用户运行 `v2bx-socks` 后按当前服务器节点列表配置。

运行依赖仍为 Bash、jq、curl 与 Linux 系统工具，无 Python 运行依赖，无常驻后台服务。安装器可使用 curl 或 wget 下载。更新使用同一条安装命令。

兼容范围沿用助手：Linux/systemd、V2bX v0.4.0 对应的 Xray/sing-box 标准配置。节点 ID 自动读取；复杂分流或不支持的内核提示退出。不会把特定服务器地址、认证信息或生产配置放入仓库。

验证包括原 22 项助手测试、安装成功/更新失败保留旧版本、校验和与构建一致性、GitHub Actions 的 Linux 测试，以及发布后匿名下载并在隔离 Linux 容器中安装。此次发布不更新生产服务器。
