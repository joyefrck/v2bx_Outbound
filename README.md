# V2bX 中文 SOCKS 出口助手

给已经安装好的 V2bX 配置 SOCKS5 出口。继续用原安装脚本安装 V2bX、填写面板和节点信息；用这个脚本配置家宽 SOCKS 出口。

## 一键安装并打开菜单

在已安装并配置好 V2bX 的 Linux 服务器上，以 root 登录，复制执行：

```bash
curl -fL --retry 2 -o install-v2bx-socks.sh https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/main/install.sh && bash install-v2bx-socks.sh && v2bx-socks
```

只有 wget 时也可以：

```bash
wget -O install-v2bx-socks.sh https://raw.githubusercontent.com/joyefrck/v2bx_Outbound/main/install.sh && bash install-v2bx-socks.sh && v2bx-socks
```

安装完成后，以后只需输入：

```bash
v2bx-socks
```

每台服务器都可以使用同一条命令。助手读取当前服务器的配置，让你选择节点；没有固定服务器地址、节点 ID 或 SOCKS 账号。

安装器把助手放到 `/usr/local/bin/v2bx-socks`，检查下载文件的 SHA256 和 Bash 语法后再替换。安装器不修改节点配置、不重启 V2bX；在菜单中确认保存出口时才会生效。

轻量版使用 **Bash + jq + curl**，不依赖 Python，也不新增后台服务。服务器已有 jq、curl 时直接使用；缺少时会提示安装对应工具，你无需手工编辑 JSON 配置。

如果服务器无法连接 GitHub，可从本仓库手动下载 `v2bx-socks.sh`，上传到服务器后执行 `bash /root/v2bx-socks.sh`。

## 按提示配置

```text
V2bX SOCKS 出口助手
1. 配置 / 更换一个节点的 SOCKS 出口
2. 只测试 SOCKS（不改配置）
3. 恢复修改前的配置
4. 查看节点与服务状态
5. 查看 SOCKS 出口配置
0. 退出
```

配置顺序：

1. 输入 `1`，再选择节点前面的序号。只有一个节点时直接回车即可；显示的节点 ID 由当前配置读取。
2. 分别填写 SOCKS 的 IP / 域名、端口、用户名和密码。不要在“地址”里填写整条带密码的链接。无账号认证、使用 IP 白名单的服务，用户名直接回车。
3. 等待显示 SOCKS 测试的出口 IP，并与服务商提供的信息核对。测试未通过不会保存配置。
4. 选择 SOCKS 是否支持 UDP。不确定时默认只使用 TCP，并阻断该节点的 UDP；语音、游戏和部分 DNS 使用方式可能需要 UDP 支持。
5. 检查节点、地址和影响说明。输入 `y` 才会备份、保存和重启；回车取消。
6. 用客户端连接该节点，再查看出口 IP。必须经过这一步才能确认完整节点链路正常。

SOCKS 本身不加密。若 SOCKS 服务需要加密隧道，请先按服务商方式建立隧道，再填写 VPS 可以访问的 SOCKS 接入地址。

## 查看已配置的 SOCKS

选择菜单 `5`，按节点查看当前配置文件中保存的 SOCKS 地址、端口、用户名、密码是否已设置以及 UDP 设置。密码始终显示为 `******`，不会显示原文。

未找到本助手的节点专用出站时，会明确提示；已有 SOCKS 出站但节点专用路由缺失时，也会提示检查路由。其他节点或自定义分流的出站不会被当作本节点已配置的出口。

也可以直接运行 `v2bx-socks --show-socks`。查看操作只读取文件，不修改配置、不重启 V2bX，也不进行网络测试；需要验证 SOCKS 连通性时使用菜单 `2`。

## 更换与恢复

更新助手：重新执行上面的一键安装命令。更新只替换助手程序，不会清空已经配置的 SOCKS 出口或备份。下载或校验失败时保留已有助手。

更换 SOCKS：重新选择菜单 `1` 并填写新的接入信息。脚本会更新该节点的规则，不会重复添加。

恢复：菜单 `3` 列出备份，默认选择最新一次修改。恢复的是“这次修改之前”的完整相关文件；若此前多次更换 SOCKS，可按从新到旧的顺序逐次恢复。

