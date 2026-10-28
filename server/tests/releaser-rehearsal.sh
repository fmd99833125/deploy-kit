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

  cat > "$bin/scp" <<'EOF'
#!/bin/bash
# scp 桩：只记录被调用，验证「校验通过后确实 exec 了真的 scp」
echo "scp $*" >> "$STUB_LOG"
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
  local dir="$root/opt/learning/incoming"
  mkdir -p "$dir"
  # 前端产物：tar 里是 dist 的内容（index.html 在根）
  local tmp="$root/.dist"
  rm -rf "$tmp"; mkdir -p "$tmp/assets"
  echo "<html><script src=\"/assets/index-${sha}.js\"></script></html>" > "$tmp/index.html"
  echo "{\"id\":\"$sha\"}" > "$tmp/version.json"
  echo "asset-$sha" > "$tmp/assets/index-${sha}.js"
  tar -czf "$dir/${sha}.web-dist.tar.gz" -C "$tmp" .
  rm -rf "$tmp"
  # 后端镜像：假包 = gzip 文本，stub 从里面读 IMAGE_TAG
  printf 'IMAGE_TAG=xuexu-api:%s\n' "$sha" | gzip > "$dir/${sha}.api-image.tar.gz"
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
REQUIRED_KEYS="PROJECT_NAME REPO_DIR DEPLOY_DIR RELEASES_DIR ARTIFACT_DIR WEB_SUBDIR API_IMAGE APP_SERVICES WEB_SERVICES HEALTH_SERVICES KEEP_RELEASES"
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
section "T7 · 受限 SSH 入口（命令注入防护）"
# ===========================================================================
ROOT7="$SANDBOX_ROOT/t7"
make_server "$ROOT7"; make_stubs "$ROOT7"
: > "$ROOT7/state/images"; : > "$ROOT7/state/compose_ps"
printf 'api\trunning\nworker\trunning\ncaddy\trunning\n' > "$ROOT7/state/compose_ps"
cp "$SERVER_DIR/push-incoming.sh" "$ROOT7/kit/push-incoming.sh"
chmod +x "$ROOT7/kit/push-incoming.sh"
make_artifacts "$ROOT7" "1a2b3c4"

# PIN_ARGS：模拟授权行里写死的 --project <名>
#   真实安装后一定带（install-server.sh 写死）；没带 = 未绑定 = 一律拒。
#   本组测的是「这把钥匙绑 xuexu」这个形态。
PIN_ARGS="--project xuexu"
run_push() {
  local root="$1"; shift
  SSH_ORIGINAL_COMMAND="$1" \
    PATH="$root/bin:$PATH" \
    STUB_LOG="$root/state/calls.log" \
    STUB_STATE="$root/state" \
    KIT_DIR="$root/kit" \
    PROJECTS_DIR="$root/kit/projects.d" \
    LOCK_DIR="$root/state" \
    bash "$root/kit/push-incoming.sh" ${PIN_ARGS} > "$root/state/push.log" 2>&1
  echo $?
}

# 白名单内：apply 正常分发
RC=$(run_push "$ROOT7" "apply xuexu 1a2b3c4")
assert "白名单命令 apply 被接受（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 真的发布了" "grep -q '1a2b3c4' '$ROOT7/opt/learning/repo/deploy/web/index.html'"

# incoming-dir：告诉 CI 往哪推
RC=$(run_push "$ROOT7" "incoming-dir xuexu")
assert "incoming-dir 返回 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert "  · 打印了产物目录" "grep -q 'incoming' '$ROOT7/state/push.log'"

# 注入类：全部必须被拒
for evil in "rm -rf /" "apply xuexu; rm -rf /" "apply ../../etc abc1234" \
            "apply xuexu ZZZZZZZ" "apply xuexu ../../../../etc/passwd" \
            "cat /etc/shadow" "apply xuexu" "status ../../x" ""; do
  RC=$(run_push "$ROOT7" "$evil")
  if [ "$RC" != "0" ]; then
    ok "拒绝危险命令：${evil:-（空）}"
  else
    bad "危险命令被放行了：${evil:-（空）}"
  fi
