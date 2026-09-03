# GitHub Install Implementation Plan

**Goal:** 发布可以在多台 V2bX 服务器上下载使用的轻量 SOCKS 助手。

**Architecture:** 保留 Bash/jq/curl 助手；增加下载、校验和原子安装入口；公开文档给出安装、更新与菜单命令。安装器和助手按职责分开，生产配置只在用户确认配置出口时写入。

**Tech Stack:** Bash、jq、curl/wget、SHA256、GitHub Actions；Python 仅用于开发测试。

- [x] 将已有 `src/helper.sh`、单文件脚本和测试移入仓库，保留纯测试数据；历史生产记录不发布。
- [x] 新增 `install.sh`，下载校验后安装到 `/usr/local/bin/v2bx-socks`；通过可被测试替换的下载函数验证失败不会覆盖旧命令。
- [x] 修改 `build.sh` 生成单文件脚本和 `SHA256SUMS`；运行 `bash build.sh` 后验证两者一致。
- [x] 更新 README，提供 curl/wget 安装命令、`v2bx-socks` 菜单入口、更新说明及支持范围。
- [x] 新增安装器测试；运行 `python3 -m unittest discover -s tests -v`，原测试和安装场景均须通过。
- [x] 配置 Linux CI，执行 Bash 语法检查、构建差异检查和全部测试。
- [x] 检查待提交文件不含生产信息，提交推送 `main`；确认远端 SHA 与本地一致。
- [x] 等待 CI，通过公开 URL 下载脚本并在临时 Linux 容器中安装，检查已安装命令 `--help`、`--version`。

发布验证记录：本地 30 项测试通过，初次发布的 GitHub Actions 运行 `33727760518` 通过。Debian 12 临时容器没有 Python，通过公开 GitHub 地址完成 curl 安装、重复更新和仅有 wget 的下载回退，已安装命令可以显示版本与帮助，SHA256 与公开清单一致。测试容器退出后自动删除。
