#!/usr/bin/env bash
set -euo pipefail

echo "========================================"
echo " laliga-cloudflare-toggle"
echo "========================================"
echo " Interval:  ${CHECK_INTERVAL:-300}s"
echo " Domains:   $(echo "${DOMAINS:-none}" | tr ',' '\n' | cut -d: -f2 | tr '\n' ' ')"
echo " DRY_RUN:   ${DRY_RUN:-false}"
echo " Telegram:  $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo "on" || echo "off")"
echo " Timeout:   ${MAX_DISABLED_HOURS:-12}h"
echo "========================================"

while true; do
    /app/toggle-proxy.sh || true
    sleep "${CHECK_INTERVAL:-300}"
done
