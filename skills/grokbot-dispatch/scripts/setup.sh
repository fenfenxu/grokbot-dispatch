#!/usr/bin/env bash
# Register / list / remove Grok Bot webhooks for grokbot-dispatch.
#
#   setup.sh --name NAME --url URL [--default] [--dispatcher]   (key via hidden prompt or $GROKBOT_KEY)
#   setup.sh --list
#   setup.sh --remove NAME
#
# The key is never echoed and never taken from argv. Config: ~/.config/grokbot-dispatch/bots.json (600, dir 700).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"
gbd_need python3

usage() {
  cat <<'USAGE'
Usage:
  setup.sh --name NAME --url URL [--default] [--dispatcher]
      Register a Grok Bot webhook. The sender key is read from a hidden prompt,
      or from env GROKBOT_KEY. Never pass the key as an argument.
  setup.sh --list              Show configured bots (keys are never printed)
  setup.sh --remove NAME       Remove a bot
Flags:
  --default      make this bot the default target (the first bot added is default automatically)
  --dispatcher   mark this bot as the dispatcher (it forwards to teammate bots by --to NAME)
Env overrides at send time: GROKBOT_WEBHOOK_URL / GROKBOT_WEBHOOK_KEY (act as a bot named "env").
USAGE
}

NAME="" URL="" DO_DEFAULT=0 DO_DISPATCHER=0 DO_LIST=0 REMOVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --default) DO_DEFAULT=1; shift ;;
    --dispatcher) DO_DISPATCHER=1; shift ;;
    --list) DO_LIST=1; shift ;;
    --remove) REMOVE="${2:-}"; shift 2 ;;
    --key|--key=*) echo "setup.sh: refusing a key on the command line (it would land in shell history / ps). Use the hidden prompt or env GROKBOT_KEY." >&2; exit 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "setup.sh: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

CFG_DIR="$(gbd_config_dir)"
CFG_FILE="$(gbd_config_file)"
export CFG_DIR CFG_FILE

if [ "$DO_LIST" = 1 ]; then
  python3 - <<'PY'
import json, os, sys
from urllib.parse import urlsplit
f = os.environ["CFG_FILE"]
cfg = {}
if os.path.exists(f):
    try: cfg = json.load(open(f))
    except Exception as e:
        print(f"config unreadable: {f}: {e}"); sys.exit(1)
bots = cfg.get("bots", {})
if os.environ.get("GROKBOT_WEBHOOK_URL") and os.environ.get("GROKBOT_WEBHOOK_KEY"):
    h = urlsplit(os.environ["GROKBOT_WEBHOOK_URL"]).netloc
    print(f"env  (from GROKBOT_WEBHOOK_URL/KEY)  host={h}  key=set")
if not bots:
    print(f"NOT_CONFIGURED: no bots in {f}")
    sys.exit(0)
for n, b in bots.items():
    tags = []
    if cfg.get("default") == n: tags.append("default")
    if cfg.get("dispatcher") == n: tags.append("dispatcher")
    h = urlsplit(b.get("url", "")).netloc
    k = "set" if b.get("key") else "MISSING"
    print(f"{n}  host={h}  key={k}  [{', '.join(tags)}]")
PY
  exit 0
fi

if [ -n "$REMOVE" ]; then
  NAME="$REMOVE" python3 - <<'PY'
import json, os, sys
f, n = os.environ["CFG_FILE"], os.environ["NAME"]
if not os.path.exists(f): print("nothing configured"); sys.exit(1)
cfg = json.load(open(f))
if n not in cfg.get("bots", {}): print(f"no such bot: {n}"); sys.exit(1)
del cfg["bots"][n]
for k in ("default", "dispatcher"):
    if cfg.get(k) == n: cfg.pop(k)
if "default" not in cfg and cfg["bots"]: cfg["default"] = next(iter(cfg["bots"]))
tmp = f + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh: json.dump(cfg, fh, indent=2)
os.replace(tmp, f); os.chmod(f, 0o600)
print(f"removed {n}")
PY
  exit 0
fi

[ -n "$NAME" ] && [ -n "$URL" ] || { usage >&2; exit 1; }
[[ "$NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "setup.sh: --name must match [A-Za-z0-9_.-]+" >&2; exit 1; }
case "$URL" in
  https://*|http://localhost*|http://127.0.0.1*) ;;
  *) echo "setup.sh: --url must be https:// (copy it from the routine panel)" >&2; exit 1 ;;
esac

KEY="${GROKBOT_KEY:-}"
if [ -z "$KEY" ]; then
  if ! [ -t 0 ] && ! { : </dev/tty; } 2>/dev/null; then
    echo "setup.sh: no terminal for the hidden key prompt. Run this in your own terminal, or set GROKBOT_KEY for this one command." >&2
    exit 1
  fi
  if [ -t 0 ]; then
    printf 'Sender key for "%s" (input hidden): ' "$NAME" >&2
    IFS= read -r -s KEY; echo >&2
  else
    printf 'Sender key for "%s" (input hidden): ' "$NAME" >/dev/tty
    IFS= read -r -s KEY </dev/tty; echo >/dev/tty
  fi
fi
KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
[ -n "$KEY" ] || { echo "setup.sh: empty key, nothing saved" >&2; exit 1; }
case "$KEY" in *\"*|*\\*) echo "setup.sh: key contains a quote or backslash; that is not a valid sender key, nothing saved" >&2; exit 1 ;; esac

umask 077
mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR"
NAME="$NAME" URL="$URL" DO_DEFAULT="$DO_DEFAULT" DO_DISPATCHER="$DO_DISPATCHER" GBD_KEY="$KEY" python3 - <<'PY'
import json, os
f = os.environ["CFG_FILE"]
cfg = json.load(open(f)) if os.path.exists(f) else {}
cfg.setdefault("bots", {})
n = os.environ["NAME"]
cfg["bots"][n] = {"url": os.environ["URL"], "key": os.environ["GBD_KEY"]}
if os.environ["DO_DEFAULT"] == "1" or "default" not in cfg: cfg["default"] = n
if os.environ["DO_DISPATCHER"] == "1": cfg["dispatcher"] = n
tmp = f + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh: json.dump(cfg, fh, indent=2)
os.replace(tmp, f); os.chmod(f, 0o600)
tags = [t for t in ("default", "dispatcher") if cfg.get(t) == n]
print(f"saved bot '{n}' {tags if tags else ''} -> {f} (key stored, not shown)")
PY
