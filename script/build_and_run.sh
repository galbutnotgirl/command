#!/usr/bin/env bash
set -euo pipefail

MODE="run"
ALLOW_UNQUALIFIED=0
APP_NAME="Command"
BUNDLE_ID="com.claudecommand"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/Command.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_SOCKET="${HOME}/.claude/state/command-agent.sock"

usage() {
  echo "usage: $0 --allow-unqualified [run|--debug|--logs|--telemetry|--verify]" >&2
}

for argument in "$@"; do
  case "$argument" in
    --allow-unqualified) ALLOW_UNQUALIFIED=1 ;;
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) MODE="$argument" ;;
    *) usage; exit 2 ;;
  esac
done

if [ "$ALLOW_UNQUALIFIED" != "1" ]; then
  echo "Refusing to launch unqualified development build." >&2
  echo "Run time ./qualify-installed-build.sh for daily app, or add --allow-unqualified for isolated UI development." >&2
  exit 64
fi

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  "$ROOT_DIR/build-agent.sh"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

wait_for_process() {
  for _ in {1..30}; do
    pgrep -x "$APP_NAME" >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

wait_for_socket() {
  for _ in {1..30}; do
    [ -S "$APP_SOCKET" ] && return 0
    sleep 0.2
  done
  return 1
}

ping_socket() {
  python3 - "$APP_SOCKET" <<'PY'
import socket, sys, time
path = sys.argv[1]
last_error = None
for _ in range(30):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(path)
        s.sendall(b"ping\n")
        reply = s.recv(1024).decode("utf-8", "replace").strip()
        s.close()
        if reply == "pong":
            raise SystemExit(0)
        raise RuntimeError(f"unexpected socket reply: {reply!r}")
    except SystemExit:
        raise
    except Exception as exc:
        last_error = exc
        time.sleep(0.2)
raise SystemExit(f"socket ping failed: {last_error}")
PY
}

verify_bundle_docs() {
  for doc in index.html install.html guide.html settings.html quick-reference.html limitations.html troubleshooting.html support.html release.html; do
    [ -f "$APP_BUNDLE/Contents/Resources/docs/$doc" ] || {
      echo "missing bundled docs/$doc" >&2
      return 1
    }
  done
}

stop_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    wait_for_process
    wait_for_socket
    ping_socket
    verify_bundle_docs
    echo "$APP_NAME runtime ok"
    ;;
  *)
    usage
    exit 2
    ;;
esac
