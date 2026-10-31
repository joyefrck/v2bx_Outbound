# V2bX 对接 Xboard VLESS 配置升级方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 兼容 Xboard 完整 VLESS decryption、保留旧面板参数，并使错误配置在替换监听前被拒绝或在应用失败后恢复。

**Architecture:** 在面板解析层统一新旧加密字段，核心构建层消费规范化值，控制器负责验证、替换、恢复和配置确认。升级官方 Xray 及工具链后继续使用现有可审计补丁、签名清单和双架构发布通道。

**Tech Stack:** Go、Xray、sing-box、Hysteria2、Python 构建/测试、systemd 更新事务。

**状态：** 2026-11-01 已进入源码实施与本地验证；尚未提交、推送或发版。实施结果与限制见 docs/official-cores.md 及本次验收记录。

## 已核实的基准

- 源码 HEAD：`7e561263d0ddd3d3d747636823e7d3ec3e8ce907`。
- 本地锁：`core-v1.0.2`，Go 1.26.1，Xray `v1.260327.0` / `v26.3.27`。
- 配套 Xboard 方案：`/Users/joyefrack/Documents/GitHub/Xboard/docs/superpowers/plans/2026-11-01-vless-panel-upgrade.md`。
- 当前 `VAllssNode` 只读 `encryption/encryption_settings`；Xboard 新接口发送 `decryption`。
- Xray 构建代码已经包含 XHTTP，不需要重新发明传输实现；需要参数覆盖和联调。
- 当前 sing-box 构建路径没有接入 VLESS Encryption，不能静默忽略后当作普通 VLESS 启动。
- 当前配置轮询会提前写入 hash/ETag，并在构建新节点前删除旧节点；失败候选必须补齐重试与恢复语义。

## Task 1：统一新旧字段

**Files:**
- Modify: `runtime/api/panel/node.go`
- Create: `runtime/api/panel/vless.go`
- Create: `runtime/api/panel/vless_test.go`

- [ ] 给 VAllssNode 增加 `Decryption *string`，读取 JSON `decryption`；保留旧字段和 `tlsSettings/networkSettings` 别名。
- [ ] 新纯函数把新完整字符串或旧分段参数规范化为同一服务端值，默认结果为 `none`。
- [ ] 不存在/null 的新字段允许走旧参数；显式空字符串视为非法。旧 `encryption` 为空或 `none` 且没有非空有效加密配置时归一化为 `none`。
- [ ] 新旧两套配置同时出现时分别归一化：结果相同允许，不同则拒绝，包括显式 `none` 与旧非空加密的冲突。不得隐式选择更弱的配置。
- [ ] 检查算法、模式、时间及认证密钥格式，使用核心 Build 做最终验证；对外错误只包含字段路径和原因分类，不包含私钥或完整参数。
- [ ] 测试矩阵：旧普通、旧加密、新普通、新加密、null、新空串、非字符串、同值双写、冲突双写、未知算法、非法密钥。

## Task 2：Xray 构建和其他核心的明确拒绝

**Files:**
- Modify: `runtime/core/xray/inbound.go`
- Modify: `runtime/core/sing/node.go`
- Create: `runtime/core/xray/vless_test.go`
- Modify/Create: `runtime/core/sing/config_compat_test.go`

- [ ] Xray 的 Decryption 使用规范化结果，去掉重复拼接旧字段的逻辑。
- [ ] EnableFallback 与非 none 加密暂定为不支持组合：返回明确错误，不再在 fallback 分支强行写成 `none`；只有独立用例证实支持后才开放。
- [ ] REALITY 目标优先取 Dest，否则取 ServerName；端口用 `net.JoinHostPort` 组合，覆盖 IPv4、域名和 IPv6。
- [ ] TCP/REALITY/Vision、TCP/TLS、XHTTP/REALITY/空 flow 的 Build 和连接测试分别覆盖；不把 uTLS 客户端参数误当作服务端设置。
- [ ] sing-box 选中加密节点或本批尚未实测支持的 XHTTP 组合时，在监听替换前返回能力错误；普通 VLESS 继续工作。
- [ ] 保持用户、流量归属、DNS、路由和 SOCKS 配置，禁止通过重新生成整套配置来适配新字段。

## Task 3：验证后替换与配置确认

