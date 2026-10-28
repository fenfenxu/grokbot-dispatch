#!/usr/bin/env bash
# Shared helpers for grokbot-dispatch scripts. Source, do not execute.

gbd_config_dir() {
  printf '%s' "${GROKBOT_DISPATCH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/grokbot-dispatch}"
}

gbd_config_file() {
  printf '%s/bots.json' "$(gbd_config_dir)"
}

gbd_need() {
  command -v "$1" >/dev/null 2>&1 || { echo "grokbot-dispatch: missing required command: $1" >&2; exit 1; }
}

