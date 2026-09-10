# V2bX 安装与可选 SOCKS 出口管理

一个中文入口完成 **安装 V2bX → 配置面板与节点 → 检查运行状态 → 可选配置 SOCKS5 出口**。
已有 V2bX 时保留节点配置与服务状态，安装管理工具后直接打开菜单，不自动重装。

## 一键安装

在 Debian/Ubuntu、CentOS/Rocky/Alma 系列的 systemd Linux 服务器上，以 root 执行：

```bash
curl -fL --connect-timeout 15 --max-time 90 --retry 5 --retry-delay 3 -o install-v2bx.sh.tmp https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/main/install.sh && test -s install-v2bx.sh.tmp && bash -n install-v2bx.sh.tmp && mv install-v2bx.sh.tmp install-v2bx.sh && bash install-v2bx.sh
```

只有 wget 时：

```bash
(
  for attempt in 1 2 3 4 5 6; do
    if wget --https-only --timeout=30 --tries=1 -O install-v2bx.sh.tmp https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/main/install.sh && test -s install-v2bx.sh.tmp && bash -n install-v2bx.sh.tmp; then
      mv install-v2bx.sh.tmp install-v2bx.sh && bash install-v2bx.sh
      exit $?
    fi
    [ "$attempt" = 6 ] || sleep 3
  done
  rm -f install-v2bx.sh.tmp
  echo '安装入口下载失败，请稍后重试。' >&2
  exit 1
)
```

出现 `503 Backend.max_conn reached` 表示本次 HTTP 下载端暂时无法处理请求。入口下载成功后，安装器仍需获取提交号、校验清单和管理脚本，所以可能在后续下载再次遇到 503。
安装器对每个地址最多尝试 4 次，间隔 2、4、6 秒；固定提交的 Raw 文件下载失败后，自动改用 GitHub 官方 Contents API 获取同一提交的原始文件，并继续校验 SHA256。最终失败会显示具体地址并保留旧工具。官方 API 也可能限流或故障，此时稍后重试；不需要修改节点配置。

如果 Debian 11 安装依赖时出现 `bullseye-backports` 404、安全索引过期或软件包 404，管理工具会在原有 APT 更新或安装失败后，改用临时官方源和 **2026-08-31 的 Debian 官方安全更新快照**。快照同时提供对应索引和软件包，避免索引可读、实际下载地址却返回 404。它不覆盖 `/etc/apt` 下的配置，不使用 backports；只对固定安全快照设置 `check-valid-until=no`，签名及软件包校验继续生效。临时源和索引用完清理，系统原有软件源仍需单独维护。CI 使用原生 AMD64 Debian 11 容器实际安装依赖并运行 jq。
Debian 11 官方 LTS 已于 2026-08-31 结束；此兼容处理不代表恢复安全更新，长期使用应安排升级系统。

CentOS 7.9 的 systemd 不提供 `NRestarts`，显式查询这个属性会导致服务读取失败。管理工具 3.4.3 / SOCKS 助手 2.5.1 起读取实际可用的属性，继续校验 `active/running`、主进程 PID、进程启动时间及监听端口；新系统同时保留重启计数检查。真实 systemd 查询错误会显示原始报错，配置失败仍执行回滚。

首次安装后按提示填写面板地址、API Key、内核、节点 ID 和协议。API Key、DNS 密钥和 SOCKS 密码输入时直接显示，便于核对；支持多个节点共用面板。
可以暂时跳过节点配置，之后运行 `v2bx generate`。服务启动并稳定监听后，询问是否配置 SOCKS：**默认回车跳过**。
跳过 SOCKS 不影响普通 V2bX 使用；之后随时运行 `v2bx socks`。

面板节点信息错误、没有监听或服务启动失败时，不进入 SOCKS 应用流程。安装二进制成功不代表节点已可用。

## 统一管理菜单

安装后输入 `v2bx` 或 `V2bX`。首页字符 Logo 下显示 V2bX 运行状态和是否开机自启，每次返回菜单时刷新；服务已运行仅表示进程状态，节点是否可用仍需实际连接验证。菜单按节点与出口、服务控制、安装与维护分组，选项逐行显示，编号从上到下连续递增（1–19）：

