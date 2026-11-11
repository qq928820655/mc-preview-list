#!/bin/sh
# mc-preview-list 一键安装/升级/管理脚本
# 用法:
#   一键部署/更新最新制品（管道模式，默认目录、默认端口、默认账号 admin/pwd123）:
#     curl -fsSL https://raw.githubusercontent.com/qq928820655/mc-preview-list/main/install.sh | sh
#   带参数部署（首次安装时可自定义账号，未指定走默认）:
#     curl -fsSL https://raw.githubusercontent.com/qq928820655/mc-preview-list/main/install.sh | sh -s -- --dir /opt/mc-preview-list --port 8010 --user admin --password pwd123
#   管理子命令:
#     sh install.sh status|start|stop|restart
#   交互菜单（本机有终端时）:
#     sh install.sh
#   说明:
#     首次安装: 可设置用户名/密码，未设置走默认 admin/pwd123
#     升级更新: 自动保留已有账号与配置（apps.json/data/config.env），无法也无法需要重设密码
#     改密码:   安装后用交互菜单选 [2] 修改访问账号

set -eu

REPO="qq928820655/mc-preview-list"
BRANCH="main"
DEFAULT_PORT=8010
DEFAULT_USER="admin"
DEFAULT_PASSWORD="pwd123"

TARGET=""
SET_TARGET=0
PORT=""
USER_NAME=""
PASSWORD=""
DO_START=1
SET_START=0
ACTION=""
EXIST_INSTALLED=0
IS_UPGRADE=0

log()  { printf '\033[32m[mcpl]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[mcpl]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[mcpl]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    status|start|stop|restart|menu)
      [ -n "$ACTION" ] && die "管理动作只能指定一个"
      ACTION="$1"; shift ;;
    --dir)          TARGET="$2"; SET_TARGET=1; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --user)         USER_NAME="$2"; shift 2 ;;
    --password)     PASSWORD="$2"; shift 2 ;;
    --start)        DO_START=1; SET_START=1; shift ;;
    --no-start)     DO_START=0; SET_START=1; shift ;;
    -h|--help)      sed -n '2,16p' "$0" 2>/dev/null || true; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

# ---------- 交互检测（curl|sh 时 stdin 是管道，提示走 /dev/tty） ----------
if [ -t 0 ]; then
  INTERACTIVE=1
elif [ -t 1 ] && (printf '' 2>/dev/null >/dev/tty) 2>/dev/null; then
  INTERACTIVE=1
else
  INTERACTIVE=0
fi

ask() {
  _prompt="$1"; _def="$2"; _ans=""
  if [ "$INTERACTIVE" = 1 ]; then
    printf '%s（回车=%s）' "$_prompt" "$_def" 2>/dev/null >/dev/tty || true
    IFS= read -r _ans 2>/dev/null </dev/tty || _ans=""
  fi
  if [ -n "$_ans" ]; then printf '%s' "$_ans"; else printf '%s' "$_def"; fi
}

ask_yes() {
  _prompt="$1"; _def="$2"; _ans=""
  if [ "$INTERACTIVE" = 1 ]; then
    case "$_def" in
      y|Y) _hint="[Y/n]" ;;
      *)   _hint="[y/N]" ;;
    esac
    printf '%s %s（回车=默认）' "$_prompt" "$_hint" 2>/dev/null >/dev/tty || true
    IFS= read -r _ans 2>/dev/null </dev/tty || _ans=""
  fi
  [ -z "$_ans" ] && _ans="$_def"
  case "$_ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

menu_read() {
  if [ -t 0 ]; then
    IFS= read -r "$1"
  else
    IFS= read -r "$1" 2>/dev/null </dev/tty || { warn "当前无交互终端"; exit 1; }
  fi
}

# ---------- 工具 ----------
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  else
    wget -qO "$2" "$1"
  fi
}