done


# ── scp 上传路径校验 ───────────────────────────────────────────────────────
ARTDIR="$ROOT7/opt/learning/incoming"
RC=$(run_push "$ROOT7" "scp -t ${ARTDIR}/1a2b3c4.web-dist.tar.gz")
assert "scp 到标准产物路径被接受（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 确实 exec 了 scp" "grep -q 'scp -t' '$ROOT7/state/calls.log'"

for bad_path in \
  "scp -t ${ARTDIR}/1a2b3c4.evil.tar.gz" \
  "scp -t ${ARTDIR}/../../etc/passwd" \
  "scp -t /etc/passwd" \
  "scp -t ${ARTDIR}/nothex.web-dist.tar.gz" \
  "scp -f ${ARTDIR}/1a2b3c4.web-dist.tar.gz" \
  "scp ${ARTDIR}/1a2b3c4.web-dist.tar.gz" \
  "scp -t /opt/learning/repo/deploy/.env" \
  "rsync -a ${ARTDIR}/ x:/tmp/"; do
  RC=$(run_push "$ROOT7" "$bad_path")
  if [ "$RC" != "0" ]; then
    ok "拒绝非法上传：${bad_path}"
  else
    bad "非法上传被放行：${bad_path}"
  fi
done

# 未知项目
RC=$(run_push "$ROOT7" "apply nosuchproject abc1234")
assert_not "未知项目被拒绝（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 明确说未知项目" "grep -q '未知项目' '$ROOT7/state/push.log'"

# 被拒的命令绝不能碰到生产目录
assert "被拒的命令没有动 deploy/web" "grep -q '1a2b3c4' '$ROOT7/opt/learning/repo/deploy/web/index.html'"


# ===========================================================================
section "T8 · 服务器端安装脚本"
# ===========================================================================
ROOT8="$SANDBOX_ROOT/t8"
make_server "$ROOT8"; make_stubs "$ROOT8"
mkdir -p "$ROOT8/srcdir/projects.d"
cp "$SERVER_DIR/releaser.sh" "$SERVER_DIR/push-incoming.sh" "$SERVER_DIR/install-server.sh" "$ROOT8/srcdir/"
# 沙箱版配置（路径指向沙箱）
sed "s|^REPO_DIR=.*|REPO_DIR=$ROOT8/opt/learning/repo|; s|^DEPLOY_DIR=.*|DEPLOY_DIR=$ROOT8/opt/learning/repo/deploy|; s|^RELEASES_DIR=.*|RELEASES_DIR=$ROOT8/opt/learning/releases|; s|^ARTIFACT_DIR=.*|ARTIFACT_DIR=$ROOT8/opt/learning/incoming|" \
  "$REAL_CONFIGS/xuexu.env" > "$ROOT8/srcdir/projects.d/xuexu.env"

# 沙箱 HOME（authorized_keys 写这儿）
mkdir -p "$ROOT8/home"

run_install() {
  local root="$1"; shift
  KIT_DIR="$root/kit-installed" \
  REQUIRE_ROOT=0 \
  SSH_KEY_DIR="$root/home/.ssh" \
  bash "$root/srcdir/install-server.sh" "$@" > "$root/state/install.log" 2>&1
  echo $?
}

# dry-run：什么都不该落盘
RC=$(run_install "$ROOT8" --project xuexu --dry-run)
assert "dry-run 退出码为 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert_not "  · 没装任何文件" "[ -d '$ROOT8/kit-installed' ]"

