#!/usr/bin/env bash
# ============================================================================
# deploy-kit · 服务器端统一发布器
#
# 职责：把 CI 推送过来的「版本产物」原子地应用到目标项目。
#       服务器**不构建**——前端产物和后端镜像都由 CI 构建好传过来。
#
# 用法：
#   releaser.sh apply    <project> <sha>   # 应用某个版本（sha = 8+ 位短 SHA）
#   releaser.sh rollback <project>          # 回滚到上一个成功版本
#   releaser.sh status   <project>          # 看当前版本 / 可回滚版本
#   releaser.sh has      <project> <sha>   # 检查该版本的产物是否已就绪（exit 0/1）
#
# 配置：$KIT_DIR/projects.d/<project>.env
#
# 设计要点（每条都对应一个踩过的坑）：
#   ① 原子替换用「换目录」而不是「换文件」——Caddy 的 bind mount 在容器创建时
#      就解析了源目录的 inode，改文件不会生效，必须换整个目录再重建 caddy。
#   ② 后端镜像用**固定 tag**（<project>-api:current），不用 sha 插值——
#      免得每次 docker compose 都要记得传环境变量，漏一次就回退到旧镜像。
#   ③ 健康检查失败 → 自动回滚（web.old 换回 + 镜像 tag 换回 + 重建容器）。
#   ④ 回滚不删旧产物，旧镜像和旧 web 都留着，随时能再滚回去。
# ============================================================================
set -Eeuo pipefail

KIT_DIR="${KIT_DIR:-/opt/deploy-kit}"
PROJECTS_DIR="${PROJECTS_DIR:-$KIT_DIR/projects.d}"
LOCK_DIR="${LOCK_DIR:-/run}"

log()  { printf '[releaser] %s\n' "$*"; }
warn() { printf '[releaser] ⚠️  %s\n' "$*" >&2; }
die()  { printf '[releaser] ❌ %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,26p' "$0"; }

# ---------------------------------------------------------------------------
# 加载项目配置
# ---------------------------------------------------------------------------
load_project() {
  local project="$1"
  local sha="${2:-}"
  local f="$PROJECTS_DIR/$project.env"
  [ -f "$f" ] || die "未知项目「${project}」：找不到配置 ${f}"
  # shellcheck disable=SC1090
  . "$f"

  PROJECT_NAME="${PROJECT_NAME:-$project}"
  REPO_DIR="${REPO_DIR:?配置缺 REPO_DIR}"
  DEPLOY_DIR="${DEPLOY_DIR:-$REPO_DIR/deploy}"
  RELEASES_DIR="${RELEASES_DIR:-$REPO_DIR/releases}"
  ARTIFACT_DIR="${ARTIFACT_DIR:-$REPO_DIR/incoming}"
  WEB_SUBDIR="${WEB_SUBDIR:-web}"
  # ⚠️ 这里用 `-` 不是 `:-`：
  #    配置里**显式写空**（API_IMAGE=）= 本项目没有后端镜像（纯前端站），
  #    配置里**完全不写** = 用默认名 <项目名>-api。
  API_IMAGE="${API_IMAGE-$PROJECT_NAME-api}"
  # ⚠️ 下面三个服务列表也用 `-` 不是 `:-`，理由同 API_IMAGE：
  #    配置里**显式写空**（APP_SERVICES=）= 这一步**不做**；
  #    配置里**完全不写** = 用默认值。
  #    为什么需要「显式写空」：有些项目前端也由 api 自己托管
  #    （同域挂 web/dist），只需要换前端时重建它**一次**，
  #    这时 APP_SERVICES= 写空、WEB_SERVICES=api。
  #    ❌ 用 `:-` 的话空串会回退成默认值 → 跑去重建本项目根本没有的服务
  #    → 日志里刷「no such service: worker」（不阻断发布，但会让人以为坏了）。
  # 换镜像后要重建的服务（跑业务代码的容器）
  APP_SERVICES="${APP_SERVICES-api worker}"
  # 换前端后要重建的服务（bind mount 绑着 web 目录，必须重建才重新解析 inode）
  WEB_SERVICES="${WEB_SERVICES-caddy}"
  # 健康检查看哪些服务
  HEALTH_SERVICES="${HEALTH_SERVICES-api worker caddy}"
  KEEP_RELEASES="${KEEP_RELEASES:-3}"
  STATE_FILE="$RELEASES_DIR/.current"

  WEB_DIR="$DEPLOY_DIR/$WEB_SUBDIR"
  WEB_OLD_DIR="$DEPLOY_DIR/$WEB_SUBDIR.old"
}

