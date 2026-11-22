#!/usr/bin/env bash
# Run from the PC: bash server/deploy.sh
# Copies the relay to the box and rebuilds only its own container. Queued commands are lost
# (state is in memory); the PC watcher re-sends its snapshot within seconds.
# First run makes a random token, keeps it in ~/.claude-watch/token on the PC and
# /opt/claudewatch/.env on the box. Enter the same token in the watch app's Settings.
set -euo pipefail
cd "$(dirname "$0")"
BOX=root@167.233.232.19
KEY="$HOME/.ssh/hetzner_crm"
SSH="ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=15 $BOX"
TOKFILE="$HOME/.claude-watch/token"

mkdir -p "$(dirname "$TOKFILE")"
[ -s "$TOKFILE" ] || python -c "import secrets;print(secrets.token_urlsafe(32),end='')" > "$TOKFILE"

$SSH 'mkdir -p /opt/claudewatch && umask 077 && cat > /opt/claudewatch/.env.new && printf "TOKEN=%s\n" "$(cat /opt/claudewatch/.env.new)" > /opt/claudewatch/.env && rm /opt/claudewatch/.env.new' < "$TOKFILE"
scp -q -i "$KEY" -o BatchMode=yes server.js push.js Dockerfile docker-compose.yml $BOX:/opt/claudewatch/
$SSH '
  set -e
  cd /opt/claudewatch
  docker compose up -d --build 2>&1 | tail -3
  sleep 2
  docker inspect claudewatch --format "{{.State.Status}} restarts={{.RestartCount}}"
  docker exec crm-caddy-1 wget -qO- -T 5 http://claudewatch:8792/health
'
echo
