# 官方内核构建与更新 Implementation Plan

**Goal:** 将菜单 13 切换到自有官方源码构建渠道，建立适配、验证、发布、安装和回滚链路。
**Architecture:** runtime/ 保存 V2bX 源码。scripts/ 负责锁定和打包，src/manager/ 负责服务器端更新。发布只接收验证成功的确定版本组合。
**Tech Stack:** Go、Bash、Python unittest、GitHub Actions、systemd。

- [x] 引入 v0.4.0 源码、许可证和固定来源；运行旧版构建建立基线。
- [x] 审查旧 fork 接口，迁移到官方 Xray、sing-box、Hysteria 模块，记录适配。
- [x] 增加机器可读实际依赖版本及离线配置检查命令，测试不访问面板的校验行为。
- [x] 实现锁定文件、可复现构建和清单生成，禁止声明与实际模块不符。
- [x] 增加受验证的发布流程及只读上游检查候选流程。
- [x] 新建 core-release.sh、core-jobs.sh，修改 core-install.sh/menu.sh/build.sh；检查来源、摘要、解压路径、版本、平台，后台安装和回滚。
- [x] 新增 tests/test_core_release.py，覆盖恶意包、摘要不符、无发布、已过期适配、同内容跳过、配置预检查和回滚。
- [x] 运行 Python 全套、Go 编译与协议测试、构建生成一致性；更新 README 和版本说明。

验证命令：`python3 -m unittest discover -s tests -v`、`bash build.sh`、`go test ./...`（runtime 目录）。任何失败先定位原因，再修改并重测。初版对未验证的系统/架构保持明确不可用，不以编译通过冒充完整运行验收。

发布边界：签名密钥已配置到 GitHub Actions；本地实现和验证完成后仍需提交/推送并显式运行发布工作流，当前没有生产服务器更新。Linux 原生测试、构建与对应源码打包证据见本次任务输出。
