#!/usr/bin/env bash
# ============================================================================
# deploy-kit · 服务器端安装
#
# 用法（在服务器上，以 root 身份）：
#   bash install-server.sh --project xuexu [--ci-pubkey <文件>] [--dry-run]
#
# 做四件事：
#   1. 把 releaser.sh / push-incoming.sh / projects.d 装到 /opt/deploy-kit
#   2. 按项目配置建好 incoming / releases 目录
#   3. 给 CI 准备一把**只能用 push-incoming.sh** 的 SSH 密钥
#      （密钥放在服务器的 authorized_keys 里，带 command= 限制）
#   4. 打印要粘进 GitHub Secrets 的私钥 + 验收命令
#
# --ci-pubkey <文件>：用你已有的公钥；不给就现场生成一对
# --dry-run：只打印要做什么，不落盘
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="${KIT_DIR:-/opt/deploy-kit}"
PROJECT=""
CI_PUBKEY=""
DRY=0

log()  { printf '[install] %s\n' "$*"; }
die()  { printf '[install] ❌ %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project)    PROJECT="${2:-}"; shift 2 ;;
    --ci-pubkey)  CI_PUBKEY="${2:-}"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *)            die "未知参数：$1" ;;
  esac
done

[ -n "$PROJECT" ] || die "必须给 --project <项目名>"
REQUIRE_ROOT="${REQUIRE_ROOT:-1}"
if [ "$REQUIRE_ROOT" = "1" ] && [ "$(id -u)" != "0" ]; then
  die "需要 root（服务器上用 sudo -i 或 sudo bash）"
fi

SRC_PROJECTS="$SCRIPT_DIR/projects.d"
[ -d "$SRC_PROJECTS" ] || die "找不到 $SRC_PROJECTS —— 脚本要从 deploy-kit/server/ 目录跑"

CFG="$SRC_PROJECTS/${PROJECT}.env"
[ -f "$CFG" ] || die "未知项目：${PROJECT}（找不到 ${CFG}）"

# 读配置
# shellcheck disable=SC1090
. "$CFG"
: "${REPO_DIR:?配置缺 REPO_DIR}"
: "${ARTIFACT_DIR:?配置缺 ARTIFACT_DIR}"
: "${RELEASES_DIR:?配置缺 RELEASES_DIR}"

log "项目      : ${PROJECT}"
log "产物目录  : ${ARTIFACT_DIR}"
log "版本目录  : ${RELEASES_DIR}"

if [ "$DRY" = "1" ]; then
  log "—— dry-run：以下操作不会真的执行 ——"
  log "  安装    : ${KIT_DIR}/{releaser.sh,push-incoming.sh,projects.d/}"
  log "  建目录  : ${ARTIFACT_DIR} ${RELEASES_DIR}"
  log "  授权    : /root/.ssh/authorized_keys 加一条 command= 限制"
  exit 0
fi

# ── 1. 装文件 ──────────────────────────────────────────────────────────────
log "安装到 ${KIT_DIR}"
install -d -m 755 "$KIT_DIR" "$KIT_DIR/projects.d"
install -m 755 "$SCRIPT_DIR/releaser.sh"      "$KIT_DIR/releaser.sh"
install -m 755 "$SCRIPT_DIR/push-incoming.sh" "$KIT_DIR/push-incoming.sh"
install -m 644 "$SRC_PROJECTS/${PROJECT}.env" "$KIT_DIR/projects.d/${PROJECT}.env"

# ── 2. 建目录 ──────────────────────────────────────────────────────────────
log "建产物与版本目录"
install -d -m 755 "$ARTIFACT_DIR" "$RELEASES_DIR"
install -d -m 755 "$RELEASES_DIR/web"

# ── 3. CI 密钥 ─────────────────────────────────────────────────────────────
# SSH 授权目录：显式取 root 的家目录 —— sudo 默认可能保留原用户的 HOME，
# 直接用 $HOME 会把公钥写进别人的 ~/.ssh。
ROOT_HOME="$(getent passwd 0 2>/dev/null | cut -d: -f6 || true)"
[ -n "$ROOT_HOME" ] || ROOT_HOME="/root"
KEYDIR="${SSH_KEY_DIR:-$ROOT_HOME/.ssh}"
install -d -m 700 "$KEYDIR"
touch "$KEYDIR/authorized_keys"
chmod 600 "$KEYDIR/authorized_keys"

# 授权行的前缀（含项目名）—— 后面两处比对都用它
AUTH_PREFIX="command=\"${KIT_DIR}/push-incoming.sh --project ${PROJECT}\",restrict "

