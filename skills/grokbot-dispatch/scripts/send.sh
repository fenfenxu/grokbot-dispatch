#!/usr/bin/env bash
# Send a task to a Grok Bot webhook routine. One try, no retry.
#
#   send.sh [--bot NAME] [--to TARGET] --task "..." [--context-file PATH|-] [--dry-run]
#
# Exit codes: 0 sent (HTTP 2xx) | 2 not configured | 1 failure
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"
gbd_need python3

BOT="" TO="" TASK="" CONTEXT_FILE="" DRY=0
usage() {
  cat <<'USAGE'
Usage: send.sh [--bot NAME] [--to TARGET] --task "..." [--context-file PATH|-] [--dry-run]
  --bot NAME            which configured webhook to use (default: the configured default bot)
  --to TARGET           target Grok Bot teammate; the receiving bot routes it (dispatcher mode)
  --task TEXT           what the Grok Bot should do (use "ping" to test)
  --context-file PATH   useful context (JSON or plain text); "-" reads stdin
  --dry-run             print the JSON body and the resolved bot, send nothing
Target resolution when --bot is omitted: --to names a configured bot -> that bot (direct);
otherwise the dispatcher bot with target=--to; otherwise the default bot.
Exit codes: 0 sent (HTTP 2xx), 2 not configured, 1 failure.
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --bot) BOT="${2:-}"; shift 2 ;;
    --to) TO="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --context-file) CONTEXT_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "send.sh: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
TO="${TO#@}"; BOT="${BOT#@}"
[ -n "$TASK" ] || { echo "send.sh: --task is required (use \"ping\" to test)" >&2; usage >&2; exit 1; }

CFG_FILE="$(gbd_config_file)"
export CFG_FILE BOT TO

# ---- resolve bot -> NUL-separated: name, url, key, target, reason ---------------------------
set +e
RESOLVED_FILE="$(mktemp)"; trap 'rm -f "$RESOLVED_FILE" "${BODY_FILE:-}"' EXIT
python3 - >"$RESOLVED_FILE" <<'PY'
import json, os, sys
f = os.environ["CFG_FILE"]
bot, to = os.environ.get("BOT", ""), os.environ.get("TO", "")
cfg = {}
if os.path.exists(f):
    try: cfg = json.load(open(f))
    except Exception as e:
        sys.stderr.write(f"send.sh: config unreadable ({f}): {e}\n"); sys.exit(1)
bots = dict(cfg.get("bots", {}))
eu, ek = os.environ.get("GROKBOT_WEBHOOK_URL"), os.environ.get("GROKBOT_WEBHOOK_KEY")
if eu and ek and "env" not in bots:
    bots["env"] = {"url": eu, "key": ek}
default = cfg.get("default") or ("env" if "env" in bots else None)
disp = cfg.get("dispatcher")
if not bots:
    sys.exit(2)
target, reason = to, ""
if bot:
    if bot not in bots:
        sys.stderr.write(f"send.sh: bot '{bot}' is not configured (have: {', '.join(bots)})\n"); sys.exit(2)
    name, reason = bot, "--bot"
elif to and to in bots:
    name, target, reason = to, "", "--to matches a configured bot (direct)"
elif to and disp and disp in bots:
    name, reason = disp, "dispatcher routes --to"
elif default and default in bots:
    name, reason = default, "default bot" + (" routes --to" if to else "")
else:
    sys.stderr.write("send.sh: no default bot configured\n"); sys.exit(2)
b = bots[name]
if not b.get("url") or not b.get("key"):
    sys.stderr.write(f"send.sh: bot '{name}' has no url/key\n"); sys.exit(2)