# 真装
RC=$(run_install "$ROOT8" --project xuexu)
assert "正式安装退出码为 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · releaser.sh 装好了" "[ -x '$ROOT8/kit-installed/releaser.sh' ]"
assert     "  · push-incoming.sh 装好了" "[ -x '$ROOT8/kit-installed/push-incoming.sh' ]"
assert     "  · 项目配置装好了" "[ -f '$ROOT8/kit-installed/projects.d/xuexu.env' ]"
assert     "  · 产物目录建好了" "[ -d '$ROOT8/opt/learning/incoming' ]"
assert     "  · 版本目录建好了" "[ -d '$ROOT8/opt/learning/releases/web' ]"
assert     "  · 授权行带 command= 限制" "grep -q 'command=.*push-incoming.sh' '$ROOT8/home/.ssh/authorized_keys'"
assert     "  · 授权行带 restrict" "grep -q 'restrict' '$ROOT8/home/.ssh/authorized_keys'"
assert     "  · 授权行绑定了项目（这把钥匙只授权这一个项目）" "grep -q 'push-incoming.sh --project xuexu' '$ROOT8/home/.ssh/authorized_keys'"
assert     "  · 私钥已生成" "[ -f '$ROOT8/home/.ssh/deploy_ci_ed25519' ]"
assert     "  · 私钥权限 600" "[ \"\$(stat -c %a '$ROOT8/home/.ssh/deploy_ci_ed25519' 2>/dev/null || stat -f %Lp '$ROOT8/home/.ssh/deploy_ci_ed25519')\" = '600' ]"

# 幂等：再装一次，authorized_keys 不该出现两条
RC=$(run_install "$ROOT8" --project xuexu)
N=$(grep -c 'push-incoming.sh' "$ROOT8/home/.ssh/authorized_keys" 2>/dev/null || echo 0)
assert "重复安装幂等（授权行数 ${N}）" "[ '$N' = 1 ]"

# 未知项目必须被拒
RC=$(run_install "$ROOT8" --project nosuchproject)
assert_not "未知项目被拒（实际 ${RC}）" "[ '$RC' = 0 ]"

# ===========================================================================
section "T9 · 多项目接入与隔离"
# ===========================================================================
# 目标：新项目接入要「一条命令」，且两个项目**互不干涉**。
# 隔离维度：产物目录 / 版本目录 / 仓目录 / 锁文件 / 镜像名 / compose 项目名。
ROOT9="$SANDBOX_ROOT/t9"
make_server "$ROOT9"; make_stubs "$ROOT9"
: > "$ROOT9/state/images"; : > "$ROOT9/state/compose_ps"
printf 'api\trunning\nworker\trunning\ncaddy\trunning\n' > "$ROOT9/state/compose_ps"
cp "$SERVER_DIR/push-incoming.sh" "$ROOT9/kit/push-incoming.sh"
chmod +x "$ROOT9/kit/push-incoming.sh"
cp "$SERVER_DIR/new-project.sh" "$ROOT9/kit/new-project.sh"
chmod +x "$ROOT9/kit/new-project.sh"

run_new_project() {
  local root="$1"; shift
  bash "$root/kit/new-project.sh" "$@" > "$root/state/newproject.log" 2>&1
  echo $?
}

# ── ① dry-run 不落盘 ───────────────────────────────────────────────────────
RC=$(run_new_project "$ROOT9" --name kids --project-repo "$ROOT9/project-repo" --dry-run)
assert "new-project --dry-run 退出码为 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert_not "  · 没写注册表条目" "[ -f '$ROOT9/kit/projects.d/kids.env' ]"
assert_not "  · 没写 workflow" "[ -f '$ROOT9/project-repo/.github/workflows/deploy.yml' ]"

# ── ② 真生成 ─────────────────────────────────────────────────────────────
RC=$(run_new_project "$ROOT9" --name kids --project-repo "$ROOT9/project-repo" \
      --api-image kids-api --api-dockerfile deploy/Dockerfile.server \
      --health-services "api caddy" --app-services api \
      --deploy-root "$ROOT9/opt/kids")
assert "new-project 正式生成退出码为 0（实际 ${RC}）" "[ '$RC' = 0 ]"
assert     "  · 注册表条目生成了" "[ -f '$ROOT9/kit/projects.d/kids.env' ]"
assert     "  · workflow 生成了" "[ -f '$ROOT9/project-repo/.github/workflows/deploy.yml' ]"