**Files:**
- Modify: `runtime/core/interface.go`，增加独立可选的 NodeValidator 接口，不增加 Core 接口的必需方法。
- Modify: `runtime/core/selector.go`
- Modify: `runtime/core/xray/node.go`
- Modify: `runtime/core/xray/dns.go`、`runtime/core/xray/outbound.go`，分离配置编译与运行态应用。
- Modify: `runtime/core/sing/node.go`
- Modify: `runtime/node/controller.go`
- Modify: `runtime/node/task.go`
- Modify: `runtime/api/panel/node.go`、`runtime/api/panel/panel.go`
- Create: `runtime/node/reload_test.go`

- [ ] Xray/sing 实现独立可选的 `NodeValidator.ValidateNode(tag, info, options)`；Selector 使用与 AddNode 相同的核心选择策略转发。VLESS 应用必须经过验证；其他协议不因本次新增接口被迫重写核心实现。覆盖入站、出站、规则及需要的证书文件检查，不在预检中写 DNS 或触发 ACME。
- [ ] Xray 的 DNS 编译改为纯函数；不能在预检调用当前会写 XRAY_DNS_PATH 的 updateDNSConfig。候选应用阶段才写入，失败回滚恢复旧 DNS 文件内容。预检不得修改传入 NodeInfo 的共享 map。
- [ ] 新 NodeInfo 与用户/限制器状态先放在候选对象，不提前覆盖 `c.info/c.tag`。
- [ ] 校验失败保持旧节点、限制器和用户；错误记录脱敏，下一轮可重试候选。
- [ ] 应用阶段保存旧 info/tag/options/users 与限制器可恢复状态，先取回并保留待上报流量，再移除旧监听、添加候选和用户。
- [ ] 候选 AddNode/AddUsers 任一步失败时清理半建候选，恢复旧监听、用户与限制器；恢复失败返回明确失败状态并通知，不 panic 导致其他节点一起退出。不能把失败当成应用成功。
- [ ] 只有监听和用户全部应用成功后才提交 c.info 和客户端确认的 hash/ETag；初次 Start 同样在成功后确认。失败候选不更新已接受 hash，防止后续轮询跳过未应用配置。
- [ ] 测试假 Core 的调用顺序、预检失败不 DelNode、安装失败恢复、用户添加失败恢复、hash/ETag 重试、初次启动失败，以及同一进程其他节点保持可用。
- [ ] 新的预检和受保护替换分支限定 VLESS；运行现有 HY2 回归，不修改其证书等待、UDP readiness 或节点实现。

此路径允许短暂重连，不宣称同端口零中断。控制器负责应用状态，不把这一责任放到面板解析器或管理脚本中。

## Task 4：加密参数生成

**Files:**
- Create: `runtime/cmd/vlessenc.go`
- Create: `runtime/cmd/vlessenc_test.go`

- [ ] 提供 `V2bX vlessenc --json --auth x25519` 和 `--auth mlkem768`，只在本机生成参数，不访问面板、不保存文件、不重启服务。
- [ ] 使用 Go 标准密码库生成配对认证材料，沿用固定 Xray 版本的规范；默认 native 模式、服务端 600s、客户端 0rtt，与官方工具的对应方案一致。
- [ ] JSON 只输出本次生成的 `encryption/decryption` 配对值；测试客户端认证材料对应服务端密钥，并且生成结果能被客户端与服务端解析。
- [ ] 保留既有 `x25519` 命令行为；不把 REALITY 密钥和 VLESS Encryption 配对参数混为一组。

## Task 5：官方 Xray 与工具链升级

**Files:**
- Modify: `runtime/go.mod`、`runtime/go.sum`
- Modify: `runtime/cores.lock.json`
- Modify: `runtime/patches/index.json` 和与 Xray 相关的替换文件/许可证路径
- Modify: `.github/workflows/core-runtime.yml`
- Modify: `scripts/core_sources.py`
- Modify: `docs/official-cores.md`

- [ ] 候选锁定 Xray 发布 `v26.10.31` 对应提交 `a4a3dff5b20c2faae567b742c172c7b95e75c083`，工具链 Go 1.27.3。该版本包含默认关闭 MPTCP 的安全调整。
- [ ] 使用已解析的模块版本 `v1.260327.1-0.20261031132019-a4a3dff5b20c`。该值由 `go list -m -json github.com/xtls/xray-core@a4a3dff5b20c2faae567b742c172c7b95e75c083` 得到；实施时再次核对提交并用 checksum database 验证下载内容后写入依赖锁和实际编译信息。2026-11-01 的 `v1.261031.0` 查询为 404，不能自行推算版本号；若校验失败，该候选不得发布。
- [ ] 重新对齐 Xray 补丁基线、模块目录、原文件 SHA256、替换文件 SHA256 和 patch index 摘要；不关闭摘要检查或绕过编译错误。
- [ ] 其他核心版本保持当前锁定目标；若 Go 最小版本选择引起间接依赖变化，逐项核对后记录，不能声称所有依赖都未变化。
- [ ] 测试 Go 1.27.3 下 jsonv2 构建参数、来源归档说明和原生 amd64/arm64；不能只更新 workflow 而遗留 source archive 中 Go 1.26.1 的硬编码说明。
- [ ] 发布版本建议 `core-v1.1.0`，实际使用前先检查 tag 未占用。使用既有源码包、清单签名、双架构和后台回滚通道，不替换为独立 xray 可执行文件。
- [ ] 管理工具只在必要时更新版本/能力提示；不重写现有 DNS、Geo、节点或 SOCKS 参数。

