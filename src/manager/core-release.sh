# Official modules are linked into our own runtime; standalone upstream binaries
# cannot replace these embedded cores. Only reviewed core-* releases are installable.
M_CORE_REPO=joyefrck/v2bx_Outbound
m_arch() {
    case $(uname -m) in x86_64|amd64) printf amd64;; aarch64|arm64) printf arm64;; *) m_error '官方内核通道目前只提供 Linux amd64 / arm64。'; return 1;; esac
}
m_core_public_key() {
    cat <<'PUBLIC_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAqpIrKsQf5BCQvnLNf1Da
nfv7tdnwNg46WTKNnZ+Aop8VWyz5R/QA8KYT5hb3TiSU6o6jcAeR268U3T7NQm27
wa0ea1Z+MBJhpYiyt4bguEnFLPEhcufdmgRQFLyHe9BDiXHAe8n/yh3ISi44Ge0Y
h/LsGnSo6H0PZ22Zukegq2/E1IRmNXkF2znwuFGTNoiWjGcRsJcxIImq7tGgMcS8
dvhY8bpY3CBT1fRJ8E9bQOyNZO5hXDmoFQ+xtKEmoe9zVfMaRyjp1zkRtMKo4lP5
4l30wubHNJkep9/7g6p07XRsgo8uPaIKC9ORC9Nz+ZovAjEYKX8eNXIWR55BzKCM
v4f4dRFmdZCQDlAoKe8xc07c24mcR7GzvHjey1xoVKC0JPC9MOdtpuTmNyQy1WJU
Hk8MJGeWQiRmv2Y1/xeaXYxbOIWvxZ4+fPVeF5sIaBtOAy28oI66fabG9R3X0KGQ
puPIrFrGhPT+mcU1YGG/39/QvmmW40E76uMk8xVWcdb9AgMBAAE=
-----END PUBLIC KEY-----
PUBLIC_KEY
}
m_core_release() {
    local output=$1 tag=${2:-}
    if [[ -n $tag ]]; then
        [[ $tag =~ ^core-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { m_error '请使用本仓库 core-vX.Y.Z 版本号。'; return 1; }
        m_fetch "https://api.github.com/repos/$M_CORE_REPO/releases/tags/$tag" "$output" || return 1
        jq -e --arg tag "$tag" '.tag_name==$tag and .draft==false and .prerelease==false' "$output" >/dev/null || return 1
    else
        m_fetch "https://api.github.com/repos/$M_CORE_REPO/releases?per_page=100" "$output.list" || return 1
        jq -e '[.[]|select(.draft==false and .prerelease==false and (.tag_name|test("^core-v[0-9]+\\.[0-9]+\\.[0-9]+$")))]|sort_by(.published_at)|last // empty' "$output.list" > "$output" || {
            m_error '尚无经过验证的稳定内核发布，保留当前版本；不会回退到旧 V2bX 下载源。'; return 1;
        }
    fi
}
m_core_manifest() {
    local stage=$1 requested=${2:-} arch tag base manifest
    arch=$(m_arch) || return 1
    m_core_release "$stage/release.json" "$requested" || return 1
    tag=$(jq -er '.tag_name' "$stage/release.json") || return 1
    [[ $tag =~ ^core-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    base="https://github.com/$M_CORE_REPO/releases/download/$tag"
    manifest="manifest-linux-$arch.json"
    m_fetch "$base/$manifest" "$stage/manifest.json" && m_fetch "$base/$manifest.sig" "$stage/manifest.sig" || return 1
    m_core_public_key > "$stage/public.pem" || return 1
    openssl dgst -sha256 -verify "$stage/public.pem" -signature "$stage/manifest.sig" "$stage/manifest.json" >/dev/null 2>&1 || {
        m_error '内核清单签名校验失败，未安装。'; return 1;
    }
    jq -e --arg tag "$tag" --arg arch "$arch" '
      .schema==1 and .source_state=="commit" and .tag==$tag and .version==($tag|ltrimstr("core-")) and
      .platform==("linux-"+$arch) and .asset==("V2bX-linux-"+$arch+".zip") and
      (.source_revision|test("^[0-9a-f]{40}$")) and (.patch_index_sha256|test("^[0-9a-f]{64}$")) and
      (.sha256|test("^[0-9a-f]{64}$")) and
      (.files|keys)==["V2bX","build-info.json","cores.lock.json","geoip.dat","geosite.dat"] and
      all(.files[];test("^[0-9a-f]{64}$")) and
      (.cores|keys)==["hysteria2","hysteria2-extras","sing-box","xray"]
    ' "$stage/manifest.json" >/dev/null || { m_error '清单格式或平台不匹配。'; return 1; }
}
m_prepare_core() {
    local stage=$1 requested=${2:-} arch tag file entry expected actual count=0
    m_core_manifest "$stage" "$requested" || return 1
    arch=$(m_arch) || return 1
    tag=$(jq -er '.tag' "$stage/manifest.json") || return 1
    printf '正在下载已验证内核 %s（Linux %s）……\n' "$tag" "$arch"
    m_fetch "https://github.com/$M_CORE_REPO/releases/download/$tag/V2bX-linux-$arch.zip" "$stage/core.zip" || return 1
    expected=$(jq -er '.sha256' "$stage/manifest.json") || return 1
    [[ $(m_core_file_hash "$stage/core.zip") == "$expected" ]] || { m_error '发布包摘要不符。'; return 1; }
    unzip -tq "$stage/core.zip" >/dev/null && unzip -Z1 "$stage/core.zip" > "$stage/entries" || return 1
    while IFS= read -r entry; do
        case $entry in V2bX|build-info.json|cores.lock.json|geoip.dat|geosite.dat) ;; *) m_error '发布包包含非预期路径。'; return 1;; esac
        count=$((count+1))
    done < "$stage/entries"
    [[ $count == 5 ]] && (( $(LC_ALL=C sort -u "$stage/entries" | wc -l) == 5 )) || return 1
    unzip -l "$stage/core.zip" | awk 'END {exit !($1 ~ /^[0-9]+$/ && $1 < 536870912)}' || return 1
    mkdir "$stage/new" && unzip -q "$stage/core.zip" -d "$stage/new" || return 1
    [[ -z $(find "$stage/new" -type l -print -quit) ]] || return 1
    while IFS= read -r file; do
        [[ -s $stage/new/$file && -f $stage/new/$file ]] || return 1
        expected=$(jq -er --arg f "$file" '.files[$f]' "$stage/manifest.json") || return 1
        [[ $(m_core_file_hash "$stage/new/$file") == "$expected" ]] || return 1
    done < "$stage/entries"
    chmod 755 "$stage/new/V2bX" || return 1
    "$stage/new/V2bX" build-info > "$stage/actual.json" || return 1
    jq -e --slurpfile m "$stage/manifest.json" '
      .schema==1 and .source_state=="commit" and .os=="linux" and ("linux-"+.arch)==$m[0].platform and
      .version==$m[0].version and .source_revision==$m[0].source_revision and
      .patch_index_sha256==$m[0].patch_index_sha256 and
      (.cores|sort)==["hysteria2","sing","xray"] and
      (.modules as $actual | all($m[0].cores|to_entries[]; $actual[.key].path==.value.path and $actual[.key].version==.value.version))
    ' "$stage/actual.json" >/dev/null || { m_error '实际编译内核与清单不符。'; return 1; }
    # Keep signed provenance with the installed payload for auditing and rollback.
    cp "$stage/manifest.json" "$stage/new/core-manifest.json" && cp "$stage/manifest.sig" "$stage/new/core-manifest.sig" || return 1
}
m_core_preflight() {
    local binary=$1
    [[ -f $M_CONFIG/config.json ]] || return 0
    (cd "$M_BINARY" && timeout 45 "$binary" check-config -c "$M_CONFIG/config.json") || {
        m_error '新内核本地配置预检查失败，服务未停止。请先处理配置兼容性。'; return 1;
    }
}
m_core_versions() (
    local stage name repo latest
    umask 077
    stage=$(mktemp -d /tmp/v2bx-versions.XXXXXX) || exit 1
    trap 'rm -rf "$stage"' EXIT
    m_section '内核版本：实际安装 / 官方稳定版 / 已适配可安装'
    if [[ -x $M_BINARY/V2bX ]] && "$M_BINARY/V2bX" build-info > "$stage/installed.json" 2>/dev/null && jq -e '.schema==1' "$stage/installed.json" >/dev/null 2>&1; then
        jq -r '.modules|to_entries[]|"  已安装 \(.key)：\(.value.version)"' "$stage/installed.json"
    else
        m_line 37 "  已安装 V2bX：$(m_core_version "$M_BINARY/V2bX")；旧构建无法可靠报告完整依赖版本。"
        [[ ! -x $M_BINARY/V2bX ]] || "$M_BINARY/V2bX" version
    fi
    for name in xray sing-box hysteria2; do
        case $name in xray) repo=XTLS/Xray-core;; sing-box) repo=SagerNet/sing-box;; hysteria2) repo=HyNetworks/hysteria;; esac
        if m_fetch "https://api.github.com/repos/$repo/releases/latest" "$stage/upstream.json" &&
           latest=$(jq -er 'select(.draft==false and .prerelease==false)|.tag_name' "$stage/upstream.json"); then
            printf '  官方稳定版 %s：%s\n' "$name" "$latest"
        else printf '  官方稳定版 %s：查询失败（保留已安装版本）\n' "$name"; fi
    done
    if m_core_manifest "$stage"; then
        jq -r '"  已适配可安装：\(.tag)",(.cores|to_entries[]|"    \(.key)：\(.value.tag)（模块 \(.value.version)）")' "$stage/manifest.json"
    else m_line 33 '  当前无法取得已签名的适配发布。官方新版仅作为候选，不能直接替换内嵌内核。'; fi
)
