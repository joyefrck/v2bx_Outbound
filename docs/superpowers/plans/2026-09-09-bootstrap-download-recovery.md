# 安装器 HTTP 503 恢复实施计划

**目标：** 下载端短暂失败后重试；Raw 持续失败时使用 GitHub 官方 API 下载同一提交的文件；失败给出地址且保留旧工具。

**方案：** 保留现有提交解析和校验流程。在 `install.sh` 内为 curl/wget 统一提供最多 4 次尝试、递增等待和有限超时；仅对本仓库完整提交 SHA 的 Raw URL 提供 Contents API 备用地址，使用原始文件媒体类型。入口命令单独增加重试与临时文件保护。

**范围：** `install.sh`、`tests/test_install.py`、`README.md`、由 `build.sh` 更新的 `SHA256SUMS`。沿用当前分支；本次不连接服务器。

- [x] 在 `tests/test_install.py` 模拟 curl/wget 的连续 503、稍后成功、官方 API 回退、全部失败、空响应及非固定提交地址，先运行确认失败。
- [x] 修改 `install.sh`，让重试和备用下载只返回完整的非空成功响应，清理失败文件并提供中文下载错误。
- [x] 更新 `README.md` 的入口重试和 503 排障说明。
- [x] 执行 `bash build.sh`、Bash 语法检查和完整 unittest；从官方 API 下载固定提交脚本并比较本地对应提交内容。

验证命令：`python3 -m unittest discover -s tests -p 'test_install.py' -v`；`python3 -m unittest discover -s tests -v`；`bash -n install.sh`；`git diff --check`。

验证结果：macOS 115 项测试无失败（跳过 8 项 Linux/systemd 测试）；Linux 隔离容器 115 项测试无失败（跳过 1 项真实 systemd 测试）。强制 Raw 失败后，官方 API 成功下载并校验完整工具包，管理脚本与固定提交源文件逐字节一致。用户已授权提交并推送到 main。
