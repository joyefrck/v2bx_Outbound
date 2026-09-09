# Debian 11 依赖安装恢复

截图证明管理工具下载与校验成功，APT 因 backports 404 和安全索引过期退出。官方 bullseye-security Release 的 Date 为 2026-08-31，有效期到 2026-09-07；官方 LTS 于 2026-08-31 结束。

实现只覆盖依赖安装：优先现有 APT 配置，失败后仅在 Debian 11 使用临时官方 main/security 源及隔离 lists 目录。安全源单独放宽历史索引有效期，保持签名、包哈希、未来时间检查；不覆盖系统源，不启用 backports，不允许删除现有软件包。安装失败必须停止后续内核安装。

验证顺序：模拟正常 APT、Bullseye 回退、其他发行版拒绝回退、回退更新及安装失败；实际 Debian 11 容器复现索引过期，再安装所有依赖并比较源文件前后校验和；完整 Linux 测试与 CI。

参考：https://www.debian.org/releases/bullseye/；https://security.debian.org/debian-security/dists/bullseye-security/Release；https://lists.debian.org/debian-devel-announce/2025/06/msg00003.html。
