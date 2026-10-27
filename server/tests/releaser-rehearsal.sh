#!/usr/bin/env bash
# ============================================================================
# deploy-kit · 发布器本地彩排
#
# 用法：bash deploy-kit/server/tests/releaser-rehearsal.sh
# 退出码：0 = 全绿；非 0 = 有用例失败
#
# 为什么要有这个：releaser.sh 要在**生产服务器**上换目录、换镜像、重建容器。
# 写完只做 `bash -n` 语法检查等于不知道会不会炸 —— 2026-10-26 在 xuexu 迁移上
# 已经吃过一次亏（彩排揪出 5 个「上生产必炸」Bug）。所以这里把整条链路
# 在临时目录里**真跑一遍**。
#
# 手法：假服务器目录 + 假 docker + 假 flock（macOS 没有 flock），
#       其余（tar/gzip/git/目录操作）全是真的。
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASER="$SERVER_DIR/releaser.sh"
REAL_CONFIGS="$SERVER_DIR/projects.d"

TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
SANDBOX_ROOT="$(mktemp -d "$TMP_BASE/deploy-kit-rehearsal.XXXXXX")"
KEEP_SANDBOX="${KEEP_SANDBOX:-0}"

PASS=0
FAIL=0
section() { printf '\n\033[1;36m▌ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m❌\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
assert()      { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
assert_not()  { if eval "$2"; then bad "$1"; else ok "$1"; fi; }

cleanup() {
  if [ "$KEEP_SANDBOX" = "1" ]; then
    printf '\n  沙箱保留：%s\n' "$SANDBOX_ROOT"
  else
    rm -rf "$SANDBOX_ROOT"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 假服务器：目录结构 + 旧版本 web
# ---------------------------------------------------------------------------
make_server() {
  local root="$1"
  mkdir -p "$root/opt/learning/repo/deploy/web/assets" \
           "$root/opt/learning/releases/web" \
           "$root/opt/learning/incoming" \
           "$root/kit/projects.d" \
           "$root/state"

  echo '<html><script src="/assets/index-OLD000.js"></script></html>' \
    > "$root/opt/learning/repo/deploy/web/index.html"
  echo '{"id":"old000"}' > "$root/opt/learning/repo/deploy/web/version.json"
  echo 'old-asset' > "$root/opt/learning/repo/deploy/web/assets/index-OLD000.js"

  echo 'name: learning' > "$root/opt/learning/repo/deploy/docker-compose.yml"
  echo 'POSTGRES_PASSWORD=pw' > "$root/opt/learning/repo/deploy/.env"
  chmod 600 "$root/opt/learning/repo/deploy/.env"

  # 沙箱版项目配置（路径指向沙箱）
  cat > "$root/kit/projects.d/xuexu.env" <<EOF
PROJECT_NAME=xuexu
REPO_DIR=$root/opt/learning/repo
DEPLOY_DIR=$root/opt/learning/repo/deploy
RELEASES_DIR=$root/opt/learning/releases
ARTIFACT_DIR=$root/opt/learning/incoming
WEB_SUBDIR=web
API_IMAGE=xuexu-api
HEALTH_SERVICES="api worker caddy"
KEEP_RELEASES=3
EOF

  # 复制真实脚本
  cp "$RELEASER" "$root/kit/releaser.sh"
  chmod +x "$root/kit/releaser.sh"
}

# ---------------------------------------------------------------------------
# 假件：docker（记录调用 + 模拟镜像状态）/ flock（macOS 没有）
# ---------------------------------------------------------------------------
make_stubs() {
  local root="$1"
  local bin="$root/bin"
  mkdir -p "$bin"

  cat > "$bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
case "$1" in
  load)
    # 假镜像包 = gzip 过的纯文本，内容形如 IMAGE_TAG=xuexu-api:abc123
    tag="$(cat | grep -o 'IMAGE_TAG=[^ ]*' | head -1 | cut -d= -f2)"
    [ -n "$tag" ] && echo "$tag" >> "$STUB_STATE/images"
    exit 0
    ;;
  tag)
    src="$2"; dst="$3"
    echo "$dst" >> "$STUB_STATE/images"
    exit 0
    ;;
  images)
    if [ -f "$STUB_STATE/images" ]; then cat "$STUB_STATE/images"; fi
    exit 0
    ;;
  image)
    # docker image inspect IMG
    img="$3"
    if [ -f "$STUB_STATE/images" ] && grep -qx "$img" "$STUB_STATE/images"; then exit 0; fi
    exit 1
    ;;
  compose)
    case "$2" in
      ps)
        if [ -f "$STUB_STATE/compose_ps" ]; then cat "$STUB_STATE/compose_ps"; fi
        exit 0
        ;;
      up)
        echo "compose up ${*}" >> "$STUB_STATE/compose_calls"
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
EOF

  cat > "$bin/flock" <<'EOF'