标题与编号为青蓝色，正文和输入提示为柔和的灰蓝色，成功状态为绿色，提醒为黄色，错误为红色。节点核心、协议和证书模式独立成行。普通 SSH 终端自动启用颜色；重定向输出、`TERM=dumb` 或设置 `NO_COLOR=1` 时使用纯文本。

```text
◇ 节点与出口
1. 修改配置（节点管理）
2. 生成节点配置
3. SOCKS 出口管理
4. 查看 V2bX 状态
5. 查看日志（持续跟踪新增日志，Ctrl+C 返回菜单）

↻ 服务控制
6. 启动 V2bX
7. 停止 V2bX
8. 重启 V2bX
9. 设置开机自启
10. 取消开机自启

⚙ 安装与维护
11. 安装 V2bX
12. 更新 V2bX 内核
13. 更新管理工具（含 SOCKS 助手）
14. 查看 V2bX 版本
15. 生成 X25519 密钥
16. 安装 BBR
17. 放行所有网络端口
18. 卸载 V2bX

19. 退出 · 下次见
```

菜单 13 更新本仓库的管理工具和助手，菜单 12 只更新 V2bX 二进制。BBR 和防火墙功能只有手动选择并确认才会执行。

```bash
v2bx install           # 首次安装与配置向导
v2bx generate          # 共用节点向导
v2bx socks             # SOCKS 管理
v2bx update v0.4.0     # 指定内核版本；省略版本则获取上游最新版
v2bx update_shell      # 更新本仓库管理工具
v2bx --help
```

## 引导式修改、新增和删除节点

运行 `v2bx config` 或选择主菜单 **1. 修改配置（节点管理）**：

```text
1. 修改现有节点
2. 新增节点
3. 删除节点
4. 返回
```

- **修改**：先列出现有节点的序号、名称、面板地址、ID、协议和内核，选择并确认目标；再选择要修改的面板地址、API Key、节点 ID、协议、TLS/证书、监听地址或出站源地址。普通字段显示当前值；API Key 和 DNS 密钥填写时直接显示，回车保留原值。没有实际修改时不保存、不重启。
- **新增**：复用菜单 2 的完整填写向导：填写面板地址和 API Key，选择后续节点是否共用面板信息，再依次填写内核、ID、协议及证书；可连续添加多个节点。同类型已有内核会自动引用（多个时列出选择），没有时才追加内核。最后一次确认后只追加新节点，原有节点、内核参数和出口规则全部保留；中途取消或校验失败不会保存半批节点。新内核需要的文件只有不存在时才创建。
- **删除**：列出现有节点，选择并确认目标，再确认备份和应用。删除该节点以及对应的助手 SOCKS 出站、节点路由和 UDP 阻断规则，保留其他节点及自定义分流；删除最后一个节点后停止 V2bX。

修改保留未编辑字段、内核参数和已有 SOCKS 出口。修改面板地址、ID 或协议时，程序保留该节点原有的路由标识，避免已有 SOCKS 或自定义节点规则失效。修改向导不切换现有节点的内核；需要另一内核时使用新增节点。

每次应用前备份到 `manager-backups/nodes-*`，`paths.json` 记录文件路径，序号 `.before` 文件保留原始内容及权限，`.absent` 表示原本不存在的文件。保存前检查配置是否被其他操作改动，启动失败时恢复本次涉及的全部文件。重复节点或存在共享、异常 SOCKS 规则时拒绝保存，不自动覆盖。

这与菜单 **2. 生成节点配置** 不同：菜单 1 只处理选定节点，菜单 2 会重新生成整套节点配置。

## 旧用户升级与文件保护

重新执行上面的一键命令即可纳入统一菜单。原 `v2bx-socks` 命令、只读参数、SOCKS 备份和后台任务保持兼容。
如果只想更新旧助手，不安装统一管理工具：

```bash
bash install-v2bx.sh --helper-only
```

