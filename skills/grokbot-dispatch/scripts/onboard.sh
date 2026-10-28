#!/usr/bin/env bash
# Print the ready-to-paste Grok Bot prompt + the step-by-step setup guide.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/../references/bot-prompt.md"
[ -r "$PROMPT_FILE" ] || { echo "onboard.sh: missing $PROMPT_FILE" >&2; exit 1; }

COPIED=""
for c in "pbcopy" "wl-copy" "xclip -selection clipboard" "xsel --clipboard --input" "clip.exe"; do
  bin="${c%% *}"
  if command -v "$bin" >/dev/null 2>&1; then
    if $c <"$PROMPT_FILE" >/dev/null 2>&1; then COPIED="$bin"; break; fi
  fi
done

cat <<EOF2
==================== Grok Bot 接入步骤 / Onboarding ====================

第 1 步：把下面「PROMPT 开始/结束」之间的整段话，粘贴到你的 Grok Bot 聊天里发送。
         (Step 1: paste everything between the PROMPT markers into your Grok Bot chat.)
         ${COPIED:+已复制到剪贴板（$COPIED）/ copied to clipboard.}

----------------------------- PROMPT 开始 -----------------------------
EOF2
cat "$PROMPT_FILE"
cat <<EOF2
----------------------------- PROMPT 结束 -----------------------------

第 2 步：Bot 创建好 routine 后，在 Grok Bot 里：
         点聊天顶部 bot 的名字（或按 Cmd+Shift+I）→ Routines 列表 → 打开 "from-agents dispatch"
         → 复制 webhook URL 和 sender key。
         (Step 2: click the bot name in the chat header or press Cmd+Shift+I, open Routines,
          open "from-agents dispatch", copy the webhook URL and sender key.)

第 3 步：在你自己的终端（不是和 AI 的聊天里）运行，key 是隐藏输入：
         (Step 3: run in YOUR terminal, not in the AI chat; the key prompt is hidden.)

   $SCRIPT_DIR/setup.sh --name <bot名字> --url <粘贴webhook URL> --default
   # 多个 bot 时，再加一个总调度 bot：  --dispatcher
   # 仅这一条命令用环境变量传 key：     GROKBOT_KEY=... setup.sh ...  （不要把 key 贴给 AI）

第 4 步：回到编码 agent，说一次「发给 Grok Bot：ping」验证。
         (Step 4: tell your coding agent "send ping to my Grok Bot" to verify.)

注意：sender key 不要贴进和任何 AI 的聊天里。/ Never paste the sender key into any AI chat.
========================================================================
EOF2
