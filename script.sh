#!/bin/bash
# Online SSH for the OpenWRT build workflows.
#
# This used to drive tmate. tmate.io is gone: the domain no longer publishes an A record
# (Cloudflare DoH returns NOERROR with no answer), so `tmate ... wait tmate-ready` never
# returns and the step hung until the job timed out. The session now runs on sshx
# (https://sshx.io): a single static binary that opens a browser terminal, no account and
# no SSH client needed.
#
# Environment variables understood here (same names as the old tmate version):
#   TIMEOUT_MIN         how many minutes the session stays open (default 30)
#   TIMEOUT_FAIL        1/true -> fail the step when the session times out instead of continuing
#   SKIP_DEBUGGER       set to anything -> skip this step entirely
#   SSHX_NAME           session name shown in the browser title
#   INFORMATION_NOTICE  TG | PUSH -> also send the link through Telegram / PushPlus
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, PUSH_PLUS_TOKEN
#
# Ending the session: press Ctrl+D (or type exit) in the browser terminal. sshx keeps the
# session alive after a shell closes, so the shell runs through a small wrapper that stops
# sshx as soon as the shell ends -- this restores the old tmate behaviour, where Ctrl+D
# continued the build immediately instead of waiting out the timeout.

set -uo pipefail

if [[ -n "${SKIP_DEBUGGER:-}" ]]; then
  echo "SKIP_DEBUGGER is set, skipping the online SSH step"
  exit 0
fi

TIMEOUT_MIN="${TIMEOUT_MIN:-30}"
timeout=$(( TIMEOUT_MIN * 60 ))
LOG="/tmp/sshx-session.log"

echo "=============================================================="
echo " 在线 SSH（sshx 网页终端）"
echo "=============================================================="

export PATH="$HOME/.local/bin:$PATH"
if ! command -v sshx > /dev/null 2>&1; then
  echo "正在安装 sshx ..."
  if ! curl -sSf https://sshx.io/get | sh > /tmp/sshx-install.log 2>&1; then
    echo "::error::sshx 安装失败"
    tail -20 /tmp/sshx-install.log
    exit 1
  fi
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v sshx > /dev/null 2>&1; then
  echo "::error::安装后仍找不到 sshx"
  exit 1
fi
echo "版本: $(sshx --version 2>&1 | head -1)"

rm -f "$LOG" /tmp/sshx.pid

# sshx tracks shells and sessions separately, so closing the shell leaves the session (and
# the sshx process) running. Run the shell through this wrapper so that ending it -- Ctrl+D,
# `exit`, anything -- also stops sshx, which is what makes the step continue right away.
SHELL_WRAPPER="/tmp/sshx-shell.sh"
cat > "$SHELL_WRAPPER" <<'WRAPPER'
#!/bin/bash
stop_sshx() {
  if [[ -f /tmp/sshx.pid ]]; then
    kill "$(cat /tmp/sshx.pid)" 2>/dev/null
  fi
  pkill -x sshx 2>/dev/null
  return 0
}
trap stop_sshx EXIT
cd "${HOME_PATH:-$HOME}" 2>/dev/null
bash -i
WRAPPER
chmod +x "$SHELL_WRAPPER"

# -q prints nothing but the link. The fragment after '#' is the end-to-end encryption key,
# so the whole string has to be handed to the user unchanged.
setsid sshx -q --name "${SSHX_NAME:-github-actions}" --shell "$SHELL_WRAPPER" > "$LOG" 2>&1 < /dev/null &
SSHX_PID=$!
echo "$SSHX_PID" > /tmp/sshx.pid

SSH_URL=""
for _ in $(seq 1 90); do
  if [[ -s "$LOG" ]]; then
    SSH_URL="$(grep -oE 'https://sshx\.io/s/[A-Za-z0-9]+#[A-Za-z0-9_-]+' "$LOG" | head -1)"
    [[ -z "$SSH_URL" ]] && SSH_URL="$(tr -d '\r\n' < "$LOG" | head -c 200)"
  fi
  [[ -n "$SSH_URL" ]] && break
  if ! kill -0 "$SSHX_PID" 2>/dev/null; then
    echo "::error::sshx 进程意外退出"
    cat "$LOG"
    exit 1
  fi
  sleep 1
done

if [[ -z "$SSH_URL" ]]; then
  echo "::error::90 秒内没有拿到 sshx 连接地址"
  cat "$LOG"
  kill "$SSHX_PID" 2>/dev/null || true
  exit 1
fi

echo ""
echo "##############################################################"
echo "#  在线 SSH 地址（浏览器直接打开，无需安装任何客户端）"
echo "#"
echo "#   ${SSH_URL}"
echo "#"
echo "#  打开后就是一个终端（默认已经在 openwrt 目录里）"
echo "#      make menuconfig"
echo "#  配置完成、保存 .config 后，按 Ctrl+D（或输入 exit）就立刻继续编译；"
echo "#  不结束的话，${TIMEOUT_MIN} 分钟后会自动继续。"
echo "##############################################################"
echo ""

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 在线 SSH"
    echo ""
    echo "浏览器打开：<${SSH_URL}>"
    echo ""
    echo "打开后执行 \`make menuconfig\`（终端默认已在 openwrt 目录）；保存 \`.config\` 后按 \`Ctrl+D\` 继续编译。"
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]] && [[ "${INFORMATION_NOTICE:-}" == "TG" ]]; then
  echo -n "正在把地址发送到 Telegram ..."
  curl -k -s -o /dev/null --data chat_id="${TELEGRAM_CHAT_ID}" \
    --data "text=在线 SSH 地址：${SSH_URL}" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" && echo " 完成" || echo " 失败"
elif [[ -n "${PUSH_PLUS_TOKEN:-}" ]] && [[ "${INFORMATION_NOTICE:-}" == "PUSH" ]]; then
  echo -n "正在把地址发送到 PushPlus ..."
  curl -k -s -o /dev/null --data token="${PUSH_PLUS_TOKEN}" --data title="在线SSH连接地址" \
    --data "content=${SSH_URL}" "https://www.pushplus.plus/send" && echo " 完成" || echo " 失败"
fi

# Keep the session open until TIMEOUT_MIN elapses, or until the user ends the shell in the
# browser (Ctrl+D / exit). The wrapper above stops sshx at that moment, so this loop notices
# immediately instead of waiting out the timeout.
elapsed=0
while kill -0 "$SSHX_PID" 2>/dev/null; do
  if (( elapsed >= timeout )); then
    echo "等待连接超时（${TIMEOUT_MIN} 分钟），现在跳过 SSH 此步骤"
    kill "$SSHX_PID" 2>/dev/null || true
    wait "$SSHX_PID" 2>/dev/null || true
    if [[ "x${TIMEOUT_FAIL:-}" = "x1" ]] || [[ "x${TIMEOUT_FAIL:-}" = "xtrue" ]]; then
      exit 1
    fi
    exit 0
  fi
  if (( elapsed > 0 && elapsed % 60 == 0 )); then
    echo "在线 SSH 中 ...（已等待 ${elapsed} 秒，剩余 $(( timeout - elapsed )) 秒）"
    echo "地址：${SSH_URL}"
  fi
  sleep 5
  elapsed=$(( elapsed + 5 ))
done

echo "在线 SSH 会话已结束，继续编译"
exit 0