`--tools-only` 只安装或更新管理工具与助手，不更新内核、不修改节点、不重启服务。
安装器从同一 GitHub 提交下载并校验发布文件，检查 Bash 语法后替换；失败恢复旧工具。
工具安装到 `/usr/bin/V2bX`、`/usr/bin/v2bx` 和 `/usr/local/bin/v2bx-socks`。

内核安装/更新先下载、解压并检查新文件，再替换。原二进制、Geo 数据和服务文件备份到
`/etc/V2bX/manager-backups/`；失败尝试恢复，原服务停止时更新后也保持停止。

重新生成节点配置会重建 `config.json`、`custom_outbound.json`、`route.json`、`sing_origin.json` 和 `hy2config.yaml`，
**重置相关 SOCKS 规则**。向导两次确认后备份所有覆盖文件及权限，再保存和启动检查；失败恢复原文件。
这类备份位于 `manager-backups/config-*`，与 SOCKS 助手菜单 5 使用的 `socks-helper-backups` 分开。
配置生成与 SOCKS 后台任务共用配置锁，不允许同时修改。

统一向导沿用上游默认拦截规则，支持 Xray、sing-box 和独立 Hysteria2；SOCKS 仍限 Xray / sing-box。
TLS 可选择 HTTP/DNS 自动申请、已有证书或自签证书。DNS 参数和面板密钥不显示原文。
暂不支持 Alpine/OpenRC、普通 Docker 安装、非标准服务布局。断电或强杀进程时应根据保留的备份检查恢复。

## SOCKS 助手

使用 `v2bx socks`、统一菜单 3 或旧命令 `v2bx-socks` 打开。
助手是 **Bash + jq + curl**，服务器不需要 Python。运行依赖在统一管理工具首次运行时安装。

## 按提示配置

```text
V2bX SOCKS 出口助手
1. 配置 / 更换一个节点的 SOCKS 出口
2. 只测试 SOCKS（不改配置）
3. 查看 SOCKS 出口配置
4. 查看节点与服务状态
5. 恢复修改前的配置
6. 检查 / 更新助手
7. 退出
```

配置顺序：

1. 输入 `1`，再选择节点前面的序号。只有一个节点时直接回车即可；显示的节点 ID 由当前配置读取。
2. 选择输入方式：默认 `1. 快捷配置`，直接回车后粘贴 `IP:端口:用户名:密码`，例如 `192.0.2.10:1080:example-user:example-pass`；IPv6 使用 `[2001:db8::1]:1080:example-user:example-pass`。用户名后的内容完整作为密码，支持密码含冒号。选择 `2. 逐项输入` 则按原方式分别填写；用户名含冒号或使用无认证 / IP 白名单时选此方式，无认证的用户名直接回车。两种方式输入均直接显示，“只测试 SOCKS”也支持这两种输入方式。
3. 等待显示 SOCKS 测试的出口 IP，并与服务商提供的信息核对。测试未通过不会保存配置。
4. 选择 SOCKS 是否支持 UDP。不确定时默认只使用 TCP，并阻断该节点的 UDP；语音、游戏和部分 DNS 使用方式可能需要 UDP 支持。
5. 检查节点、地址和影响说明。输入 `y` 后交给独立后台任务备份、保存和重启；回车取消。提交成功后 SSH 断开也会继续执行。
6. 重连后运行 `v2bx-socks` 或 `v2bx-socks --last-job` 查看最近任务结果，再用客户端连接该节点查看出口 IP。必须经过这一步才能确认完整节点链路正常。

SOCKS 本身不加密。若 SOCKS 服务需要加密隧道，请先按服务商方式建立隧道，再填写 VPS 可以访问的 SOCKS 接入地址。

## SSH 断开也能完成配置（2.3.0）

如果 SSH 本身经过正在配置的 V2bX 节点，重启节点会切断 SSH；保活设置无法避免这种断连。从 2.3.0 起，保存和恢复均由一次性 systemd 后台任务执行，独立于 SSH 会话，仍保留配置备份、漂移检查、启动检查和失败回滚。

