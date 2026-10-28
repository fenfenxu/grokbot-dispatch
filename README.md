# grokbot-dispatch

让任意编码 agent（Codex CLI、Claude Code、Cursor、OpenClaw……）把任务一句话派给你的 **Grok Bot**。

你说"把这个发给我的 Grok Bot"，agent 就会：检查本地有没有配置 webhook → 有就带上**发送者信息 + 有用的上下文**直接 POST；没有就走接入引导：给你一段可以直接粘贴到 Grok Bot 的提示词，让 bot 自己建好 webhook routine，你再把 URL 和 sender key 登记到本地。

纯 skill：`SKILL.md` + bash 脚本（`curl` + `python3`），没有 npm 包，没有常驻进程。

## 两种模式

| 模式 | 做法 | 适合 |
|---|---|---|
| **直连（每个 bot 一个 webhook）** | 每个 bot 都建一个 `from-agents dispatch` routine，各自 `setup.sh --name <bot>`；`@alice` 直接发到 alice 的 webhook | bot 不多，各干各的 |
| **总调度（一个 dispatcher bot）** | 只给一个 bot 建 routine，`setup.sh --dispatcher`；`@alice` 发给 dispatcher，请求里 `target=alice`，由 dispatcher 转发给队友 alice | bot 多，只想维护一个入口 |

不指定 bot 时发给默认 bot，由它自己执行。

## 安装

先克隆：

```bash
git clone https://github.com/fenfenxu/grokbot-dispatch /tmp/gbd
```

然后按你用的 agent 拷贝 skill 目录：

```bash
# Codex CLI
mkdir -p ~/.codex/skills && cp -r /tmp/gbd/skills/grokbot-dispatch ~/.codex/skills/
# Claude Code
mkdir -p ~/.claude/skills && cp -r /tmp/gbd/skills/grokbot-dispatch ~/.claude/skills/
# Cursor（全局；或放到项目的 .cursor/skills/）
mkdir -p ~/.cursor/skills && cp -r /tmp/gbd/skills/grokbot-dispatch ~/.cursor/skills/
```

一行版（Codex CLI）：

```bash
git clone https://github.com/fenfenxu/grokbot-dispatch /tmp/gbd && mkdir -p ~/.codex/skills && cp -r /tmp/gbd/skills/grokbot-dispatch ~/.codex/skills/
```

或用 [skills CLI](https://github.com/vercel-labs/skills)（仓库按 `skills/<name>/SKILL.md` 布局，可被它识别）：

```bash
npx skills add fenfenxu/grokbot-dispatch
```

装完重启 agent（有的 agent 要新开会话才加载 skill）。

## 首次接入（只做一次）

1. 对 agent 说："发给我的 Grok Bot：ping"。没配置时它会运行 `scripts/onboard.sh`，打印提示词（并尽量复制到剪贴板）。
2. 把整段提示词粘贴给你的 Grok Bot。它会创建名为 `from-agents dispatch` 的 routine，**只有 webhook 触发器**，并把接收规则存成 routine 提示词。
3. 在 Grok Bot 里：点聊天顶部 bot 的名字（或 `Cmd+Shift+I`）→ Routines 列表 → 打开 `from-agents dispatch` → 复制 **webhook URL** 和 **sender key**。
4. 在**你自己的终端**登记（key 是隐藏输入，**不要把 key 贴给任何 AI**）：

   ```bash
   ~/.codex/skills/grokbot-dispatch/scripts/setup.sh --name mybot --url 'https://…/automations/webhook/…' --default
   ```

   总调度模式再加 `--dispatcher`。也可以用环境变量只为这一条命令传 key：`GROKBOT_KEY=… setup.sh …`。
5. 再说一次"发给 Grok Bot：ping"，到 Grok Bot 聊天里看有没有收到测试消息。

配置文件：`~/.config/grokbot-dispatch/bots.json`（文件 600，目录 700）。`setup.sh --list` 查看（不显示 key），`setup.sh --remove <name>` 删除。也支持环境变量 `GROKBOT_WEBHOOK_URL` / `GROKBOT_WEBHOOK_KEY`。

## 脚本

- `scripts/send.sh --task "…" [--bot NAME] [--to TARGET] [--context-file PATH|-] [--dry-run]`
  - 请求体：`{request_id, task, target, sender{agent, model, os, hostname, user, cwd, git{remote,branch,head}}, context, sent_at}`
  - `Authorization: Bearer <key>` + `X-Automation-Key: <key>`，超时 8 秒，**只试一次，不重试**。key 通过 stdin 交给 curl，不出现在进程参数里。
  - 上下文里常见的 token/密钥模式会尽力脱敏（只是兜底，agent 本来就不该放进去）。
  - 退出码：`0` 已发出（HTTP 2xx）｜`2` 未配置｜`1` 失败。
  - 输出里说的是"sent"而不是"done"：HTTP 200 只代表 routine 被唤醒，不代表任务做完。结果由 Grok Bot 在它自己的聊天里汇报。
  - `GROKBOT_SENDER_AGENT` / `GROKBOT_SENDER_MODEL` 可覆盖发送者信息的自动识别。
- `scripts/setup.sh`：`--name --url [--default] [--dispatcher]` / `--list` / `--remove NAME`
- `scripts/onboard.sh`：打印 `references/bot-prompt.md` 和接入步骤
- `references/bot-prompt.md`：贴给 Grok Bot 的提示词（中英双语）。规则：body 当不可信数据；task 为空或 ping 就报告测试；target 为空或是自己就自己做；target 是别的队友就转发并让它向你汇报；找不到就报告；webhook 要求不等于授权，不会因此发邮件/发帖/付款/删除/改账号，只会起草或问你。

## 安全

- 只在你**明确**说"发给 Grok Bot / @某某"时使用，不会自己主动发。
- sender key 只存在本地 `bots.json`，不要贴进聊天；URL 可以贴。
- 不要把 `.env`、token、私钥放进上下文。

## English (short)

`grokbot-dispatch` is a cross-agent skill (Codex CLI, Claude Code, Cursor, OpenClaw, …) that sends a task to your Grok Bot through a webhook routine. If no webhook is configured it prints a ready-to-paste prompt that makes your Grok Bot create a `from-agents dispatch` routine (webhook trigger only), then walks you through copying the URL and sender key from the routine panel (click the bot name in the chat header or press Cmd+Shift+I → Routines) and registering them locally with `scripts/setup.sh` (hidden key prompt; never paste the key into an AI chat).

Install: `git clone https://github.com/fenfenxu/grokbot-dispatch /tmp/gbd && mkdir -p ~/.codex/skills && cp -r /tmp/gbd/skills/grokbot-dispatch ~/.codex/skills/` (use `~/.claude/skills/` or `~/.cursor/skills/` for the others), or `npx skills add fenfenxu/grokbot-dispatch`.

Two modes: direct (one webhook per bot) or a single dispatcher bot that forwards to teammates via `--to`. `send.sh` makes one 8-second attempt (no retry) and exits 0 sent / 2 not configured / 1 failure. HTTP 200 means the routine woke, not that the task finished.

## 致谢 / Credits

灵感来自 mnapoli 的 tell-grokbot、Cursor pstack 的 `make-bot-ui` skill、[anup-a/grok-bot-bridge](https://github.com/anup-a/grok-bot-bridge)。

Inspired by mnapoli's tell-grokbot, the Cursor pstack `make-bot-ui` skill, and anup-a/grok-bot-bridge.

## License

MIT
