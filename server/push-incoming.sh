#!/usr/bin/env bash
# ============================================================================
# deploy-kit · 受限 SSH 入口
#
# 用途：放进 authorized_keys 的 command= 里，CI 用密钥登录服务器后**只能**跑这一个脚本。
#       SSH 客户端请求执行的原始命令会放进 $SSH_ORIGINAL_COMMAND，本脚本按白名单分发。
#
#       为什么要有这一层：CI 要往服务器推产物，就得有服务器私钥。私钥一旦泄露，
#       攻击者就能直接 SSH 上去跑任意命令。用 command= 限制住，泄露的密钥
#       最多只能「把已经推上去的产物发布一下」，不能拿它挖矿。
#
# 授权示例（公钥来自 GitHub Actions 的 deploy key）：
#   command="/opt/deploy-kit/push-incoming.sh --project xuexu",restrict ssh-ed25519 AAAA... github-actions
#
# ⚠️ **--project 把密钥绑定到一个项目上**：
#    不绑定的话，A 项目的 CI 密钥能往 B 项目的产物目录里塞文件、也能触发 B 项目发布
#    —— 多项目共用一台服务器时，这就是一条现成的横向越权通道。
#    install-server.sh 会自动写成带 --project 的形式。
#
# 允许的子命令：
#   scp -t <path>        上传产物到 <path>（path 必须是已知项目的产物目录下的标准文件名）
#   apply      <project> <sha>        应用指定版本
#   status     <project>              查看当前版本
#   has        <project> <sha>        检查产物是否就绪
#   incoming-dir <project>            打印该项目的产物落地目录
#
# ⚠️ 为什么用 scp 不用 rsync：
#    authorized_keys 的 command= 会**顶掉**客户端请求的远程命令，rsync 依赖远程跑
#    `rsync --server <一堆参数>`，参数很难严格校验后原样 exec；scp 只有一个
#    `scp -t <目标路径>`，目标路径可以精确校验 → 校验通过后原样 exec 给真正的 scp。
# ============================================================================
set -Eeuo pipefail

KIT_DIR="${KIT_DIR:-/opt/deploy-kit}"
RELEASER="$KIT_DIR/releaser.sh"
PROJECTS_DIR="${PROJECTS_DIR:-$KIT_DIR/projects.d}"

die() { printf '[push-incoming] ❌ %s\n' "$*" >&2; exit 1; }

# ── 绑定项目（授权行里带 --project <名>）──────────────────────────────────
PINNED_PROJECT=""
if [ "${1:-}" = "--project" ]; then
  PINNED_PROJECT="${2:-}"
  [ -n "$PINNED_PROJECT" ] || die "--project 后面要跟项目名"
  shift 2
fi
if [ -n "$PINNED_PROJECT" ]; then
  if ! printf '%s' "$PINNED_PROJECT" | grep -qE '^[a-z0-9][a-z0-9-]{0,30}$'; then
    die "绑定的项目名格式不合法：${PINNED_PROJECT}"
  fi
  [ -f "$PROJECTS_DIR/${PINNED_PROJECT}.env" ] \
    || die "绑定的项目未注册：${PINNED_PROJECT}（找不到 ${PROJECTS_DIR}/${PINNED_PROJECT}.env）"
fi

if [ -z "$PINNED_PROJECT" ]; then
  die "未绑定项目，拒绝一切操作（授权行应写成 command=\"${KIT_DIR}/push-incoming.sh --project <项目名>\"）"
fi

CMD="${SSH_ORIGINAL_COMMAND:-}"
[ -n "$CMD" ] || die "没有拿到要执行的命令"

# 词分割（不做 glob、不做 eval）
read -r -a words <<< "$CMD"
[ "${#words[@]}" -ge 1 ] || die "命令为空"
verb="${words[0]}"

# ── 白名单 ─────────────────────────────────────────────────────────────────
case "$verb" in
  scp|apply|status|has|incoming-dir) : ;;
  *) die "不允许的命令：${verb}（可用：scp / apply / status / has / incoming-dir）" ;;