确认后菜单会等待结果；若断线，重新登录后运行 `v2bx-socks --last-job`。再次打开菜单也会显示最近任务的结果。正在执行时会阻止新的配置操作；任务失败或无法确认完成时会明确提示，不会当作成功。任务成功后仍需用客户端确认完整链路。

后台任务使用系统已有的 `systemd-run`，不增加 Python、tmux 或常驻服务。任务结束后自动删除含认证信息的工作副本，保留私有日志、结果和原有配置备份。启动后台任务失败时不会退回前台重启。机器断电或进程被强杀不属于 SSH 断开保护范围；请根据提示检查服务并恢复未完成的备份。

当前使用旧版时，先通过菜单 `6` 更新助手，然后重新打开菜单使用。

## 查看已配置的 SOCKS

选择菜单 `5`，按节点查看当前配置文件中保存的 SOCKS 地址、端口、用户名、密码是否已设置以及 UDP 设置。密码始终显示为 `******`，不会显示原文。

未找到本助手的节点专用出站时，会明确提示；已有 SOCKS 出站但节点专用路由缺失时，也会提示检查路由。其他节点或自定义分流的出站不会被当作本节点已配置的出口。

也可以直接运行 `v2bx-socks --show-socks`。查看操作只读取文件，不修改配置、不重启 V2bX，也不进行网络测试；需要验证 SOCKS 连通性时使用菜单 `2`。

## 更换与恢复

更新助手：选择菜单 `6. 检查 / 更新助手`，查看当前版本和仓库版本。有更新时输入 `y` 确认，脚本会备份当前助手、更新文件并自动重新打开新版菜单。没有更新时会提示“已是最新版本”，不会重复安装，也不会自动降级。

更新只替换当前运行的助手文件，保留原文件权限、已配置的 SOCKS 出口和配置备份，不重启 V2bX。旧助手保存在原路径旁的 `.bak-版本-摘要` 文件中。下载或校验失败时保留当前助手。

**旧版菜单里还没有 `6`？** 先重新执行一次上面的一键安装命令，升级到 2.2.0 或更新版本，之后就能直接从菜单更新。每台服务器需要分别操作。

更新检查需要连接 GitHub API 和下载服务；无法连接或 API 请求受限时会提示稍后重试。脚本和校验文件固定从同一次 GitHub 提交下载，避免分支缓存不同步造成文件混用。

更换 SOCKS：重新选择菜单 `1` 并填写新的接入信息。脚本会更新该节点的规则，不会重复添加。

恢复：菜单 `3` 列出备份，默认选择最新一次修改。恢复的是“这次修改之前”的完整相关文件；若此前多次更换 SOCKS，可按从新到旧的顺序逐次恢复。

每次修改前，原始配置及权限保存于主配置目录下的 `socks-helper-backups/`。目录权限为 `700`，备份和含认证信息的新配置为 `600`。恢复时还原原来的文件权限。

如果主配置、路由或出站被其他脚本或人工改动，助手会检查文件摘要并拒绝覆盖后续修改。此时需要先核对配置，不能强行选择旧备份覆盖。

发生启动失败或写入中断时，助手尝试自动恢复。SSH 断开或终端关闭不会中止已提交的后台任务。若后台进程被强杀或系统断电，重新运行后可通过菜单 `3` 恢复未完成的修改。在无法完整恢复配置时，会保持服务停止，避免读取一半新一半旧的配置。

## 支持范围

- Linux，使用 systemd 的原脚本 V2bX 安装；需要 Bash、jq 1.6+、curl、`ss`、`flock`、`systemd-run` 和常规 coreutils 工具。
- Xray 和 sing-box 内核。配置格式依据 V2bX v0.4.0；实际 Xray 运行验证使用对应发布版本。
- 每次只修改所选节点的出口，以节点入站标识匹配；可分别为多个节点配置不同 SOCKS。
- 保留已有拦截规则、面板信息、证书和其他节点默认出口。重启发生在整个 V2bX 服务，因此所有现有连接会短暂中断。
- 标准“拦截规则 + 默认出口”配置。已有复杂分流、共享配置文件的多个内核、独立 Hysteria2 内核会明确提示，不自动覆盖。
- 配置须为标准 JSON，相关出站和路由文件须已存在；带注释的 JSONC、符号链接或特殊配置路径会提示退出。
- SOCKS 子菜单只负责出口配置；安装和升级由统一管理菜单单独执行。SOCKS 助手不改系统路由或 SSH 配置。
- 默认不允许 SOCKS 失败后回退 VPS 直连；未知 UDP 支持时阻断 UDP。
- SOCKS 出口测试通过，只能证明到 SOCKS 的 TCP / HTTPS 链路和当时的出口 IP，不能证明 IP 为家宽、固定出口、UDP 可用或客户端已正确接入。
- 现有 V2bX 未运行、没有节点监听、面板返回 `Server does not exist` 时不应用配置；菜单 `2` 仍可单独测试 SOCKS。

