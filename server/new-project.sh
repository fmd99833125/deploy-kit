#!/usr/bin/env bash
# ============================================================================
# deploy-kit · 新项目接入脚手架
#
# 一条命令把「接入一个新项目」要落的东西全生成好：
#   ① deploy-kit 的项目注册表条目   server/projects.d/<项目名>.env
#   ② 项目仓的发布 workflow        <项目仓>/.github/workflows/deploy.yml
#   ③ 打印服务器端命令 + GitHub Secrets 清单
#
# 用法（在 deploy-kit 仓根目录）：
#   bash server/new-project.sh --name kids \
#        --project-repo ../kids-english-copilot \
#        --api-image kids-api \
#        --api-dockerfile deploy/Dockerfile.server \
#        --health-services "api caddy" --app-services api
#
#   纯前端项目（没有后端镜像）：
#   bash server/new-project.sh --name mysite --no-api --project-repo ../mysite
#
# 常用开关：--dry-run（只看要做什么）· --force（覆盖已存在的文件）
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_DIR="$SCRIPT_DIR/projects.d"

# ── 默认值 ────────────────────────────────────────────────────────────────
NAME=""
PROJECT_REPO=""
WEB_DIR="web"
API_IMAGE=""
NO_API=0
API_DOCKERFILE="deploy/Dockerfile.api"
IMAGE_CONTEXT="."
NODE_VERSION="22"
SKIP_PATHS='^(docs/|.*\.md$)'
DEPLOY_ROOT=""
HEALTH_SERVICES="api worker caddy"
APP_SERVICES="api worker"
WEB_SERVICES="caddy"
KEEP_RELEASES=3
DRY=0
FORCE=0

log()  { printf '[new-project] %s\n' "$*"; }
die()  { printf '[new-project] ❌ %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)             NAME="${2:-}"; shift 2 ;;
    --project-repo)     PROJECT_REPO="${2:-}"; shift 2 ;;
    --web-dir)          WEB_DIR="${2:-}"; shift 2 ;;
    --api-image)        API_IMAGE="${2:-}"; shift 2 ;;
    --no-api)           NO_API=1; shift ;;
    --api-dockerfile)   API_DOCKERFILE="${2:-}"; shift 2 ;;
    --image-context)    IMAGE_CONTEXT="${2:-}"; shift 2 ;;
    --node-version)     NODE_VERSION="${2:-}"; shift 2 ;;
    --skip-paths)       SKIP_PATHS="${2:-}"; shift 2 ;;
    --deploy-root)      DEPLOY_ROOT="${2:-}"; shift 2 ;;
    --health-services)  HEALTH_SERVICES="${2:-}"; shift 2 ;;
    --app-services)     APP_SERVICES="${2:-}"; shift 2 ;;
    --web-services)     WEB_SERVICES="${2:-}"; shift 2 ;;
    --keep-releases)    KEEP_RELEASES="${2:-}"; shift 2 ;;
    --dry-run)          DRY=1; shift ;;
    --force)            FORCE=1; shift ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *)                  die "未知参数：$1" ;;
  esac
done

[ -n "$NAME" ] || die "必须给 --name <项目名>"
# 项目名会进目录名、锁文件名、容器名，必须严格
case "$NAME" in
  *[!a-z0-9-]*) die "项目名只能用小写字母、数字、连字符（收到：${NAME}）" ;;
esac
[ "${#NAME}" -le 31 ] || die "项目名太长（≤31 字符）"

if [ "$NO_API" = "1" ]; then
  API_IMAGE=""
  API_DOCKERFILE=""
else
  [ -n "$API_IMAGE" ] || API_IMAGE="${NAME}-api"
fi

[ -n "$DEPLOY_ROOT" ] || DEPLOY_ROOT="/opt/${NAME}"

ENV_FILE="$PROJECTS_DIR/${NAME}.env"
WORKFLOW_FILE=""
if [ -n "$PROJECT_REPO" ]; then
  WORKFLOW_FILE="$PROJECT_REPO/.github/workflows/deploy.yml"
fi

# ── 预检：别覆盖别人的东西 ────────────────────────────────────────────────
for f in "$ENV_FILE" $WORKFLOW_FILE; do
  [ -n "$f" ] || continue
  if [ -f "$f" ] && [ "$FORCE" != "1" ]; then
    die "文件已存在：${f}（要覆盖请加 --force）"
  fi
done

# ── 生成注册表条目 ────────────────────────────────────────────────────────
ENV_CONTENT="$(cat <<EOF
# deploy-kit 项目注册表 · ${NAME}
#
# 这份文件会被装到服务器的 /opt/deploy-kit/projects.d/${NAME}.env
# releaser.sh / push-incoming.sh 都靠它知道这个项目的路径和镜像。

PROJECT_NAME=${NAME}

# 代码仓在服务器上的位置
REPO_DIR=${DEPLOY_ROOT}/repo
DEPLOY_DIR=${DEPLOY_ROOT}/repo/deploy