每次修改前，原始配置及权限保存于主配置目录下的 `socks-helper-backups/`。目录权限为 `700`，备份和含认证信息的新配置为 `600`。恢复时还原原来的文件权限。

如果主配置、路由或出站被其他脚本或人工改动，助手会检查文件摘要并拒绝覆盖后续修改。此时需要先核对配置，不能强行选择旧备份覆盖。

发生启动失败或写入中断时，助手尝试自动恢复。若终端被强制关闭、进程被强杀或系统断电，重新运行后可通过菜单 `3` 恢复未完成的修改。在无法完整恢复配置时，会保持服务停止，避免读取一半新一半旧的配置。

## 支持范围

- Linux，使用 systemd 的原脚本 V2bX 安装；需要 Bash、jq 1.6+、curl、`ss`、`flock` 和常规 coreutils 工具。
- Xray 和 sing-box 内核。配置格式依据 V2bX v0.4.0；实际 Xray 运行验证使用对应发布版本。
- 每次只修改所选节点的出口，以节点入站标识匹配；可分别为多个节点配置不同 SOCKS。
- 保留已有拦截规则、面板信息、证书和其他节点默认出口。重启发生在整个 V2bX 服务，因此所有现有连接会短暂中断。
- 标准“拦截规则 + 默认出口”配置。已有复杂分流、共享配置文件的多个内核、独立 Hysteria2 内核会明确提示，不自动覆盖。
- 配置须为标准 JSON，相关出站和路由文件须已存在；带注释的 JSONC、符号链接或特殊配置路径会提示退出。
- 不安装、不升级、不重装 V2bX，不改系统路由或 SSH 配置。
- 默认不允许 SOCKS 失败后回退 VPS 直连；未知 UDP 支持时阻断 UDP。
- SOCKS 出口测试通过，只能证明到 SOCKS 的 TCP / HTTPS 链路和当时的出口 IP，不能证明 IP 为家宽、固定出口、UDP 可用或客户端已正确接入。
- 现有 V2bX 未运行、没有节点监听、面板返回 `Server does not exist` 时不应用配置；菜单 `2` 仍可单独测试 SOCKS。

使用原 V2bX 向导重新生成节点配置，可能重建出站和路由文件；完成后重新运行本助手检查或再次配置出口。

## 只读命令

```bash
v2bx-socks --help
v2bx-socks --version
v2bx-socks --status
v2bx-socks --show-socks
```

`--help` 和 `--version` 只需 Bash，不安装依赖，也不读取或修改服务配置。

## 开发与验证

```bash
bash build.sh
python3 -m unittest discover -s tests -v
bash -n install.sh
bash -n v2bx-socks.sh
bash v2bx-socks.sh --help
```

额外的真实内核测试：

```bash
python3 tests/runtime_xray.py /path/to/V2bX
```

该测试只监听本机回环地址，用临时配置和测试账号验证“所选节点经过 SOCKS、另一个节点保持直连”。不连接真实面板或家宽代理。

`build.sh` 检查 `src/helper.sh` 的语法后，生成可独立运行的 `v2bx-socks.sh` 和 `SHA256SUMS`。修改助手源码后应重新构建并一起提交。`install.sh` 负责从此仓库下载、校验和安装命令。

Python 仅用于开发者在本地和 GitHub Actions 运行测试，服务器运行助手不需要它。CI 检查生成文件一致性、路由、回滚、终端交互和安装失败保护。真实内核测试需另外提供 V2bX 二进制。

2.0 版沿用原节点规则标识与备份目录，可恢复 1.0 版对既有配置文件生成的备份。旧版若曾创建原本不存在的配置文件，该类备份应使用保留的 1.0 版脚本恢复。

## 参考

- [V2bX 配置说明](https://v2bx.v-50.me/v2bx/v2bx-pei-zhi-wen-jian-shuo-ming/config)
- [V2bX v0.4.0 入站标识生成源码](https://github.com/wyx2685/V2bX/blob/v0.4.0/node/controller.go)
- [对应 Xray SOCKS 出站解析器](https://github.com/wyx2685/xray-core/blob/a74bf884128d/infra/conf/socks.go)
- [sing-box SOCKS 出站说明](https://sing-box.sagernet.org/configuration/outbound/socks/)
