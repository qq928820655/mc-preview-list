#!/bin/sh
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
[ -f config.env ] && set -a && . ./config.env && set +a
PORT="${MCPL_PORT:-8010}"
ss -tlnp 2>/dev/null | grep -q ":${PORT} " && { echo "端口 ${PORT} 已被占用"; exit 1; }
setsid nohup python3 -m uvicorn app:app --host 0.0.0.0 --port "${PORT}" > server.log 2>&1 &
echo "mc-preview-list 已启动, pid=$!, port=${PORT}"