重新生成节点配置后，请从统一菜单 3 检查或再次配置 SOCKS 出口。

## 只读命令

```bash
v2bx-socks --help
v2bx-socks --version
v2bx-socks --status
v2bx-socks --show-socks
v2bx-socks --last-job
```

`--help` 和 `--version` 只需 Bash，不安装依赖，也不读取或修改服务配置。

## 开发与验证

```bash
bash build.sh
python3 -m unittest discover -s tests -v
bash -n install.sh
bash -n v2bx-socks.sh
bash -n v2bx-manager.sh
bash v2bx-socks.sh --help
bash v2bx-manager.sh --help
```

额外的真实内核测试：

```bash
python3 tests/runtime_xray.py /path/to/V2bX
```

该测试只监听本机回环地址，用临时配置和测试账号验证“所选节点经过 SOCKS、另一个节点保持直连”。不连接真实面板或家宽代理。

`build.sh` 从 `src/helper.sh` 和 `src/manager/` 生成两个独立脚本及 `SHA256SUMS`。
修改源码或安装器后必须重新构建，一起提交产物、校验文件及许可证。CI 检查发布一致性、安装保护、节点向导、路由、回滚及终端交互。

真实 systemd 验证只在一次性 Linux 环境执行：

```bash
V2BX_SYSTEMD_TEST=1 python3 -m unittest discover -s tests -v
# 需要已安装 v0.4.0 内核与统一管理工具，且尚无 config.json：
V2BX_MANAGER_RUNTIME_TEST=1 python3 tests/runtime_manager.py
```

后一个测试会使用本地面板测试接口创建两个真实 VLESS 节点，验证向导默认跳过 SOCKS，
再通过后台任务配置 SOCKS，检查选中节点转发和另一个节点保持直连，并通过真实终端验证节点修改、新增、删除及最后一个节点停止服务；会修改该测试环境的服务与配置，不能在生产服务器运行。
测试入口与临时数据均使用虚构账号；真实业务节点仍须用客户端验收实际出口 IP。

上游脚本固定于 `c532ec57a67d7544c700f3f438c09dffcd0b1313`，原始参考代码、来源说明和 MPL-2.0 许可证保存在 `vendor/v2bx-script/`。
整合后的运行代码由本仓库维护，不会在更新时下载原版管理菜单覆盖 SOCKS 入口。

Python 仅用于开发者在本地和 GitHub Actions 运行测试，服务器运行助手不需要它。CI 检查生成文件一致性、路由、回滚、终端交互和安装失败保护。真实内核测试需另外提供 V2bX 二进制。

2.0 版沿用原节点规则标识与备份目录，可恢复 1.0 版对既有配置文件生成的备份。旧版若曾创建原本不存在的配置文件，该类备份应使用保留的 1.0 版脚本恢复。

## 参考

- [V2bX 配置说明](https://v2bx.v-50.me/v2bx/v2bx-pei-zhi-wen-jian-shuo-ming/config)
- [V2bX v0.4.0 入站标识生成源码](https://github.com/wyx2685/V2bX/blob/v0.4.0/node/controller.go)
- [对应 Xray SOCKS 出站解析器](https://github.com/wyx2685/xray-core/blob/a74bf884128d/infra/conf/socks.go)
- [sing-box SOCKS 出站说明](https://sing-box.sagernet.org/configuration/outbound/socks/)
