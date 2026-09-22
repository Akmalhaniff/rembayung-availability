#!/bin/bash
set -e
# clone with PAT (provided via secret GH_PAT)
if [ -n "$GH_PAT" ]; then
  git clone https://$GH_PAT@github.com/Akmalhaniff/rembayung-availability.git /tmp/repo 2>/dev/null || true
  cp -r /tmp/repo/.git /app/.git 2>/dev/null || true
  git remote set-url origin https://$GH_PAT@github.com/Akmalhaniff/rembayung-availability.git 2>/dev/null || true
fi
while true; do
  pwsh ./fetch-availability.ps1 -Days 14 -PartySize 3 >> /tmp/cron.log 2>&1 || curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage?chat_id=$TELEGRAM_CHAT_ID&text=FLY_FETCH_FAILED" > /dev/null
  git add availability.json opened.json 2>/dev/null || git add availability.json
  if ! git diff --cached --quiet; then
    git commit -m "data $(date -u +%Y-%m-%dT%H:%M:%SZ) [skip netlify]" >> /tmp/cron.log 2>&1
    git push >> /tmp/cron.log 2>&1
  fi
  sleep 300
done