esac

# ── scp 上传：严格校验目标路径后，原样 exec 给真正的 scp ──────────────────
if [ "$verb" = "scp" ]; then
  [ "${#words[@]}" -ge 2 ] || die "scp 参数不全"
  case " ${words[*]:1} " in
    *" -t "*) : ;;
    *) die "只允许 scp -t（上传），不接受其它 scp 用法" ;;
  esac
  target="${words[${#words[@]}-1]}"

  # 目标必须精确形如 <项目的 ARTIFACT_DIR>/<sha>.<kind>.tar.gz
  # ⚠️ 绑定模式下**只看绑定的那一个项目** —— 否则 A 项目的密钥能往 B 项目塞文件。
  matched=0
  if [ -n "$PINNED_PROJECT" ]; then
    cfgs="$PROJECTS_DIR/${PINNED_PROJECT}.env"
  else
    die "未绑定项目，拒绝上传（授权行应写成 command=\"${KIT_DIR}/push-incoming.sh --project <项目名>\"）"
  fi
  for cfg in $cfgs; do
    [ -f "$cfg" ] || continue
    # shellcheck disable=SC1090
    . "$cfg"
    dir="${ARTIFACT_DIR:-}"
    [ -n "$dir" ] || continue
    case "$target" in
      "$dir"/*)
        fname="${target#"$dir"/}"
        if printf '%s' "$fname" | grep -qE '^[0-9a-f]{7,40}\.(web-dist|api-image)\.tar\.gz$'; then
          matched=1
          break
        fi
        ;;
    esac
  done
  if [ "$matched" != "1" ]; then
    if [ -n "$PINNED_PROJECT" ]; then
      die "这把密钥只授权了项目 ${PINNED_PROJECT}，无权上传到 ${target}"
    fi
    die "拒绝上传到该路径：${target}（文件名必须是 <sha>.web-dist.tar.gz / <sha>.api-image.tar.gz）"
  fi

  exec scp -t "$target"
fi

# ── 以下都是「命令 + 参数」形式 ───────────────────────────────────────────
arg1="${words[1]:-}"
arg2="${words[2]:-}"

if [ -z "$arg1" ]; then
  die "缺少项目名"
fi
# 项目名只允许小写字母数字和连字符 —— 防路径穿越
if ! printf '%s' "$arg1" | grep -qE '^[a-z0-9][a-z0-9-]{0,30}$'; then
  die "项目名格式不合法：${arg1}"
fi

if [ "$verb" = "apply" ] || [ "$verb" = "has" ]; then
  if [ -z "$arg2" ]; then
    die "缺少版本号（sha）"
  fi
  # 版本号只允许十六进制 —— 防路径穿越 + 防命令注入
  if ! printf '%s' "$arg2" | grep -qE '^[0-9a-f]{7,40}$'; then
    die "版本号格式不合法：${arg2}（只允许 7-40 位十六进制）"
  fi
fi

CONFIG="$PROJECTS_DIR/${arg1}.env"
[ -f "$CONFIG" ] || die "未知项目：${arg1}（找不到 ${CONFIG}）"

if [ -n "$PINNED_PROJECT" ] && [ "$arg1" != "$PINNED_PROJECT" ]; then
  die "这把密钥只授权了项目 ${PINNED_PROJECT}，无权操作 ${arg1}"
fi

case "$verb" in
  incoming-dir)
    # 打印产物落地目录，CI 按这个路径上传
    # shellcheck disable=SC1090
    . "$CONFIG"
    ARTIFACT_DIR="${ARTIFACT_DIR:?配置缺 ARTIFACT_DIR}"
    printf '%s\n' "$ARTIFACT_DIR"
    ;;
  apply)
    exec "$RELEASER" apply "$arg1" "$arg2"
    ;;
  status)
    exec "$RELEASER" status "$arg1"
    ;;
  has)
    exec "$RELEASER" has "$arg1" "$arg2"
    ;;
esac