# ---------------------------------------------------------------------------
# 单实例锁：CI 的 SSH 触发和定时器可能同时到达
# ---------------------------------------------------------------------------
acquire_lock() {
  local project="$1"
  mkdir -p "$LOCK_DIR"
  local lock="${LOCK_DIR}/deploy-${project}.lock"
  exec 9>"$lock"
  if ! flock -n 9; then
    die "另一个发布正在进行中（${lock}），本次跳过"
  fi
}

# ---------------------------------------------------------------------------
# 健康检查：容器都活着才算成功
# ---------------------------------------------------------------------------
health_check() {
  local ps_out
  ps_out="$(cd "$DEPLOY_DIR" && docker compose ps --format '{{.Service}}\t{{.State}}' 2>/dev/null || true)"
  [ -n "$ps_out" ] || { warn "拿不到容器状态"; return 1; }

  local svc state
  for svc in $HEALTH_SERVICES; do
    state="$(printf '%s\n' "$ps_out" | awk -F'\t' -v s="$svc" '$1==s{print $2}')"
    case "$state" in
      running|healthy) : ;;
      *) warn "服务 ${svc} 状态异常：${state:-（没起来）}"; return 1 ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# has：产物是否就绪
# ---------------------------------------------------------------------------
cmd_has() {
  local project="$1" sha="$2"
  load_project "$project" "$sha"
  local art="$ARTIFACT_DIR/${sha}.web-dist.tar.gz"
  local img="$ARTIFACT_DIR/${sha}.api-image.tar.gz"
  local ok=1
  [ -f "$art" ] || { warn "缺前端产物：$art"; ok=0; }
  if [ -n "$API_IMAGE" ]; then
    [ -f "$img" ] || { warn "缺后端镜像：$img"; ok=0; }
  fi
  [ "$ok" = "1" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# apply：应用指定版本
# ---------------------------------------------------------------------------
cmd_apply() {
  local project="$1" sha="$2"
  load_project "$project" "$sha"
  acquire_lock "$project"

  local art="$ARTIFACT_DIR/${sha}.web-dist.tar.gz"
  local img="$ARTIFACT_DIR/${sha}.api-image.tar.gz"
  [ -f "$art" ] || die "缺前端产物：${art}（CI 还没传完？）"
  if [ -n "$API_IMAGE" ]; then
    [ -f "$img" ] || die "缺后端镜像：${img}（CI 还没传完？）"
  fi

  local prev_sha=""
  [ -f "$STATE_FILE" ] && prev_sha="$(cat "$STATE_FILE")"
  log "发布 ${PROJECT_NAME} @ ${sha}${prev_sha:+（当前 ${prev_sha}）}"

  # ---- 1. 解包前端到 releases（保留，供回滚）----
  local rel_web="$RELEASES_DIR/web/$sha"
  rm -rf "$rel_web.tmp" "$rel_web"
  mkdir -p "$rel_web.tmp"
  tar -xzf "$art" -C "$rel_web.tmp"
  [ -f "$rel_web.tmp/index.html" ] || die "前端产物里没有 index.html —— 打包结构不对"
  mv "$rel_web.tmp" "$rel_web"

  # ---- 2. 载入后端镜像并打上固定 tag（纯前端项目跳过）----
  if [ -n "$API_IMAGE" ]; then
    log "载入镜像"
    gunzip -c "$img" | docker load >/dev/null
    docker tag "${API_IMAGE}:${sha}" "${API_IMAGE}:current"
    docker tag "${API_IMAGE}:${sha}" "${API_IMAGE}:${sha}" 2>/dev/null || true
  else
    log "本项目没有后端镜像（API_IMAGE 为空），只发布前端"
  fi

  # ---- 3. 原子替换 web 目录（换 inode，bind mount 才会重新解析）----
  log "替换前端目录"
  rm -rf "$WEB_DIR.new"
  mkdir -p "$WEB_DIR.new"
  cp -a "$rel_web/." "$WEB_DIR.new/"
  rm -rf "$WEB_OLD_DIR"
  if [ -d "$WEB_DIR" ]; then
    mv "$WEB_DIR" "$WEB_OLD_DIR"
  fi
  mv "$WEB_DIR.new" "$WEB_DIR"

  # ---- 4. 起容器（镜像 tag 变了，compose 会重建跑业务的服务）----
  log "重建容器"
  # 服务列表可以留空 —— 有些项目「前端也由 api 自己托管」（同域挂 web/dist），
  # 那就只需要在换前端时重建它一次，不必重建两遍。
  if [ -n "$APP_SERVICES" ]; then
    # shellcheck disable=SC2086
    (cd "$DEPLOY_DIR" && docker compose up -d --force-recreate $APP_SERVICES) || true
  fi
  if [ -n "$WEB_SERVICES" ]; then
    # shellcheck disable=SC2086
    (cd "$DEPLOY_DIR" && docker compose up -d --force-recreate $WEB_SERVICES) || true
  fi

  # ---- 5. 健康检查；不过就回滚 ----
  sleep 3
  if ! health_check; then
    warn "健康检查未通过 → 自动回滚"
    do_rollback "$prev_sha"
    die "发布失败，已回滚到 ${prev_sha:-（无上一版）}"
  fi

  printf '%s' "$sha" > "$STATE_FILE"
  prune_releases
  log "发布完成：${PROJECT_NAME} @ ${sha}"
}

# ---------------------------------------------------------------------------
# 回滚
# ---------------------------------------------------------------------------
do_rollback() {
  local prev_sha="${1:-}"
  warn "开始回滚 ${PROJECT_NAME}${prev_sha:+ → ${prev_sha}}"

  # 前端：换回旧目录
  if [ -d "$WEB_OLD_DIR" ]; then
    rm -rf "$WEB_DIR.revert"
    mv "$WEB_DIR" "$WEB_DIR.revert" 2>/dev/null || true
    mv "$WEB_OLD_DIR" "$WEB_DIR"
    rm -rf "$WEB_DIR.revert"
  else
    warn "没有可回滚的前端目录（$WEB_OLD_DIR 不存在）"
  fi

  # 后端：把旧镜像重新打成 current（纯前端项目没有镜像要回滚）
  if [ -n "$API_IMAGE" ]; then
    if [ -n "$prev_sha" ] && docker image inspect "${API_IMAGE}:${prev_sha}" >/dev/null 2>&1; then
      docker tag "${API_IMAGE}:${prev_sha}" "${API_IMAGE}:current"
    else
      warn "旧镜像 ${API_IMAGE}:${prev_sha:-?} 不在本地，后端无法回滚"
    fi
  fi

  if [ -n "$APP_SERVICES" ]; then
    # shellcheck disable=SC2086
    (cd "$DEPLOY_DIR" && docker compose up -d --force-recreate $APP_SERVICES) || true
  fi
  if [ -n "$WEB_SERVICES" ]; then
    # shellcheck disable=SC2086
    (cd "$DEPLOY_DIR" && docker compose up -d --force-recreate $WEB_SERVICES) || true
  fi
  sleep 3
  health_check || warn "回滚后健康检查仍未通过 —— 需要人工介入"

  if [ -n "$prev_sha" ]; then
    printf '%s' "$prev_sha" > "$STATE_FILE"
  fi
}

cmd_rollback() {
  local project="$1"
  load_project "$project" ""
  acquire_lock "$project"
  local cur=""
  [ -f "$STATE_FILE" ] && cur="$(cat "$STATE_FILE")"
  [ -n "$cur" ] || die "没有记录过任何版本，无从回滚"
  do_rollback ""
}

# ---------------------------------------------------------------------------
# 清理：只保留最近 KEEP_RELEASES 个版本
# ---------------------------------------------------------------------------
prune_releases() {
  local keep="$KEEP_RELEASES"
  local old
  old="$(ls -1dt "$RELEASES_DIR"/web/*/ 2>/dev/null | tail -n +$((keep + 1)) | head -20)"
  [ -n "$old" ] || return 0
  for d in $old; do
    rm -rf "$d"
  done
  log "已清理旧版本，只保留最近 ${keep} 个"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
cmd_status() {
  local project="$1"
  load_project "$project" ""
  printf '  项目      : %s\n' "$PROJECT_NAME"
  printf '  当前版本  : %s\n' "$([ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo '（未发布过）')"
  printf '  可回滚目录: %s\n' "$([ -d "$WEB_OLD_DIR" ] && echo "$WEB_OLD_DIR" || echo '（无）')"
  # 版本目录名是十六进制 sha（不含空格等特殊字符），xargs -n1 basename 是安全的
  # shellcheck disable=SC2011
  printf '  已存版本  : %s\n' "$(ls -1dt "$RELEASES_DIR"/web/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ' || echo '（无）')"
  if [ -n "$API_IMAGE" ]; then
    printf '  镜像      : %s\n' "$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "^${API_IMAGE}:" | tr '\n' ' ' || echo '（无）')"
  else
    printf '  镜像      : （本项目无后端镜像）\n'
  fi
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  apply)    shift; [ $# -ge 2 ] || { usage; exit 1; }; cmd_apply "$1" "$2" ;;
  rollback) shift; [ $# -ge 1 ] || { usage; exit 1; }; cmd_rollback "$1" ;;
  status)   shift; [ $# -ge 1 ] || { usage; exit 1; }; cmd_status "$1" ;;
  has)      shift; [ $# -ge 2 ] || { usage; exit 1; }; cmd_has "$1" "$2" ;;
  *)        usage; exit 1 ;;
esac