#!/bin/bash
# macOS 没有 flock；彩排里串行执行，直接当成功
exit 0
EOF

  chmod +x "$bin"/*
}

# ---------------------------------------------------------------------------
# 造一份「CI 传来的产物」
# ---------------------------------------------------------------------------
make_artifacts() {
  local root="$1" sha="$2"
  local dir="$root/opt/learning/incoming/$sha"
  mkdir -p "$dir"
  # 前端产物：tar 里是 dist 的内容（index.html 在根）
  local tmp="$root/.dist"
  rm -rf "$tmp"; mkdir -p "$tmp/assets"
  echo "<html><script src=\"/assets/index-${sha}.js\"></script></html>" > "$tmp/index.html"
  echo "{\"id\":\"$sha\"}" > "$tmp/version.json"
  echo "asset-$sha" > "$tmp/assets/index-${sha}.js"
  tar -czf "$dir/web-dist.tar.gz" -C "$tmp" .
  rm -rf "$tmp"
  # 后端镜像：假包 = gzip 文本，stub 从里面读 IMAGE_TAG
  printf 'IMAGE_TAG=xuexu-api:%s\n' "$sha" | gzip > "$dir/api-image.tar.gz"
}

run_releaser() {
  local root="$1"; shift
  PATH="$root/bin:$PATH" \
  STUB_LOG="$root/state/calls.log" \
  STUB_STATE="$root/state" \
  KIT_DIR="$root/kit" \
  PROJECTS_DIR="$root/kit/projects.d" \
  LOCK_DIR="$root/state" \
  bash "$root/kit/releaser.sh" "$@" > "$root/state/out.log" 2>&1
  echo $?
}

# ===========================================================================
section "T0 · 静态守卫"
# ===========================================================================
# 变量名后紧跟非 ASCII 字符 → bash 把 UTF-8 首字节吞进变量名 → unbound variable
SCAN_N="SKIP"
if command -v python3 >/dev/null 2>&1; then
  SCAN_N="$(python3 - <<'PY'
import re, pathlib
pat = re.compile(r'\$\{?[A-Za-z_][A-Za-z0-9_]*\}?')
n = 0
for f in sorted(pathlib.Path('.').rglob('*.sh')):
    for i, line in enumerate(f.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
        if line.lstrip().startswith('#'):
            continue
        for m in pat.finditer(line):
            tail = line[m.end():m.end() + 1]
            if tail and ord(tail[0]) > 127 and line[m.end() - 1] != '}':
                print(f"{f}:{i}")
                n += 1
print(f"HITS={n}")
PY
)"
  SCAN_N="${SCAN_N##*HITS=}"
fi
if [ "$SCAN_N" = "SKIP" ]; then
  printf '  \033[1;33m⚠️ \033[0m 没有 python3，跳过多字节变量名扫描\n'
elif [ "$SCAN_N" = "0" ]; then
  ok "无「变量名后紧跟非 ASCII」写法（0 命中）"
else
  bad "发现 ${SCAN_N} 处多字节变量名隐患"
fi

# 真实项目配置必须包含 releaser.sh 用到的全部键
REQUIRED_KEYS="PROJECT_NAME REPO_DIR DEPLOY_DIR RELEASES_DIR ARTIFACT_DIR WEB_SUBDIR API_IMAGE HEALTH_SERVICES KEEP_RELEASES"
MISSING=""
for k in $REQUIRED_KEYS; do
  grep -qE "^${k}=" "$REAL_CONFIGS/xuexu.env" 2>/dev/null || MISSING="$MISSING $k"
done
if [ -z "$MISSING" ]; then
  ok "真实配置 xuexu.env 含全部必需键"
else
  bad "xuexu.env 缺键：${MISSING}"
fi

# 真实配置的路径必须在 /opt 下且互相自洽（DEPLOY/RELEASES/ARTIFACT 都在 REPO 或同级）
if grep -qE '^REPO_DIR=/opt/' "$REAL_CONFIGS/xuexu.env" \
   && grep -qE '^DEPLOY_DIR=/opt/' "$REAL_CONFIGS/xuexu.env" \
   && grep -qE '^ARTIFACT_DIR=/opt/' "$REAL_CONFIGS/xuexu.env"; then
  ok "真实配置的路径都指向 /opt（生产位置）"
else
  bad "真实配置的路径不像生产位置"
fi

# ===========================================================================
section "T1 · 正常发布"
# ===========================================================================
ROOT1="$SANDBOX_ROOT/t1"
make_server "$ROOT1"; make_stubs "$ROOT1"
: > "$ROOT1/state/images"; : > "$ROOT1/state/compose_ps"; : > "$ROOT1/state/compose_calls"
printf 'api\trunning\nworker\trunning\ncaddy\trunning\n' > "$ROOT1/state/compose_ps"
make_artifacts "$ROOT1" "abc1234"

RC=$(run_releaser "$ROOT1" apply xuexu abc1234)
assert "退出码为 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert "新版本进了 deploy/web" "[ -f '$ROOT1/opt/learning/repo/deploy/web/index.html' ] && grep -q 'abc1234' '$ROOT1/opt/learning/repo/deploy/web/index.html'"
assert "旧版本留作回滚保险（web.old）" "[ -d '$ROOT1/opt/learning/repo/deploy/web.old' ] && grep -q 'OLD000' '$ROOT1/opt/learning/repo/deploy/web.old/index.html'"
assert "版本记进状态文件" "[ \"\$(cat '$ROOT1/opt/learning/releases/.current')\" = 'abc1234' ]"
assert "镜像被打上固定 tag current" "grep -qx 'xuexu-api:current' '$ROOT1/state/images'"
assert "releases 里留了这份版本" "[ -f '$ROOT1/opt/learning/releases/web/abc1234/index.html' ]"
assert "重建了 api/worker" "grep -q 'compose up' '$ROOT1/state/compose_calls'"
assert "重建了 caddy" "grep -q 'force-recreate caddy' '$ROOT1/state/compose_calls'"
assert "web 目录换过 inode（bind mount 才会重新解析）" "[ \"\$(stat -c %i '$ROOT1/opt/learning/repo/deploy/web' 2>/dev/null || stat -f %i '$ROOT1/opt/learning/repo/deploy/web')\" != \"\$(stat -c %i '$ROOT1/opt/learning/repo/deploy/web.old' 2>/dev/null || stat -f %i '$ROOT1/opt/learning/repo/deploy/web.old')\" ]"

# ===========================================================================
section "T2 · 产物缺失 → 明确失败，不半途动生产"
# ===========================================================================
ROOT2="$SANDBOX_ROOT/t2"
make_server "$ROOT2"; make_stubs "$ROOT2"
: > "$ROOT2/state/images"; printf 'api\trunning\nworker\trunning\ncaddy\trunning\n' > "$ROOT2/state/compose_ps"
RC=$(run_releaser "$ROOT2" apply xuexu deadbee)
assert_not "退出码非 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 明确指出缺产物" "grep -q '缺前端产物' '$ROOT2/state/out.log'"
assert     "  · 没动 web 目录" "grep -q 'OLD000' '$ROOT2/opt/learning/repo/deploy/web/index.html'"
assert     "  · 没建 releases" "[ ! -d '$ROOT2/opt/learning/releases/web/deadbee' ]"

# ===========================================================================
section "T3 · 健康检查失败 → 自动回滚"
# ===========================================================================
ROOT3="$SANDBOX_ROOT/t3"
make_server "$ROOT3"; make_stubs "$ROOT3"
: > "$ROOT3/state/images"; : > "$ROOT3/state/compose_calls"
make_artifacts "$ROOT3" "aaa1111"
printf 'api\trunning\nworker\trunning\ncaddy\trunning\n' > "$ROOT3/state/compose_ps"
RC=$(run_releaser "$ROOT3" apply xuexu aaa1111)
assert "先成功发布一版（实际 ${RC}）" "[ '$RC' = 0 ]"

# 再发一版，但把 api 弄成 exited → 应回滚
make_artifacts "$ROOT3" "bbb2222"
printf 'api\texited\nworker\trunning\ncaddy\trunning\n' > "$ROOT3/state/compose_ps"
RC=$(run_releaser "$ROOT3" apply xuexu bbb2222)
assert_not "健康检查失败时退出码非 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 写了回滚日志" "grep -q '自动回滚' '$ROOT3/state/out.log'"
assert     "  · web 换回旧版本" "grep -q 'aaa1111' '$ROOT3/opt/learning/repo/deploy/web/index.html'"
assert     "  · 状态文件回退" "[ \"\$(cat '$ROOT3/opt/learning/releases/.current')\" = 'aaa1111' ]"

# ===========================================================================
section "T4 · has / status 子命令"
# ===========================================================================
ROOT4="$SANDBOX_ROOT/t4"
make_server "$ROOT4"; make_stubs "$ROOT4"
make_artifacts "$ROOT4" "ccc3333"
RC=$(run_releaser "$ROOT4" has xuexu ccc3333)
assert "has：产物齐了返回 0（实际 ${RC}）" "[ '$RC' = 0 ]"
RC=$(run_releaser "$ROOT4" has xuexu nnn9999)
assert_not "has：产物没齐返回非 0（实际 ${RC}）" "[ '$RC' = 0 ]"
RC=$(run_releaser "$ROOT4" status xuexu)
assert "status：退出码为 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 打印了当前版本" "grep -q '当前版本' '$ROOT4/state/out.log'"
RC=$(run_releaser "$ROOT4" status nosuchproject)
assert_not "status：未知项目返回非 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 明确说未知项目" "grep -q '未知项目' '$ROOT4/state/out.log'"

# ===========================================================================
section "T5 · 保留策略：只留最近 KEEP_RELEASES 个版本"
# ===========================================================================
ROOT5="$SANDBOX_ROOT/t5"
make_server "$ROOT5"; make_stubs "$ROOT5"
: > "$ROOT5/state/images"; printf 'api\trunning\nworker\trunning\ncaddy\trunning\n' > "$ROOT5/state/compose_ps"
for sha in s001 s002 s003 s004 s005; do
  make_artifacts "$ROOT5" "$sha"
  run_releaser "$ROOT5" apply xuexu "$sha" > /dev/null
done
N="$(ls -1d "$ROOT5"/opt/learning/releases/web/*/ 2>/dev/null | wc -l | tr -d ' ')"
assert "只保留 3 个版本（实际 ${N}）" "[ '$N' = 3 ]"
assert "最新版本还在" "[ -d '$ROOT5/opt/learning/releases/web/s005' ]"
assert "最老版本已清掉" "[ ! -d '$ROOT5/opt/learning/releases/web/s001' ]"

# ===========================================================================
section "T6 · 手动回滚"
# ===========================================================================
ROOT6="$SANDBOX_ROOT/t6"
make_server "$ROOT6"; make_stubs "$ROOT6"
: > "$ROOT6/state/images"; printf 'api\trunning\nworker\trunning\ncaddy\trunning\n' > "$ROOT6/state/compose_ps"
make_artifacts "$ROOT6" "v111111"
run_releaser "$ROOT6" apply xuexu v111111 > /dev/null
make_artifacts "$ROOT6" "v222222"
run_releaser "$ROOT6" apply xuexu v222222 > /dev/null
RC=$(run_releaser "$ROOT6" rollback xuexu)
assert "回滚退出码为 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · web 换回上一版" "grep -q 'v111111' '$ROOT6/opt/learning/repo/deploy/web/index.html'"
assert     "  · 镜像 tag 换回" "grep -qx 'xuexu-api:current' '$ROOT6/state/images'"

# ===========================================================================
printf '\n\033[1m═══ 结果：%d 通过 / %d 失败 ═══\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