# ── ③ 生成的注册表条目必须能被 releaser 吃下（所有必需键都在）──────────────
MISSING=""
for k in PROJECT_NAME REPO_DIR DEPLOY_DIR RELEASES_DIR ARTIFACT_DIR WEB_SUBDIR API_IMAGE; do
  grep -qE "^${k}=" "$ROOT9/kit/projects.d/kids.env" || MISSING="${MISSING} ${k}"
done
assert "注册表条目关键键齐全（缺：${MISSING:-无}）" "[ -z \"\$MISSING\" ]"

# ⚠️ 这份文件会被 . (source) 进来 —— 多词值不加引号会被解析成多条赋值，
#    第二个词会被当成命令执行（exit 127）。这里真 source 一次。
if ( set -a; . "$ROOT9/kit/projects.d/kids.env" ) 2>/dev/null; then
  ok "注册表条目能被正常 source"
else
  bad "注册表条目 source 失败（多半是值没加引号）"
fi
if ( . "$ROOT9/kit/projects.d/kids.env"; echo "$HEALTH_SERVICES" ) 2>/dev/null | grep -q 'api caddy'; then
  ok "  · HEALTH_SERVICES 是完整的 'api caddy'"
else
  bad "  · HEALTH_SERVICES 被截断了"
fi

# 注册表条目里的路径要指向 sandbox 而不是真服务器
assert "  · 产物目录指向沙箱" "grep -q 'ARTIFACT_DIR=$ROOT9/opt/kids/incoming' '$ROOT9/kit/projects.d/kids.env'"
assert "  · 版本目录指向沙箱" "grep -q 'RELEASES_DIR=$ROOT9/opt/kids/releases' '$ROOT9/kit/projects.d/kids.env'"

# ── ④ 生成的 workflow 必须是合法 YAML，且关键参数对 ───────────────────────
if command -v python3 >/dev/null 2>&1; then
  WF="$ROOT9/project-repo/.github/workflows/deploy.yml"
  if python3 -c "
import yaml,sys
d=yaml.safe_load(open('$WF'))
j=d['jobs']['deploy']
w=j['with']
assert w['project']=='kids', w
assert w['api_image']=='kids-api', w
assert w['api_dockerfile']=='deploy/Dockerfile.server', w
assert 'uses' in j and 'deploy-kit' in j['uses'], j
assert j['secrets']=='inherit'
" 2>/dev/null; then
    ok "生成的 workflow 是合法 YAML，参数都对"
  else
    bad "生成的 workflow YAML 有问题"
  fi
else
  printf '  \033[1;33m⚠️ \033[0m 没有 python3，跳过 workflow YAML 校验\n'
fi

# ── ④之二 包管理器：默认 npm、可指定 pnpm、非法值被拒 ────────────────────
assert "  · 默认包管理器是 npm" "grep -q 'package_manager: npm' '$ROOT9/project-repo/.github/workflows/deploy.yml'"
assert "  · 引用的是 v2（v1 没有 package_manager 输入，用了会报 Invalid input）" \
  "grep -q 'deploy-kit/.github/workflows/deploy.yml@v2' '$ROOT9/project-repo/.github/workflows/deploy.yml'"
RC=$(run_new_project "$ROOT9" --name pnpmproj --project-repo "$ROOT9/project-repo3" --package-manager pnpm)
assert "  · --package-manager pnpm 能生成（实际 ${RC}）" "[ '$RC' = 0 ]"
assert "  · 生成的 workflow 里是 pnpm" "grep -q 'package_manager: pnpm' '$ROOT9/project-repo3/.github/workflows/deploy.yml'"
RC=$(run_new_project "$ROOT9" --name badpm --project-repo "$ROOT9/project-repo4" --package-manager yarn2)
assert_not "  · 非法包管理器被拒（实际 ${RC}）" "[ '$RC' = 0 ]"

# ── ④之三 reusable workflow 本身：合法 + 有 package_manager 输入 ──────────
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "
import yaml
d=yaml.safe_load(open('.github/workflows/deploy.yml'))
inp=d[True]['workflow_call']['inputs']
assert 'package_manager' in inp, list(inp)
assert inp['package_manager']['default']=='npm', inp['package_manager']
"; then
    ok "reusable workflow 合法，且有 package_manager 输入（默认 npm）"
  else
    bad "reusable workflow 缺 package_manager 输入"
  fi