if [ -n "$CI_PUBKEY" ]; then
  [ -f "$CI_PUBKEY" ] || die "公钥文件不存在：${CI_PUBKEY}"
  PUBKEY="$(cat "$CI_PUBKEY")"
  PRIVATE_HINT="（用你自己已有的私钥，不要贴到聊天里）"
else
  # ⚠️ 钥匙必须【按项目分】，不能共用：
  #    ① 同一把公钥不能当两个项目的 deploy key；
  #    ② OpenSSH 只认 authorized_keys 里【第一条】匹配公钥的授权行 →
  #       两个项目共用一把钥匙 = 第二个项目的授权行永远不生效，
  #       而脚本还会「看着成功」地退出 0（静默失效，最难查的一类）。
  #    迁移友好：如果这台机器上已经有【本项目】的授权行，就沿用那把钥匙 ——
  #    否则老项目的 GitHub Secret 跟着要改（等于逼人重配一遍 CI）。
  KEYFILE=""
  for cand in "$KEYDIR"/deploy_ci_*.pub "$KEYDIR"/deploy_ci.pub; do
    [ -f "$cand" ] || continue
    cand_pub="$(cat "$cand")"
    if grep -qF "${AUTH_PREFIX}${cand_pub}" "$KEYDIR/authorized_keys" 2>/dev/null; then
      KEYFILE="${cand%.pub}"
      log "沿用已授权给本项目的既有密钥：${KEYFILE}"
      break
    fi
  done
  if [ -z "$KEYFILE" ]; then
    KEYFILE="$KEYDIR/deploy_ci_${PROJECT}_ed25519"
    if [ ! -f "$KEYFILE" ]; then
      log "生成 CI 专用密钥对（项目 ${PROJECT}）"
      ssh-keygen -t ed25519 -N '' -C "github-actions-${PROJECT}" -f "$KEYFILE"
    else
      log "复用已存在的密钥：${KEYFILE}"
    fi
  fi
  chmod 600 "$KEYFILE"
  PUBKEY="$(cat "${KEYFILE}.pub")"
  PRIVATE_HINT="$KEYFILE"
fi

# 授权行：command= 把这台服务器上的任何 SSH 命令都顶成 push-incoming.sh
# restrict 禁掉 pty / 端口转发 / agent 转发
# ⚠️ 必须带 --project <名>：这把密钥只授权这一个项目，
#    否则 kids 的 CI 密钥能往 xuexu 的产物目录里塞文件、也能触发 xuexu 发布。
# ⚠️ 比对的是【整条授权行】而不是公钥：同一把公钥配不同的 command= 是两条不同的授权，
#    只比公钥会把「本项目该加的那条」误判成「已经有了」→ 静默不写。
AUTH_LINE="${AUTH_PREFIX}${PUBKEY}"
if grep -qF "$AUTH_LINE" "$KEYDIR/authorized_keys"; then
  log "authorized_keys 里已有这条授权，跳过"
else
  printf '%s\n' "$AUTH_LINE" >> "$KEYDIR/authorized_keys"
  log "已写入 authorized_keys"
fi

# ── 4. 验收 ────────────────────────────────────────────────────────────────
log "验收："
"$KIT_DIR/releaser.sh" status "$PROJECT" || die "releaser.sh status 跑不通"
# ⚠️ 下面这行必须用 `|| true` 而不是 `; true`：
#    `;` 只是分隔命令，set -e 照样会因前一条命令失败而退出整个脚本。
# ⚠️ 还必须带 --project：push-incoming.sh 现在**要求**绑定项目（没绑一律拒），
#    自检这一步少传就会自己把自己判成失败。
SSH_ORIGINAL_COMMAND="incoming-dir ${PROJECT}" "$KIT_DIR/push-incoming.sh" --project "${PROJECT}" \
  | sed 's|^|  产物目录: |'

cat <<EOF

══════════════════════════════════════════════════════════════
  ✅ deploy-kit 装好了（项目：${PROJECT}）

  接下来两步：

  ① 把 CI 私钥放进 GitHub 仓库的 Secrets
     Secret 名 : DEPLOY_SSH_KEY
     私钥位置 : ${PRIVATE_HINT}
     其它必需 : DEPLOY_HOST / DEPLOY_USER
     可选     : DEPLOY_PORT（默认 22）

  ② 在项目仓加 .github/workflows/deploy.yml 调用本仓的 reusable workflow
     uses: fmd99833125/deploy-kit/.github/workflows/deploy.yml@v1

  服务器上 verify：
     ${KIT_DIR}/releaser.sh status ${PROJECT}
══════════════════════════════════════════════════════════════
EOF