sys.stdout.write("\0".join([name, b["url"], b["key"], target, reason]) + "\0")
PY
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  if [ "$RC" -eq 2 ]; then
    echo "NOT_CONFIGURED: no usable Grok Bot webhook. Run: $SCRIPT_DIR/onboard.sh" >&2
  fi
  # still show the body in dry-run so the payload can be inspected
  [ "$DRY" = 1 ] && [ "$RC" -eq 2 ] || exit "$RC"
  BOT_NAME="(unconfigured)"; URL=""; KEY=""; TARGET="$TO"; REASON="not configured"
else
  mapfile -d '' -t R <"$RESOLVED_FILE"
  BOT_NAME="${R[0]}"; URL="${R[1]}"; KEY="${R[2]}"; TARGET="${R[3]}"; REASON="${R[4]}"
fi

# ---- build body ---------------------------------------------------------------------------
BODY_FILE="$(mktemp)"
CTX_RAW=""
if [ -n "$CONTEXT_FILE" ]; then
  if [ "$CONTEXT_FILE" = "-" ]; then CTX_RAW="$(cat)"
  elif [ -r "$CONTEXT_FILE" ]; then CTX_RAW="$(cat "$CONTEXT_FILE")"
  else echo "send.sh: cannot read context file: $CONTEXT_FILE" >&2; exit 1; fi
fi
GIT_REMOTE="" GIT_BRANCH="" GIT_SHA=""
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_REMOTE="$(git remote get-url origin 2>/dev/null || true)"
  GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