fi

# ── ④之四 workflow 静态体检：重复键 / step id / input 引用 ──────────────────
# 2026-10-28 踩坑：同一个 step 写了两条 if，GitHub 报 "'if' is already defined"，
# 整个 workflow 解析失败 —— 而 Python 的 yaml.safe_load 对【重复键是静默覆盖】，
# 本地校验全绿，只有真跑 workflow 才炸。这里用严格 loader 在彩排里就拦下来。
if command -v python3 >/dev/null 2>&1; then
  if python3 - "$PWD/.github/workflows/deploy.yml" "$ROOT9/project-repo/.github/workflows/deploy.yml" <<'PYEOF'
import yaml, re, sys

class Strict(yaml.SafeLoader):
    pass

def no_dup(loader, node, deep=False):
    mapping = {}
    for k, v in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in mapping:
            raise AssertionError("重复键 '%s'（第 %d 行）" % (key, k.start_mark.line + 1))
        mapping[key] = loader.construct_object(v, deep=deep)
    return mapping

Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dup)

for path in sys.argv[1:]:
    d = yaml.load(open(path, encoding='utf-8'), Loader=Strict)
    on = d[True] if True in d else d['on']
    declared = set((on.get('workflow_call') or {}).get('inputs', {}))
    ids, refs, used = set(), set(), set()
    for job in d['jobs'].values():
        for s in job.get('steps', []):
            if 'id' in s:
                ids.add(s['id'])
            blob = yaml.dump(s, allow_unicode=True)
            refs |= set(re.findall(r'steps\.([A-Za-z0-9_-]+)\.', blob))
            for k in ('if', 'run', 'env'):
                v = s.get(k)
                if isinstance(v, str):
                    used |= set(re.findall(r'inputs\.([A-Za-z0-9_]+)', v))
            for v in (s.get('with') or {}).values():
                if isinstance(v, str):
                    used |= set(re.findall(r'inputs\.([A-Za-z0-9_]+)', v))
    missing_steps = refs - ids
    missing_inputs = used - declared
    assert not missing_steps, "%s 引用了不存在的 step id: %s" % (path, missing_steps)
    assert not missing_inputs, "%s 引用了未声明的 input: %s" % (path, missing_inputs)
print("OK")
PYEOF
  then
    ok "workflow 静态体检通过（无重复键 / step id 与 input 引用都对得上）"
  else
    bad "workflow 静态体检不通过（重复键？引用了不存在的 step id / input？）"
  fi
fi

# ── ④之五 scp 必须走老协议（-O）─────────────────────────────────────────
# ⚠️ 2026-10-28 踩坑：OpenSSH 9.0+ 的 scp 默认改走 SFTP（发的是 subsystem 请求），
#    而 authorized_keys 里的 command="..." 会**顶掉 subsystem 请求** →
#    受限入口脚本去接 SFTP 的活 → 客户端看到 "scp: Connection closed"。
#    必须 -O 强制走老协议（远程命令 = scp -t <path>），受限入口才认得。
assert "  · 上传用的 scp 带 -O（否则 OpenSSH 9.0+ 走 SFTP，会被 command= 顶掉）" \
  "grep -q 'scp -O' .github/workflows/deploy.yml"
assert "  · 受限入口认的是老协议（exec scp -t）" \
  "grep -q 'exec scp -t' server/push-incoming.sh"

# ── ⑤ 拒绝覆盖 / 拒绝非法名 ──────────────────────────────────────────────
RC=$(run_new_project "$ROOT9" --name kids --project-repo "$ROOT9/project-repo")
assert_not "重复生成被拒（无 --force，实际 ${RC}）" "[ '$RC' = 0 ]"
RC=$(run_new_project "$ROOT9" --name "Bad_Name" --project-repo "$ROOT9/project-repo")
assert_not "非法项目名被拒（实际 ${RC}）" "[ '$RC' = 0 ]"
RC=$(run_new_project "$ROOT9" --name kids --project-repo "$ROOT9/project-repo" \
      --api-image kids-api --api-dockerfile deploy/Dockerfile.server \
      --health-services "api caddy" --app-services api \
      --deploy-root "$ROOT9/opt/kids" --force)
