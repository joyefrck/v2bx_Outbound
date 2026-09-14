# 官方源码内核通道

管理工具 3.7.0 起，菜单 13 使用本仓库 `core-vX.Y.Z` 稳定发布，安装入口使用同一通道。
不再下载 wyx2685/V2bX 的 Release 二进制。V2bX 将多个 Go 内核链接进同一程序；
因此更新的是本仓库适配、测试并构建的完整程序，不能拿独立 xray/sing-box 可执行文件替换其中的库。

## 用户操作

- 菜单 **13**：查看实际安装、官方稳定、已适配可安装版本，然后选择后台更新、查看结果或回滚。
- `v2bx update`：更新到最新已验证构建。
- `v2bx update core-v1.0.0`：指定本仓库稳定构建；不接受旧上游 v0.4.0 标签。
- `v2bx core-versions`：只读查询三类版本。
- `v2bx core-job`：查询后台任务及结果。
- `v2bx core-rollback`：后台恢复上次成功更新之前的内核。

官方稳定版本比已适配版本新时，只说明有新版待适配；不会直接安装未经测试的候选。
没有本仓库稳定发布、网络失败或签名失败时，保留当前程序，不回退旧下载源。
本版通道提供 Linux amd64/arm64。管理工具仍能识别旧 s390x 安装，但不宣称它已有新内核构建。

## 第一组锁定版本

见 `runtime/cores.lock.json`：Xray v26.3.27（Go 模块 v1.260327.0）、sing-box v1.14.0、
Hysteria 2 app/v2.12.2（core/extras 模块 v2.12.2），Go 1.26.1。
这些是此次选择并适配的官方稳定版本，不代表未来一直最新。

V2bX 基础源码的来源、固定提交和许可证在 `runtime/UPSTREAM.md`。
每个官方模块的版本、提交、Go 校验和，以及 Geo 文件的独立来源、版本和 SHA256 均被锁定。
必要的用户管理、协议和并发补丁在 `runtime/patches/`；原文件或补丁摘要变化会使构建失败。
`V2bX build-info` 显示实际编译依赖、替换模块、源码提交和补丁摘要，不将补丁版描述成原封不动的官方二进制。

## 更新事务

1. systemd 后台任务持有现有节点/SOCKS 管理共享锁；下载期间不会重启节点。
2. 验证内置公钥对应的 RSA/SHA256 清单签名、包摘要、文件摘要、精确文件列表、CPU 平台、实际编译信息。
3. 保留现用 Geo 文件，执行新程序的 `check-config` 离线预检查。预检查不启动监听、不访问面板；它检查本地结构、类型与支持的配置构建，不代替面板下发后的协议健康检查。
4. 在 `/etc/V2bX/manager-backups/core-*` 备份程序、Geo 和服务文件，再替换程序。
5. 原本运行的服务通过稳定 PID、重启计数和监听检查后才成功；失败恢复旧文件并再次检查。原本停止的保持停止。
6. 相同完整内容直接跳过。查询后台结果使用 `v2bx core-job`。

手动回滚验证备份程序摘要，保留当前节点、SOCKS、Geo 和服务文件，不回退用户之后的配置修改。
旧内核没有离线检查命令时，回滚依靠服务健康检查；检查失败自动恢复回滚操作前的程序。
断电、强制 SIGKILL 或磁盘故障不能保证脚本完成恢复，必须检查保留的事务目录和备份。

## 配置兼容范围

- 新生成的 sing-box 配置使用结构化 DNS 和 `action: reject`。
- 老管理工具生成的纯 IP/本地 DNS 地址、普通 block 出站及对应规则，可在内存中等价转换；规则顺序、出口标识和原文件保持不变。
- 复杂的旧 DNS、block 选择器、远程 Include 等需要明确迁移，预检查失败时不停止服务。
- sing-box REALITY `Xver` 必须为 0；Xray 已移除的 `DisableIVCheck=true` 会被拒绝。
- 本次验证覆盖 sing-box 9 种 TCP 协议配置和 8 种 UDP 配置（AnyTLS 不在该 UDP 测试中）、Xray 4 种协议、独立 Hysteria 2、用户增删、流量归属、并发读写及 Xray / sing-box 节点 SOCKS 分流。
- 不以这些测试声称所有自定义传输、面板组合或操作系统均已通过验收。生产更新仍须通过安装事务的实际服务检查。

## 开发与发布

```bash
# 本地准备经过校验的私有模块副本
GOTOOLCHAIN=go1.26.1 python3 scripts/core_overlay.py /tmp/v2bx-core.json
# 在 runtime/ 中运行测试，使用上述生成的 /tmp/v2bx-core.mod
# 原生 Linux 构建、源码归档和打包
python3 scripts/build_core.py --output /tmp/core-dist --arch amd64
# 只做交叉编译时加 --build-only
```

`core-runtime.yml` 在原生 Linux amd64 和 arm64 上测试、构建、验证 SOCKS、运行真实 systemd 事务测试，
每个平台生成二进制包、实测清单及包含许可证的对应源码归档。发布 job 只有显式
`workflow_dispatch` 并选择 `publish=true`，且两个架构的全部构建检查通过，才会运行。
它核对相同源码提交、锁定清单和包摘要，签名后先创建 Draft；所有文件上传完整后才转为稳定发布。
普通 push、PR、候选检查均不发布。

首次签名引导使用 `python3 scripts/setup_core_signing.py`，将私钥直接存入本仓库 Actions 的
`CORE_RELEASE_SIGNING_KEY`，仅把公钥嵌入管理脚本；临时私钥文件自动删除。
更换密钥需要兼容旧签名的信任迁移，不能简单覆盖公钥。

`core-upstream.yml` 每周读取三个官方仓库的稳定 Release，输出候选报告和 Actions 摘要，
不自动修改依赖、不自动发版。维护者处理候选时更新版本/提交/Go 校验和、重做补丁基线及补丁摘要，
通过所有验证后提高 `core-vX.Y.Z` 版本号，再运行发布工作流。任何编译或适配失败都阻止发布。
Geo 数据可独立更新锁定版本，已有服务器的 Geo 数据不随菜单 13 被覆盖。

## 本次本地验收状态（2026-09-14）

- macOS 脚本套件：194 项，11 项依赖 Linux/systemd 环境的测试跳过，其余通过。
- Linux 脚本套件及新增内核事务测试通过；独立运行的 3 项真实 systemd 测试通过，包括 SSH 挂断、启动失败恢复和手动回滚。
- macOS 与 Linux arm64 的 Go 包测试通过；协议/流量/用户变更并发测试连续 3 轮通过，包含 UDP 用户撤销。
- Linux arm64 原生构建、对应源码归档、包内摘要、新旧配置预检查/启动、Xray 和 sing-box SOCKS 分流验证通过。
- Linux amd64 静态交叉编译通过；当前本机容器没有 x86-64 执行支持，原生运行验收由发布前的 amd64 CI job 强制执行。
- 两个新工作流通过 actionlint；生成脚本与 SHA256SUMS 一致。
- Actions 签名密钥已配置。本节记录本地验收结果，不代表 GitHub CI、稳定 Release 或生产服务器已完成更新。新通道须在推送后通过原生双架构 CI，再显式执行发布才能提供可安装版本；仅推送代码不会生成稳定 Release。