fi
AGENT="${GROKBOT_SENDER_AGENT:-}"
if [ -z "$AGENT" ]; then
  if   env | grep -q '^CODEX_'; then AGENT="codex-cli"
  elif [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then AGENT="claude-code"
  elif env | grep -q '^CURSOR_'; then AGENT="cursor"
  elif env | grep -q '^OPENCLAW_'; then AGENT="openclaw"
  elif [ -n "${GEMINI_CLI:-}" ]; then AGENT="gemini-cli"
  else AGENT="unknown"; fi
fi
export TASK TARGET CTX_RAW GIT_REMOTE GIT_BRANCH GIT_SHA AGENT BODY_FILE
export MODEL="${GROKBOT_SENDER_MODEL:-}"
OS_INFO="$(uname -srm 2>/dev/null || true)"
HOST_NAME="$(hostname 2>/dev/null || uname -n)"
USER_NAME="${USER:-$(id -un 2>/dev/null || true)}"
export OS_INFO HOST_NAME USER_NAME
export CWD_PATH="$PWD"

REQUEST_ID="$(python3 - <<'PY'
import json, os, re, uuid, datetime
from urllib.parse import urlsplit, urlunsplit
e = os.environ
def clean_remote(u):
    try:
        p = urlsplit(u)
        if p.username or p.password:
            host = p.hostname + (f":{p.port}" if p.port else "")
            return urlunsplit((p.scheme, host, p.path, p.query, p.fragment))
    except Exception: pass
    return u
SECRET = [
    (re.compile(r"(?i)(authorization:\s*bearer\s+)[^\s\"']+"), r"\1[REDACTED]"),
    (re.compile(r"\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,})\b"), "[REDACTED]"),
    (re.compile(r"(?i)\b((?:api[_-]?key|secret|token|password|passwd|sender[_-]?key)\s*[=:]\s*)[^\s\"',]{6,}"), r"\1[REDACTED]"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[REDACTED PRIVATE KEY]"),
]
def scrub(s):
    for rx, rep in SECRET: s = rx.sub(rep, s)
    return s
MAX = 16000
ctx = e.get("CTX_RAW", "")
truncated = False
if ctx:
    ctx = scrub(ctx)
    if len(ctx) > MAX: ctx, truncated = ctx[:MAX], True
context = None
if ctx:
    try:
        context = json.loads(ctx) if not truncated else ctx
    except Exception:
        context = ctx
    if truncated: context = {"_truncated": True, "text": ctx}
rid = str(uuid.uuid4())
sender = {
    "agent": e.get("AGENT") or "unknown",
    "model": e.get("MODEL") or None,
    "os": e.get("OS_INFO") or None,
    "hostname": e.get("HOST_NAME") or None,
    "user": e.get("USER_NAME") or None,
    "cwd": e.get("CWD_PATH") or None,
    "git": ({"remote": clean_remote(e["GIT_REMOTE"]) if e.get("GIT_REMOTE") else None,
             "branch": e.get("GIT_BRANCH") or None, "head": e.get("GIT_SHA") or None}
            if e.get("GIT_BRANCH") or e.get("GIT_REMOTE") else None),
}
body = {
    "request_id": rid,
    "task": scrub(e["TASK"]),
    "target": e.get("TARGET") or "",
    "sender": sender,
    "context": context,
    "sent_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(e["BODY_FILE"], "w") as fh: json.dump(body, fh, ensure_ascii=False, indent=2)
print(rid)
PY
)"

if [ "$DRY" = 1 ]; then
  HOST_ONLY="$(printf '%s' "$URL" | sed -E 's#^[a-z]+://([^/]+).*#\1#')"
  echo "DRY-RUN (nothing sent)"
  echo "bot:     $BOT_NAME ($REASON)"
  echo "webhook: ${HOST_ONLY:-<none>}  (path and key hidden)"
  echo "request_id: $REQUEST_ID"
  echo "body:"
  cat "$BODY_FILE"; echo
  [ -n "$URL" ] || exit 2
  exit 0
fi

# ---- send: one try, no retry. Key goes to curl via stdin config, never argv. ----------------
RESP_FILE="$(mktemp)"; trap 'rm -f "$RESOLVED_FILE" "$BODY_FILE" "$RESP_FILE"' EXIT
echo "request_id: $REQUEST_ID"
set +e
HTTP_CODE="$(
  printf 'url = "%s"\nheader = "Content-Type: application/json"\nheader = "Authorization: Bearer %s"\nheader = "X-Automation-Key: %s"\n' "$URL" "$KEY" "$KEY" |
  curl -sS -K - -X POST --data-binary "@$BODY_FILE" --max-time 8 --connect-timeout 8 \
       -o "$RESP_FILE" -w '%{http_code}' 2>"$RESP_FILE.err"
)"
CURL_RC=$?
set -e
if [ -n "${GROKBOT_DISPATCH_SENT_LOG:-}" ]; then
  # optional audit log: the exact body that was sent (never the key) + result
  { python3 -c 'import json,sys; print(json.dumps({"http": sys.argv[1], "curl_rc": int(sys.argv[2]), "bot": sys.argv[3], "body": json.load(open(sys.argv[4]))}, ensure_ascii=False))' \
      "${HTTP_CODE:-}" "$CURL_RC" "$BOT_NAME" "$BODY_FILE" >>"$GROKBOT_DISPATCH_SENT_LOG"; } 2>/dev/null || true
fi
if [ "$CURL_RC" -ne 0 ]; then
  echo "FAILED: curl exit $CURL_RC ($(head -c 200 "$RESP_FILE.err" 2>/dev/null | sed "s#$URL#<url>#g")). Not retried." >&2
  rm -f "$RESP_FILE.err"; exit 1
fi
rm -f "$RESP_FILE.err"
case "$HTTP_CODE" in
  2??)
    echo "sent: HTTP $HTTP_CODE -> bot '$BOT_NAME'. The routine was woken; the task is NOT necessarily finished. The Grok Bot will report in its own chat (look for request_id $REQUEST_ID)."
    exit 0 ;;
  *)
    echo "FAILED: HTTP $HTTP_CODE from bot '$BOT_NAME'. Not retried. Response: $(head -c 300 "$RESP_FILE" | tr '\n' ' ')" >&2
    [ "$HTTP_CODE" = 401 ] || [ "$HTTP_CODE" = 403 ] && echo "Hint: the sender key may be wrong or rotated; re-run setup.sh for this bot." >&2
    exit 1 ;;
esac