assert "--force 能覆盖（实际 ${RC}）" "[ '$RC' = 0 ]"
# ⚠️ --force 重生成必须带全套参数：漏一个（比如 --deploy-root）
#    就会把注册表条目覆写成默认路径 → 服务器上指向错目录 → 发布时找不到产物。
assert "  · 重生成后路径没漂移" "grep -q 'ARTIFACT_DIR=$ROOT9/opt/kids/incoming' '$ROOT9/kit/projects.d/kids.env'"

# ── ⑥ 纯前端项目（没有后端镜像）也要能接 ─────────────────────────────────
RC=$(run_new_project "$ROOT9" --name static --project-repo "$ROOT9/project-repo2" --no-api)
assert "纯前端项目生成成功（实际 ${RC}）" "[ '$RC' = 0 ]"
assert "  · 注册表条目里 API_IMAGE 显式留空" "grep -qE '^API_IMAGE=$' '$ROOT9/kit/projects.d/static.env'"
assert_not "  · workflow 里没有 api_image" "grep -q 'api_image' '$ROOT9/project-repo2/.github/workflows/deploy.yml'"

# 纯前端项目发布：只换前端，不碰镜像
mkdir -p "$ROOT9/opt/static/repo/deploy/web" "$ROOT9/opt/static/incoming" "$ROOT9/opt/static/releases/web"
cat > "$ROOT9/kit/projects.d/static.env" <<EOF
PROJECT_NAME=static
REPO_DIR=$ROOT9/opt/static/repo
DEPLOY_DIR=$ROOT9/opt/static/repo/deploy
RELEASES_DIR=$ROOT9/opt/static/releases
ARTIFACT_DIR=$ROOT9/opt/static/incoming
WEB_SUBDIR=web
API_IMAGE=
APP_SERVICES=
WEB_SERVICES=caddy
HEALTH_SERVICES=caddy
KEEP_RELEASES=3
EOF
echo '<html>static</html>' > "$ROOT9/opt/static/repo/deploy/web/index.html"
tar -czf "$ROOT9/opt/static/incoming/aaa1111.web-dist.tar.gz" -C "$ROOT9/opt/static/repo/deploy/web" .
RC=$(run_releaser "$ROOT9" has static aaa1111)
assert "纯前端项目 has 通过（实际 ${RC}）" "[ '$RC' = 0 ]"
RC=$(run_releaser "$ROOT9" apply static aaa1111)
assert "纯前端项目 apply 通过（实际 ${RC}）" "[ '$RC' = 0 ]"
assert_not "  · 没有载入镜像" "grep -q 'docker load' '$ROOT9/state/calls.log'"

# ── ⑦ 两个项目互不干涉 ───────────────────────────────────────────────────
# 给 kids 补齐沙箱目录，发布一次
mkdir -p "$ROOT9/opt/kids/repo/deploy/web" "$ROOT9/opt/kids/releases/web" "$ROOT9/opt/kids/incoming"
echo '<html>kids</html>' > "$ROOT9/opt/kids/repo/deploy/web/index.html"
tar -czf "$ROOT9/opt/kids/incoming/bbb2222.web-dist.tar.gz" -C "$ROOT9/opt/kids/repo/deploy/web" .
printf 'IMAGE_TAG=kids-api:bbb2222\n' | gzip > "$ROOT9/opt/kids/incoming/bbb2222.api-image.tar.gz"
: > "$ROOT9/state/calls.log"

RC=$(run_releaser "$ROOT9" apply kids bbb2222)
assert "kids 发布成功（实际 ${RC}）" "[ '$RC' = 0 ]"

