#!/bin/sh
DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
[ -f config.env ] && set -a && . ./config.env && set +a
PORT="${MCPL_PORT:-8010}"
_pids=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
[ -z "$_pids" ] && { echo "mc-preview-list 未在运行 (端口 ${PORT})"; exit 0; }
for _x in $_pids; do kill "$_x" 2>/dev/null || true; done
sleep 1
_pids=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
[ -n "$_pids" ] && for _x in $_pids; do kill -9 "$_x" 2>/dev/null || true; done
echo "mc-preview-list 已停止 (端口 ${PORT})"
