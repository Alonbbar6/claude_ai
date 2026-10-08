#!/usr/bin/env bash
# Bring up what the phone needs: backend on 0.0.0.0:8000 and the ngrok tunnel on the
# static domain from ios/project.yml. Idempotent. `--web` also starts the web demo on :8010.
set -u
cd "$(dirname "$0")/../../../.." || exit 2   # repo root (claude_ai/)
LOGS=~/Library/Logs/minieats; mkdir -p "$LOGS"
DOMAIN=${NGROK_DOMAIN:-$(grep -E '^\s*MINIEATS_SERVER_URL:' ios/project.yml | head -1 | sed -E 's/.*https?:\/\///; s/\s*$//')}
WEB=0; [ "${1:-}" = "--web" ] && WEB=1

wait_for() { for _ in $(seq 1 "$2"); do curl -s -m 3 -o /dev/null -H 'ngrok-skip-browser-warning: 1' "$1" && return 0; sleep 1; done; return 1; }

# 1. backend
if pgrep -f 'uvicorn app.main:app' >/dev/null; then
  if pgrep -f 'uvicorn app.main:app' | xargs -I{} ps -o args= -p {} | grep -q -- '--host 0.0.0.0'; then
    echo "backend: already running on 0.0.0.0:8000"
  else
    echo "backend: running on localhost only — restarting on 0.0.0.0"; pkill -f 'uvicorn app.main:app'; sleep 1
  fi
fi
if ! pgrep -f 'uvicorn app.main:app' >/dev/null; then
  [ -f .env ] && set -a && . ./.env && set +a
  nohup .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 >"$LOGS/backend.log" 2>&1 &
  wait_for http://127.0.0.1:8000/api/restaurants 20 && echo "backend: started on 0.0.0.0:8000" || { echo "backend: FAILED to start — tail $LOGS/backend.log"; exit 1; }
fi

# 2. ngrok (free plan: one tunnel per agent, so never start a second one)
if [ -z "$DOMAIN" ]; then echo "ngrok: no static domain in ios/project.yml; set NGROK_DOMAIN"; exit 1; fi
if pgrep -x ngrok >/dev/null; then
  echo "ngrok: agent already running ($(curl -s -m 3 http://127.0.0.1:4040/api/tunnels | grep -o '"public_url":"[^"]*' | head -1 | cut -d'"' -f4))"
else
  command -v ngrok >/dev/null || { echo "ngrok: not installed (brew install ngrok)"; exit 1; }
  nohup ngrok http --domain="$DOMAIN" 8000 --log=stdout >"$LOGS/ngrok.log" 2>&1 &
  wait_for http://127.0.0.1:4040/api/tunnels 15 && echo "ngrok: tunnel up on https://$DOMAIN -> :8000" || { echo "ngrok: FAILED — tail $LOGS/ngrok.log (is the authtoken set? is another agent using the domain?)"; exit 1; }
fi
c=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H 'ngrok-skip-browser-warning: 1' "https://$DOMAIN/api/restaurants")
[ "$c" = 200 ] && echo "phone URL OK: https://$DOMAIN (HTTP 200)" || echo "phone URL https://$DOMAIN returned HTTP $c — give it a few seconds and run check.sh"

# 3. web demo (optional)
if [ "$WEB" = 1 ]; then
  if pgrep -f 'uvicorn web.app:app' >/dev/null; then echo "web demo: already running on :8010"; else
    nohup .venv/bin/uvicorn web.app:app --host 0.0.0.0 --port 8010 >"$LOGS/web.log" 2>&1 &
    wait_for http://127.0.0.1:8010/api/state 60 && echo "web demo: started on 0.0.0.0:8010" || echo "web demo: FAILED — tail $LOGS/web.log"
  fi
  echo "web demo: dashboard http://$(ipconfig getifaddr en0):8010 — ngrok's free plan can't tunnel a second port; phones on the same Wi-Fi use that LAN URL"
fi