assert "  · kids 用的是自己的镜像 tag" "grep -q 'kids-api:bbb2222' '$ROOT9/state/calls.log'"
assert_not "  · 没碰 xuexu 的镜像" "grep -q 'xuexu-api' '$ROOT9/state/calls.log'"
assert "  · kids 的前端目录独立" "[ -d '$ROOT9/opt/kids/repo/deploy/web' ]"
assert "  · kids 的前端内容是它自己的" "grep -q 'kids' '$ROOT9/opt/kids/repo/deploy/web/index.html'"
assert "  · xuexu 的目录没被动（还是原来的内容）" "grep -q 'OLD000' '$ROOT9/opt/learning/repo/deploy/web/index.html'"
assert_not "  · xuexu 没多出 web.old（没被换过目录）" "[ -d '$ROOT9/opt/learning/repo/deploy/web.old' ]"

# 版本目录互不干扰
assert "  · kids 的版本进自己的 releases" "[ -d '$ROOT9/opt/kids/releases/web/bbb2222' ]"
assert_not "  · xuexu 的 releases 里没有 kids 的版本" "[ -d '$ROOT9/opt/learning/releases/web/bbb2222' ]"

# 锁文件按项目分
assert "  · 锁文件按项目名分开" "[ -f '$ROOT9/state/deploy-kids.lock' ]"

# ── ⑧ 跨项目投毒必须被拒 ─────────────────────────────────────────────────
# kids 的 CI 密钥不能把产物推进 xuexu 的目录
RC=$(run_push "$ROOT9" "scp -t $ROOT9/opt/kids/incoming/ccc3333.web-dist.tar.gz")
assert_not "把产物推进别的项目目录被拒（实际 ${RC}）" "[ '$RC' = 0 ]"
# 未注册的项目
RC=$(run_push "$ROOT9" "apply nosuchproject 1a2b3c4")
assert_not "发布未注册项目被拒（实际 ${RC}）" "[ '$RC' = 0 ]"

# ── ⑨ 绑定模式：钥匙只授权一个项目 ───────────────────────────────────────
# 这才是真实安装后的形态：授权行写死 command="... push-incoming.sh --project kids"
PIN_ARGS="--project kids"

RC=$(run_push "$ROOT9" "scp -t $ROOT9/opt/kids/incoming/ddd4444.web-dist.tar.gz")
assert "绑定模式下推进自己项目的目录被接受（实际 ${RC}）" "[ '$RC' = 0 ]"

RC=$(run_push "$ROOT9" "scp -t $ROOT9/opt/learning/incoming/eee5555.web-dist.tar.gz")
assert_not "绑定模式下推进别的项目目录被拒（实际 ${RC}）" "[ '$RC' = 0 ]"
assert "  · 报错说清了只授权了 kids" "grep -q '只授权' '$ROOT9/state/push.log'"

RC=$(run_push "$ROOT9" "apply xuexu 1a2b3c4")
assert_not "绑定模式下发布别的项目被拒（实际 ${RC}）" "[ '$RC' = 0 ]"

RC=$(run_push "$ROOT9" "apply kids bbb2222")
assert "绑定模式下发布自己项目被接受（实际 ${RC}）" "[ '$RC' = 0 ]"

RC=$(run_push "$ROOT9" "incoming-dir xuexu")
assert_not "绑定模式下问别的项目的产物目录被拒（实际 ${RC}）" "[ '$RC' = 0 ]"

# 未绑定 → 一律拒（没有逃生口）
PIN_ARGS=""
RC=$(run_push "$ROOT9" "scp -t $ROOT9/opt/kids/incoming/fff6666.web-dist.tar.gz")
assert_not "未绑定项目时拒绝上传（实际 ${RC}）" "[ '$RC' = 0 ]"
RC=$(run_push "$ROOT9" "apply kids bbb2222")
assert_not "未绑定项目时拒绝发布（实际 ${RC}）" "[ '$RC' = 0 ]"
RC=$(run_push "$ROOT9" "status kids")
assert_not "未绑定项目时拒绝查状态（实际 ${RC}）" "[ '$RC' = 0 ]"

# ===========================================================================
printf '\n\033[1m═══ 结果：%d 通过 / %d 失败 ═══\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
