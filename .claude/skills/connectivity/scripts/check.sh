#!/usr/bin/env bash
# Diagnose phone <-> Mac <-> backend connectivity for Mini Eats. Read-only.
# Prints PASS/FAIL per link with a fix hint. Exit code = number of failures.
set -u
cd "$(dirname "$0")/../../../.." || exit 2   # repo root (claude_ai/)

DOMAIN=${NGROK_DOMAIN:-$(grep -E '^\s*MINIEATS_SERVER_URL:' ios/project.yml | head -1 | sed -E 's/.*https?:\/\///; s/\s*$//')}
BARMADE=${BARMADE_URL:-https://barmade-riw5.onrender.com}
fails=0
pass() { printf '\033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m %s\n     fix: %s\n' "$1" "$2"; fails=$((fails+1)); }
code() { curl -s -m "${2:-5}" -o /dev/null -w '%{http_code}' -H 'ngrok-skip-browser-warning: 1' "$1" 2>/dev/null || echo 000; }

echo "== Mac network"
IP=$(ipconfig getifaddr en0 2>/dev/null || true)
GW=$(ipconfig getoption en0 router 2>/dev/null || true)
if [ -n "$IP" ]; then
  if [ "$GW" = "172.20.10.1" ]; then pass "Wi-Fi up via iPhone Personal Hotspot, Mac IP $IP"; else pass "Wi-Fi up, Mac IP $IP (gateway ${GW:-?})"; fi
else
  fail "no Wi-Fi address on en0" "join a Wi-Fi network or the iPhone's Personal Hotspot"
fi

echo "== Backend (uvicorn app.main:app on :8000)"
if pgrep -f 'uvicorn app.main:app' >/dev/null; then
  c=$(code http://127.0.0.1:8000/api/restaurants)
  if [ "$c" = 200 ]; then pass "backend answers locally (HTTP $c)"; else fail "backend process exists but /api/restaurants returned $c" "tail ~/Library/Logs/minieats/backend.log; restart with scripts/up.sh"; fi
  if pgrep -f 'uvicorn app.main:app' | xargs -I{} ps -o args= -p {} | grep -q -- '--host 0.0.0.0'; then
    pass "backend bound to 0.0.0.0 (reachable from the phone over LAN)"
  else
    fail "backend bound to localhost only" "restart with --host 0.0.0.0 (scripts/up.sh does this)"
  fi
else
  fail "backend not running" "scripts/up.sh"
fi

echo "== ngrok tunnel ($DOMAIN)"
if [ -z "$DOMAIN" ]; then
  fail "no static domain found in ios/project.yml (MINIEATS_SERVER_URL)" "set NGROK_DOMAIN=<domain> or fix project.yml"
elif pgrep -x ngrok >/dev/null; then
  pub=$(curl -s -m 3 http://127.0.0.1:4040/api/tunnels | grep -o '"public_url":"[^"]*' | head -1 | cut -d'"' -f4)
  if [ -n "$pub" ]; then pass "ngrok agent running, public URL $pub"; else fail "ngrok process exists but has no tunnel" "tail ~/Library/Logs/minieats/ngrok.log; restart via scripts/up.sh"; fi
else
  fail "ngrok agent not running" "scripts/up.sh"
fi
if [ -n "$DOMAIN" ]; then
  c=$(code "https://$DOMAIN/api/restaurants" 15)
  case "$c" in
    200) pass "phone-facing URL https://$DOMAIN serves the API (HTTP 200)";;
    404) fail "https://$DOMAIN returns 404 = ngrok 'endpoint offline' (this is what the phone shows)" "scripts/up.sh";;
    502|503) fail "tunnel is up but nothing answers on :8000 (HTTP $c)" "scripts/up.sh";;
    *) fail "https://$DOMAIN returned HTTP $c" "check internet access and the ngrok log";;
  esac
fi

echo "== BarMade API ($BARMADE)"
c=$(code "$BARMADE/" 60)
if [ "$c" = 200 ]; then pass "BarMade reachable"; else fail "BarMade returned HTTP $c" "Render cold start takes ~50 s; retry. 404 with x-render-routing: no-server means the host moved"; fi

echo "== Web demo (:8010)"
if pgrep -f 'uvicorn web.app:app' >/dev/null; then pass "web demo running at http://127.0.0.1:8010 (phones: http://$IP:8010)"; else printf 'skip web demo not running (scripts/up.sh --web)\n'; fi

echo
if [ "$fails" = 0 ]; then
  echo "All good. Phone server URL: https://$DOMAIN   (LAN alternative: http://$IP:8000)"
else
  echo "$fails problem(s). Run: bash .claude/skills/connectivity/scripts/up.sh"
fi
exit "$fails"