read_env_var() {
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

rewrite_env_var() {
  _f="$1"; _k="$2"; _v="$3"
  [ -f "$_f" ] || return 0
  { grep -v "^$_k=" "$_f" 2>/dev/null || true; echo "$_k=$_v"; } > "$_f.t.$$"
  mv "$_f.t.$$" "$_f"
  chmod 600 "$_f" 2>/dev/null || true
}

current_port() {
  _v=$(read_env_var "$TARGET/config.env" MCPL_PORT)
  if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$DEFAULT_PORT"; fi
}

current_user() {
  _v=$(read_env_var "$TARGET/config.env" MCPL_USER)
  if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "$DEFAULT_USER"; fi
}

port_pids() { ss -tlnp 2>/dev/null | grep ":$1 " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u; }

mgmt_stop() {
  _p="$(current_port)"
  _pids=$(port_pids "$_p")
  [ -z "$_pids" ] && { log "mc-preview-list 未在运行（端口 $_p）"; return 0; }
  for _x in $_pids; do kill "$_x" 2>/dev/null || true; done
  sleep 1
  _pids=$(port_pids "$_p")
  [ -n "$_pids" ] && for _x in $_pids; do kill -9 "$_x" 2>/dev/null || true; done
  log "mc-preview-list 已停止（端口 $_p）"
}

mgmt_wait() {
  _p="$1"; _i=0
  while [ $_i -lt 20 ]; do
    [ -n "$(port_pids "$_p")" ] && return 0
    sleep 1; _i=$((_i + 1))
  done
  return 1
}

mgmt_start() {
  _p="$(current_port)"
  if [ -n "$(port_pids "$_p")" ]; then
    log "mc-preview-list 已在运行（端口 $_p，PID $(port_pids "$_p" | tr '\n' ',' | sed 's/,$//')）"
    return 0
  fi
  ( cd "$TARGET" && setsid nohup sh start.sh >> server.log 2>&1 ) || true
  if mgmt_wait "$_p"; then
    log "mc-preview-list 已启动（端口 $_p）"
  else
    warn "启动后未监听，请查看日志: $TARGET/server.log"
    return 1
  fi
}

mgmt_status() {
  _p="$(current_port)"
  _pids=$(port_pids "$_p")
  if [ -n "$_pids" ]; then
    printf '  mc-preview-list  运行中  端口 %-6s PID %-12s %s\n' "$_p" "$(echo $_pids | tr '\n' ',' | sed 's/,$//')" "$TARGET"
  else
    printf '  mc-preview-list  已停止  端口 %-6s %-12s %s\n' "$_p" "-" "$TARGET"
  fi
}

# ---------- 目录定位与已有安装识别 ----------
if [ "$SET_TARGET" = 0 ]; then
  for _p in /opt "$HOME" "$(pwd)"; do
    if [ -f "$_p/mc-preview-list/app.py" ] && [ -f "$_p/mc-preview-list/static/index.html" ]; then
      TARGET="$_p/mc-preview-list"; break
    fi
  done
fi
[ -z "$TARGET" ] && { [ "$(id -u)" = 0 ] && TARGET=/opt/mc-preview-list || TARGET="$HOME/mc-preview-list"; }
[ -f "$TARGET/app.py" ] && EXIST_INSTALLED=1

# ---------- 依赖 ----------
ensure_deps() {
  command -v python3 >/dev/null 2>&1 || die "需要 python3"
  if python3 -c "import fastapi, uvicorn" >/dev/null 2>&1; then
    return 0
  fi
  log "安装 Python 依赖（fastapi uvicorn）"
  _r=""
  [ -f "$TARGET/requirements.txt" ] && _r="-r $TARGET/requirements.txt"
  pip3 install $_r >/dev/null 2>&1 \
    || pip3 install --break-system-packages $_r >/dev/null 2>&1 \
    || pip3 install --user $_r >/dev/null 2>&1 \
    || pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple $_r >/dev/null 2>&1 \
    || true
  python3 -c "import fastapi, uvicorn" >/dev/null 2>&1 \
    || die "依赖安装失败，请手动执行: pip3 install fastapi uvicorn"
}

# ---------- 下载制品（优先 artifact 制品包，回退源码归档） ----------
fetch_extract() {
  _dest_new="$1"; _tmp="$2"
  if fetch "https://raw.githubusercontent.com/$REPO/$BRANCH/artifact/mc-preview-list-latest.tar.gz" "$_tmp" 2>/dev/null \
     && tar -tzf "$_tmp" >/dev/null 2>&1; then
    mkdir -p "$_dest_new"
    tar -xzf "$_tmp" -C "$_dest_new"
    rm -f "$_tmp"
    return 0
  fi
  rm -f "$_tmp"
  log "制品包不可用，回退源码归档 $REPO@$BRANCH"
  fetch "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" "$_tmp"
  mkdir -p "$_dest_new"
  tar -xzf "$_tmp" -C "$_dest_new" --strip-components=1
  rm -f "$_tmp"
}

# ---------- 安装/升级主流程 ----------
do_install() {
  if [ "$EXIST_INSTALLED" = 1 ]; then
    IS_UPGRADE=1
    _old_port=$(read_env_var "$TARGET/config.env" MCPL_PORT)
    [ -n "$_old_port" ] && [ -z "$PORT" ] && PORT="$_old_port"
    log "检测到已有安装: $TARGET，执行升级（保留账号与配置）"
    if [ -n "$USER_NAME" ] || [ -n "$PASSWORD" ]; then
      warn "升级模式忽略 --user/--password：账号与密码无法也不会被重设（如需修改请在交互菜单选 [2]）"
      USER_NAME=""; PASSWORD=""
    fi
  fi

  if [ "$INTERACTIVE" = 1 ] && [ "$IS_UPGRADE" != 1 ]; then
    log "开始安装（回车即全部用默认值）"
    if [ "$SET_TARGET" = 0 ]; then
      TARGET=$(ask "安装目录" "$TARGET")
    fi
    [ -z "$PORT" ] && PORT=$(ask "监听端口" "$DEFAULT_PORT")
    [ -z "$USER_NAME" ] && USER_NAME=$(ask "登录用户名" "$DEFAULT_USER")
    [ -z "$PASSWORD" ] && PASSWORD=$(ask "登录密码" "$DEFAULT_PASSWORD")
    if [ "$SET_START" = 0 ]; then
      ask_yes "安装完成后立即启动服务？" "y" && DO_START=1 || DO_START=0
    fi
  elif [ "$IS_UPGRADE" != 1 ]; then
    [ -z "$PORT" ] && PORT="$DEFAULT_PORT"
    [ -z "$USER_NAME" ] && USER_NAME="$DEFAULT_USER"
    [ -z "$PASSWORD" ] && PASSWORD="$DEFAULT_PASSWORD"
  fi
  [ -z "$PORT" ] && PORT=$(read_env_var "$TARGET/config.env" MCPL_PORT)
  [ -z "$PORT" ] && PORT="$DEFAULT_PORT"

  command -v tar >/dev/null 2>&1 || die "需要 tar"
  mkdir -p "$(dirname "$TARGET")"

  WAS_RUNNING=0
  if [ "$EXIST_INSTALLED" = 1 ] && [ -n "$(port_pids "$(current_port)")" ]; then
    WAS_RUNNING=1
    log "服务正在运行（端口 $(current_port)），升级前先停止"
    mgmt_stop
  fi

  NEW="$TARGET.new.$$"
  log "下载最新制品 $REPO@$BRANCH -> $TARGET"
  fetch_extract "$NEW" "$(dirname "$TARGET")/.tgz.$$"

  if [ -d "$TARGET" ]; then
    for _keep in data config.env apps.json; do
      if [ -e "$TARGET/$_keep" ]; then cp -rf "$TARGET/$_keep" "$NEW/$_keep"; fi
    done
    rm -rf "$TARGET"
  fi
  mv "$NEW" "$TARGET"
  chmod +x "$TARGET"/start.sh "$TARGET"/stop.sh 2>/dev/null || true

  ensure_deps

  if [ ! -f "$TARGET/config.env" ]; then
    cat > "$TARGET/config.env" <<EOF
MCPL_PORT=$PORT
MCPL_USER=$USER_NAME
MCPL_PASSWORD=$PASSWORD
EOF
    chmod 600 "$TARGET/config.env"
    log "初始化账号: $USER_NAME（首次登录请尽快修改密码）"
  else
    rewrite_env_var "$TARGET/config.env" MCPL_PORT "$PORT"
    log "保留已有 config.env（账号/端口不变）"
  fi

  if [ ! -f "$TARGET/data/users.json" ]; then
    _u=$(read_env_var "$TARGET/config.env" MCPL_USER)
    _pw=$(read_env_var "$TARGET/config.env" MCPL_PASSWORD)
    [ -z "$_u" ] && _u="$DEFAULT_USER"
    [ -z "$_pw" ] && _pw="$DEFAULT_PASSWORD"
    ( cd "$TARGET" && MCPL_SET_USER="$_u" MCPL_SET_PASSWORD="$_pw" python3 -c 'import os, app; app.set_user(os.environ["MCPL_SET_USER"], os.environ["MCPL_SET_PASSWORD"])' )
    chmod 600 "$TARGET/data/users.json" 2>/dev/null || true
    log "已写入登录账号: $_u"
  else
    log "保留已有登录账号"
  fi

  _ver=$(cat "$TARGET/VERSION" 2>/dev/null || echo "unknown")
  log "已部署版本: $_ver"

  if [ "$DO_START" = 1 ] || [ "$WAS_RUNNING" = 1 ]; then
    mgmt_start || true
  fi

  MAIN_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
  [ -z "$MAIN_IP" ] && MAIN_IP=127.0.0.1
  _u=$(read_env_var "$TARGET/config.env" MCPL_USER)
  _pw=$(read_env_var "$TARGET/config.env" MCPL_PASSWORD)
  [ -z "$_u" ] && _u="$DEFAULT_USER"
  [ -z "$_pw" ] && _pw="$DEFAULT_PASSWORD"
  echo
  log "完成！"
  if [ "$IS_UPGRADE" = 1 ]; then
    echo "  模式     : 更新/升级（账号与配置已保留）"
  else
    echo "  模式     : 全新安装"
  fi
  echo "  地址     : http://$MAIN_IP:$PORT/   账号: $_u / $_pw"
  echo "  目录     : $TARGET"
  echo "  配置     : $TARGET/config.env（端口/账号，chmod 600）"
  echo "  服务管理 : sh $TARGET/../install.sh status|start|stop|restart"
  echo "  预览     : 平台环境自动生成 <端口>-前缀的预览地址"
  echo
}

# ---------- 修改账号（仅交互菜单） ----------
change_password() {
  [ -d "$TARGET" ] || die "尚未安装: $TARGET"
  _new_u=$(ask "新的登录用户名" "$(current_user)")
  _new_p=$(ask "新的登录密码" "")
  [ -z "$_new_p" ] && { log "已取消（保持原密码）"; return 0; }
  rewrite_env_var "$TARGET/config.env" MCPL_USER "$_new_u"
  rewrite_env_var "$TARGET/config.env" MCPL_PASSWORD "$_new_p"
  ( cd "$TARGET" && MCPL_SET_USER="$_new_u" MCPL_SET_PASSWORD="$_new_p" python3 -c 'import os, app; app.set_user(os.environ["MCPL_SET_USER"], os.environ["MCPL_SET_PASSWORD"])' )
  chmod 600 "$TARGET/data/users.json" 2>/dev/null || true
  log "登录账号已更新为: $_new_u"
  if [ -n "$(port_pids "$(current_port)")" ]; then
    mgmt_stop
    mgmt_start || true
  fi
}

# ---------- 交互菜单 ----------
main_menu() {
  while :; do
    echo
    echo "========== mc-preview-list 服务管理 =========="
    mgmt_status
    echo "  1) 安装 / 升级最新制品（已有配置自动保留）"
    echo "  2) 修改登录账号"
    echo "  3) 启动        4) 停止        5) 重启"
    echo "  0) 退出"
    printf '请选择: '
    menu_read sel
    case "$sel" in
      1) EXIST_INSTALLED=0; [ -f "$TARGET/app.py" ] && EXIST_INSTALLED=1; do_install ;;
      2) change_password ;;
      3) mgmt_start || true ;;
      4) mgmt_stop ;;
      5) mgmt_stop; mgmt_start || true ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择: $sel" ;;
    esac
  done
}

# ---------- 入口 ----------
case "${ACTION:-}" in
  status)  mgmt_status ;;
  start)   mgmt_start ;;
  stop)    mgmt_stop ;;
  restart) mgmt_stop; mgmt_start ;;
  menu)    main_menu ;;
  "")
    if [ "$INTERACTIVE" = 1 ]; then
      main_menu
    else
      do_install
    fi
    ;;
esac
