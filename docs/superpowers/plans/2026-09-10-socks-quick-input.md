# SOCKS 快捷输入实现计划

**目标：** SOCKS 连接信息默认支持 `IP:端口:用户名:密码` 一行输入，保留逐项输入。

**实现：** 在 `src/helper.sh` 的 `ask_endpoint` 增加两项菜单，默认 1。快捷格式通过 stdin 交给 jq 解析，用户名后的剩余内容完整作为密码；IPv6 地址使用方括号。解析后复用 `validate_endpoint`、`probe_socks`，逐项输入沿用原有行为。测试和文档只使用虚构凭据。

**技术：** Bash、jq；运行环境不增加依赖。

1. 在 `tests/test_endpoint_input.py` 覆盖回车选快捷、逐项认证、无认证、特殊字符和含冒号密码、IPv6、错误格式及端口范围。验证旧代码失败。
2. 实现 `parse_quick_endpoint` 和输入模式选择；在写出有效连接信息后继续原有连通性测试。错误仅显示格式说明，不回显输入内容。
3. 更新版本和 README，通过 `bash build.sh` 同步发布脚本和校验清单。运行专项和完整测试，提交推送 main，检查 CI。

命令：`python3 -m unittest discover -s tests -p test_endpoint_input.py -v`；完整 Linux 测试使用既有隔离容器运行 `python3 -m unittest discover -s tests -v`。