# 版本留存（前端目录 + 当前版本号）
RELEASES_DIR=${DEPLOY_ROOT}/releases

# CI 传产物的落地目录
ARTIFACT_DIR=${DEPLOY_ROOT}/incoming

# 前端产物放在 deploy/ 下的哪个子目录（compose 里 bind mount 的那个）
WEB_SUBDIR=web

# 后端镜像。**显式留空 = 本项目没有后端镜像**（纯前端站），
# 不写这一行则默认用 <项目名>-api。
API_IMAGE=${API_IMAGE}

# 换镜像后要重建的服务（跑业务代码的容器）
# ⚠️ 值必须加引号：这份文件会被 . (source) 进来，
#    不加引号时 "api caddy" 会被解析成两条赋值 —— 第二个词 caddy 会被当成命令执行。
APP_SERVICES="${APP_SERVICES}"

# 换前端后要重建的服务（bind mount 绑着 web 目录，必须重建才重新解析 inode）
WEB_SERVICES="${WEB_SERVICES}"

# 健康检查看哪些服务：全部 running/healthy 才算发布成功
HEALTH_SERVICES="${HEALTH_SERVICES}"

# 保留最近几个版本（其余的会被清理）
KEEP_RELEASES=${KEEP_RELEASES}
EOF
)"

# ── 生成项目仓的 workflow ────────────────────────────────────────────────
WORKFLOW_CONTENT=""
if [ -n "$WORKFLOW_FILE" ]; then
  if [ "$NO_API" = "1" ]; then
    WITH_BLOCK="      project: ${NAME}
      web_dir: ${WEB_DIR}
      node_version: \"${NODE_VERSION}\"
      skip_paths: '${SKIP_PATHS}'"
  else
    WITH_BLOCK="      project: ${NAME}
      web_dir: ${WEB_DIR}
      api_image: ${API_IMAGE}
      api_dockerfile: ${API_DOCKERFILE}
      image_context: ${IMAGE_CONTEXT}
      node_version: \"${NODE_VERSION}\"
      skip_paths: '${SKIP_PATHS}'"
  fi

  WORKFLOW_CONTENT="$(cat <<EOF
# ============================================================================
# ${NAME} · 发布
#
# 真正的发布流程在 deploy-kit 仓里（reusable workflow），这里只提供项目参数。
# 改发布逻辑 → 改 deploy-kit；改本项目的构建参数 → 改这里。
#
# 服务器不构建：前端产物和后端镜像都在 CI 上构建好再传过去。
# ============================================================================
name: deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: fmd99833125/deploy-kit/.github/workflows/deploy.yml@v1
    with:
${WITH_BLOCK}
    secrets: inherit
EOF
)"
fi

# ── 落盘 / dry-run ───────────────────────────────────────────────────────
if [ "$DRY" = "1" ]; then
  log "—— dry-run：不会写任何文件 ——"
  log ""
  log "① 注册表条目 → ${ENV_FILE}"
  printf '%s\n' "$ENV_CONTENT" | sed 's|^|  |'
  if [ -n "$WORKFLOW_FILE" ]; then
    log ""
    log "② 项目 workflow → ${WORKFLOW_FILE}"
    printf '%s\n' "$WORKFLOW_CONTENT" | sed 's|^|  |'
  fi
  log ""
  log "③ 服务器端："
  log "   把 deploy-kit/server/ 传上去，然后："
  log "   bash install-server.sh --project ${NAME}"
  log ""
  log "④ GitHub Secrets：DEPLOY_HOST / DEPLOY_USER / DEPLOY_SSH_KEY（DEPLOY_PORT 可选）"
  exit 0
fi

mkdir -p "$PROJECTS_DIR"
printf '%s\n' "$ENV_CONTENT" > "$ENV_FILE"
log "已生成注册表条目：${ENV_FILE}"

if [ -n "$WORKFLOW_FILE" ]; then
  mkdir -p "$(dirname "$WORKFLOW_FILE")"
  printf '%s\n' "$WORKFLOW_CONTENT" > "$WORKFLOW_FILE"
  log "已生成项目 workflow：${WORKFLOW_FILE}"
fi

cat <<EOF

══════════════════════════════════════════════════════════════
  ✅ ${NAME} 的接入物料已生成

  ① deploy-kit 仓：提交 server/projects.d/${NAME}.env
  ② 项目仓：提交 .github/workflows/deploy.yml
  ③ 服务器端：
       把 deploy-kit/server/ 传上去，然后
       bash install-server.sh --project ${NAME}
  ④ GitHub Secrets（项目仓）：DEPLOY_HOST / DEPLOY_USER / DEPLOY_SSH_KEY
  ⑤ 推 main 触发首次发布

  ⚠️ deploy-kit 仓要推上去才有 reusable workflow 可引用：
       git remote add origin git@github.com:fmd99833125/deploy-kit.git
       git push -u origin main && git tag v1 && git push origin v1
══════════════════════════════════════════════════════════════
EOF