## Task 6：测试矩阵与联调

- [ ] 准备受校验的私有模块副本：`GOTOOLCHAIN=go1.27.3 python3 scripts/core_overlay.py /tmp/v2bx-vless-core.json`。
- [ ] 在 runtime 运行：`GOTOOLCHAIN=go1.27.3 go test -timeout 180s -modfile=/tmp/v2bx-vless-core.mod -mod=readonly -tags 'sing xray hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor' ./...`。
- [ ] 对新解析/生命周期包及既有用户管理包运行对应 race 测试；对无监听预检断言没有端口、面板请求、文件写入或 DNS/用户状态变化。
- [ ] 新增 `tests/runtime_vless.py`：回环 mock panel + 测试用户 + 独立服务端/客户端进程，真实访问本地 HTTPS/流量目标；覆盖旧格式、新格式、参数变化、错误字段、用户撤销、流量归属及 SOCKS 出口。
- [ ] 把上述用例加入 `.github/workflows/core-runtime.yml` 双架构原生 job；继续执行 `tests/runtime_xray.py`、`tests/runtime_config.py`、`tests/runtime_hy2_geo.py`、`tests/runtime_hy2_socks.py` 和真实 systemd 更新事务测试。
- [ ] 运行 `python3 -m unittest discover -s tests -v`；脚本改动时执行 `bash build.sh` 并检查生成入口/SHA256SUMS 一致。
- [ ] 连通性矩阵至少包含：旧面板+新 V2bX；新面板普通节点+旧 V2bX；新面板普通/增强节点+新 V2bX；新面板增强节点+旧 V2bX 明确禁止启用。
- [ ] 真实客户端记录具体构建版本。当前客户端源码实现了加密不能代替实际安装包与订阅的联通验证。

## 发布顺序与回滚

1. Xboard P0 先独立发布和完整验收。
2. V2bX 新核心构建、源码及签名验证通过，先升级测试节点，仍使用旧配置验证。
3. 发布 Xboard VLESS 表单/API/订阅，增强项保持默认关闭。
4. 在独立测试节点和端口启用加密或 XHTTP，验证对应客户端；通过后再安排后续范围。
5. 回退前先恢复旧协议并验证订阅更新，再回退 V2bX。原有后台 updater 保留镜像/程序备份及现有 Geo/SOCKS。

安全候选回滚到旧 Xray 会恢复旧的安全风险，必须单独记录并采取对应系统级隔离/修复，不能把协议回滚当成安全验收通过。生产内核及 MPTCP 的实际暴露情况仍需独立核实。

## 完成判据

新旧协议字段无歧义、失败配置不降级、失败更新可重试、旧监听可恢复；Xray 新版在两种架构上通过全部核心/用户/流量/SOCKS/HY2 回归；签名来源可审计；测试节点的真实客户端和业务流量验收通过。源码修改、CI 通过、稳定发布和生产更新分别报告。

## 2026-11-01 本地实施验收

- 全包 Go 和重点包 race 通过；脚本套件 249 项中 236 通过、13 项 Linux/systemd 条件用例在 macOS 跳过。
- Linux arm64 以源码锁定的官方 Mihomo 1.19.33 跑通六组回环 HTTPS、无效参数保留/重试、流量归属及用户撤销。
- Linux arm64 的 Xray/Sing SOCKS 分流与撤销、HY2 SOCKS、Geo 路径、新旧配置启动回归通过。
- Linux amd64/arm64 最新源码交叉编译通过；amd64 原生运行和完整双架构 CI、签名归档及生产验收尚未执行。
- 新 REALITY 混合 KeyShare 兼容参数必须随实际后端版本同步登记并刷新订阅；旧缓存不能视为自动兼容。
- 本次未提交、推送、发布或部署；具体兼容边界见 docs/official-cores.md。
