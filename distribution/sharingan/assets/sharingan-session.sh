#!/usr/bin/env bash
# sharingan の録音セッションを背景で管理する。
# Claude(agent skill)が録音の start/stop/status/latest を制御するための薄いラッパー。
set -euo pipefail

STATE_DIR="${SHARINGAN_STATE:-$HOME/.sharingan}"
TRANSCRIPT_DIR="${SHARINGAN_DIR:-$STATE_DIR/transcripts}"
PID_FILE="$STATE_DIR/current.pid"
PATH_FILE="$STATE_DIR/current.path"
LOG_FILE="$STATE_DIR/current.log"
# 既定では PATH 上の sharingan を使う。テスト時は SHARINGAN_BIN_PATH で差し替え可能。
BIN="${SHARINGAN_BIN_PATH:-sharingan}"

mkdir -p "$TRANSCRIPT_DIR"

is_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd_start() {
  if is_running; then
    echo "すでに録音中です (PID $(cat "$PID_FILE"))。停止するには stop。" >&2
    exit 1
  fi
  local file
  file="$TRANSCRIPT_DIR/$(date +%Y-%m-%d_%H%M%S).md"
  # 背景実行。ライブ表示とエラーはログへ。停止時は SIGINT で末尾を確定させる。
  nohup "$BIN" "$file" >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  echo "$file" >"$PATH_FILE"
  echo "録音開始: $file (PID $(cat "$PID_FILE"))"
}

cmd_stop() {
  if ! is_running; then
    echo "録音は実行されていません。" >&2
    exit 1
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  # SIGTERM で sharingan が末尾の発話を確定してから終了する(graceful stop)。
  # 背景プロセスは SIGINT を無視するため、必ず届く TERM を使う。
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  # 5秒経っても生きていれば強制終了にエスカレーションする。
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.3
  fi
  # 死亡を確認できるまで PID ファイルを消さない(孤児プロセスの取り残しを防ぐ)。
  if kill -0 "$pid" 2>/dev/null; then
    echo "停止に失敗しました (PID $pid がまだ動いています)。" >&2
    exit 1
  fi
  rm -f "$PID_FILE"
  echo "停止しました: $(cat "$PATH_FILE" 2>/dev/null || echo unknown)"
}

cmd_status() {
  if is_running; then
    echo "running pid=$(cat "$PID_FILE") file=$(cat "$PATH_FILE" 2>/dev/null)"
  else
    echo "stopped"
  fi
}

cmd_latest() {
  if [ -f "$PATH_FILE" ] && [ -s "$PATH_FILE" ]; then
    cat "$PATH_FILE"
  else
    # 直近の transcript を返す
    ls -t "$TRANSCRIPT_DIR"/*.md 2>/dev/null | head -1
  fi
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  latest) cmd_latest ;;
  *)
    echo "usage: sharingan-session {start|stop|status|latest}" >&2
    exit 2
    ;;
esac
