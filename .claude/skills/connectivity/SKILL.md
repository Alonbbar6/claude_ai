---
name: connectivity
description: Diagnose and fix how the Mini Eats / Eats Merchant iPhone apps and the web demo reach their backends — the FastAPI server on :8000, the ngrok tunnel and its static domain, the Mac's LAN/hotspot IP, the BarMade API on Render, and the web demo on :8010. Use this whenever the phone shows "Can't reach the server", "Server returned 404", a blank restaurant list, the QR menu won't load on phones, the dashboard says "BarMade unreachable", or the user mentions ngrok, tunnel, hotspot, LAN IP, server URL, or "the app can't connect" — even if they just paste a screenshot of the error.
---

# Connectivity: phone ↔ Mac ↔ backends

Everything the apps talk to, and the one thing that usually breaks:

```
iPhone (Mini Eats / Eats Merchant)
   │  MINIEATS_SERVER_URL (baked at build, or Account → Server)
   ▼
https://<static>.ngrok-free.dev  ──ngrok agent on the Mac──▶  uvicorn app.main:app  :8000
   (if ngrok is NOT running, ngrok answers an HTML "endpoint offline"
    page; the app reports it as "Server returned 404")

iPhone (BarMade mode) ──▶ https://barmade-riw5.onrender.com   (Render free tier: ~50 s cold start)
Web demo (dashboard)  ──▶ uvicorn web.app:app :8010 ──reads──▶ BarMade API
```

## Do this first

Run the checker; it prints PASS/FAIL per link with the fix for each failure:

```bash
bash .claude/skills/connectivity/scripts/check.sh
```

Then bring up whatever is missing (safe to re-run; it skips things already running):

```bash
bash .claude/skills/connectivity/scripts/up.sh          # backend :8000 + ngrok tunnel
bash .claude/skills/connectivity/scripts/up.sh --web    # also the web demo on :8010
```

Re-run `check.sh` afterwards and tell the user which URL to use on the phone. The app
needs a **Retry** tap or a relaunch after the tunnel comes up; nothing on the phone needs
reinstalling when only the tunnel was down.

## Reading the symptoms

| Phone / dashboard says | Real cause | Fix |
|---|---|---|
| "Server returned 404", server = `…ngrok-free.dev` | ngrok agent not running (domain shows ngrok's offline page) | `up.sh` |
| "Server returned 502/503" via ngrok | tunnel up, backend on :8000 down | `up.sh` |
| Timeout / "could not connect", server = `http://172.20.10.x:8000` or `192.168.x.x` | Mac's IP changed (hotspot vs Wi-Fi), or uvicorn bound to 127.0.0.1 | use the ngrok URL, or set Account → Server to the IP `check.sh` prints; backend must run with `--host 0.0.0.0` |
| Server = `127.0.0.1` / `localhost` on a real phone | points at the phone itself; app ignores it and falls back to the built-in default | set a real URL in Account / Settings |
| "BarMade unreachable" / app spinner for ~1 min | Render cold start, or the old `barmade-api` host (gone) | wait a minute; default is `barmade-riw5.onrender.com` |
| QR menu doesn't open on participants' phones | they can't reach `127.0.0.1:8010`; the dashboard QR encodes whatever host it was opened on | open the dashboard through a public URL (`up.sh --web` prints an ngrok URL only if a second domain is configured; otherwise share the LAN IP) |

## Facts that cost us time before

- The ngrok **free plan allows one tunnel at a time** per agent. Starting a second one for :8010 kills the first unless the account has a second static domain. `up.sh --web` warns instead of trying.
- `ngrok` must be started with `--domain=<the static domain from ios/project.yml>`; a bare `ngrok http 8000` gives a random URL the phone doesn't know.
- The phone drops a saved `localhost`/`127.0.0.1` server on purpose (`usableServerURL` in `ios/MiniEats/APIClient.swift`); only the Simulator accepts those.
- On the Personal Hotspot the Mac is 172.20.10.x and the gateway is 172.20.10.1; on home Wi-Fi it's 192.168.x.x. Any saved IP goes stale when the network changes — the ngrok domain doesn't.
- Build output under `~/Desktop` (iCloud-synced) breaks codesign; that's a build problem, not connectivity — see the iOS build guide.
- Requests to ngrok's free domains need the header `ngrok-skip-browser-warning: 1`; the apps already send it. When testing with curl, add it or you get an HTML interstitial.

## When nothing above matches

Collect, in this order, and reason from the first failure: `check.sh` output → `tail ~/Library/Logs/minieats/ngrok.log` → `tail ~/Library/Logs/minieats/backend.log` → the exact text on the phone's error screen (it shows the server URL it used).
