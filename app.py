import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import time
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse

BASE_DIR = Path(__file__).resolve().parent
ANN_FILE = BASE_DIR / "apps.json"
STATIC_DIR = BASE_DIR / "static"
DATA_DIR = BASE_DIR / "data"
USERS_FILE = DATA_DIR / "users.json"
SECRET_FILE = DATA_DIR / "secret.key"
PORT = int(os.environ.get("MCPL_PORT", "8010"))
PREVIEW_SUFFIX = os.environ.get("MCPL_PREVIEW_SUFFIX", "").strip()
PREVIEW_SCHEME = os.environ.get("MCPL_PREVIEW_SCHEME", "https")
TOKEN_TTL_SECONDS = 10 * 365 * 24 * 3600
DEFAULT_USER = "admin"
DEFAULT_PASSWORD = "pwd123"

app = FastAPI(title="MC Preview List", docs_url=None, redoc_url=None)


def hash_password(password: str, salt: str) -> str:
    return hashlib.sha256((salt + password).encode()).hexdigest()


def set_user(username: str, password: str):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    salt = secrets.token_hex(8)
    USERS_FILE.write_text(
        json.dumps([{
            "username": username,
            "salt": salt,
            "password_hash": hash_password(password, salt),
        }], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    try:
        USERS_FILE.chmod(0o600)
    except OSError:
        pass


def ensure_data():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not SECRET_FILE.exists():
        SECRET_FILE.write_text(secrets.token_hex(32))
        try:
            SECRET_FILE.chmod(0o600)
        except OSError:
            pass
    if not USERS_FILE.exists():
        set_user(DEFAULT_USER, DEFAULT_PASSWORD)


def server_secret() -> bytes:
    ensure_data()
    return SECRET_FILE.read_bytes().strip()


def verify_user(username: str, password: str) -> bool:
    ensure_data()
    try:
        users = json.loads(USERS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    for u in users if isinstance(users, list) else []:
        expected = str(u.get("password_hash", ""))
        actual = hash_password(password, str(u.get("salt", "")))
        if u.get("username") == username and hmac.compare_digest(expected, actual):
            return True
    return False


def mint_token(username: str) -> str:
    exp = int(time.time()) + TOKEN_TTL_SECONDS
    payload = f"{username}.{exp}"
    sig = hmac.new(server_secret(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def verify_token(token: str) -> str:
    parts = str(token or "").strip().split(".")
    if len(parts) != 3 or not parts[1].isdigit():
        return ""
    username, exp, sig = parts
    if int(exp) < time.time():
        return ""
    payload = f"{username}.{exp}"
    expect = hmac.new(server_secret(), payload.encode(), hashlib.sha256).hexdigest()
    return username if hmac.compare_digest(sig, expect) else ""


def current_user(request: Request, token_query: str) -> str:
    tok = token_query or request.headers.get("x-auth-token", "")
    return verify_token(tok)


def load_annotations():
    try:
        with open(ANN_FILE, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def read_proc(pid: int) -> dict:
    info = {"pid": pid, "name": "", "cmdline": "", "cwd": ""}
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
        info["cmdline"] = raw[:200]
        info["name"] = raw.split(" ")[0].split("/")[-1] or "unknown"
    except OSError:
        pass
    try:
        info["cwd"] = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        pass
    return info


def parse_listener_lines(text: str):
    results = []
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "LISTEN":
            local = parts[3] if len(parts) > 3 else ""
            pid = None
            m = re.search(r'pid=(\d+)', line)
            if m:
                pid = int(m.group(1))
        elif parts[0] in ("tcp", "tcp6") and len(parts) > 5 and parts[5] == "LISTEN":
            local = parts[3]
            pid = None
            m = re.search(r'(\d+)/\S+\s*$', line)
            if m:
                pid = int(m.group(1))
        else:
            continue
        if ":" not in local:
            continue
        addr, _, port = local.rpartition(":")
        if not port.isdigit():
            continue
        results.append({"addr": addr, "port": int(port), "pid": pid})
    return results


async def scan_listeners():
    for tool, args in (("ss", ("-tlnp",)), ("netstat", ("-tlnp",))):
        try:
            proc = await asyncio.create_subprocess_exec(
                tool, *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except (OSError, ValueError):
            continue
        out, _ = await proc.communicate()
        if proc.returncode == 0 and out:
            items = parse_listener_lines(out.decode(errors="replace"))
            if items:
                return items
    return parse_proc_net_tcp()


def parse_proc_net_tcp():
    results = []
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = Path(path).read_text().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            cols = line.split()
            if len(cols) < 4 or cols[3] != "0A":
                continue
            _, port_hex = cols[1].rsplit(":", 1)
            results.append({"addr": "*", "port": int(port_hex, 16), "pid": None})
    return results


def find_annotation(annotations, port: int, text: str):
    for a in annotations:
        kw = str(a.get("match_keyword", "")).strip().lower()
        if kw and kw in text:
            return a
    for a in annotations:
        if int(a.get("match_port", -1)) == port:
            return a
    return None


def derive_preview_base(request: Request):
    host = (request.headers.get("host") or "").split(":")[0].strip()
    m = re.match(r"^(\d+)-(.+)$", host)
    if m and "." in m.group(2):
        return m.group(2)
    if PREVIEW_SUFFIX:
        return PREVIEW_SUFFIX
    return None


def short_cmdline(cmdline: str) -> str:
    return cmdline if len(cmdline) <= 120 else cmdline[:117] + "..."


@app.post("/api/login")
async def login(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"detail": "请求格式错误"}, status_code=400)
    username = str(body.get("username") or "").strip()
    password = str(body.get("password") or "")
    if not username or not password:
        return JSONResponse({"detail": "用户名或密码不能为空"}, status_code=400)
    await asyncio.sleep(0.3)
    if not verify_user(username, password):
        return JSONResponse({"detail": "用户名或密码错误"}, status_code=401)
    return {"ok": True, "username": username, "token": mint_token(username)}


@app.get("/api/me")
async def me(request: Request, token: str = ""):
    user = current_user(request, token)
    if not user:
        return JSONResponse({"detail": "未登录"}, status_code=401)
    return {"ok": True, "username": user}


@app.get("/api/apps")
async def list_apps(request: Request, q: str = "", include_local: int = 0, token: str = ""):
    user = current_user(request, token)
    if not user:
        return JSONResponse({"detail": "未登录"}, status_code=401)
    annotations = load_annotations()
    listeners = await scan_listeners()

    groups = {}
    for item in listeners:
        is_public = item["addr"] in ("0.0.0.0", "*", "::")
        if not is_public and not include_local:
            continue
        proc = read_proc(item["pid"]) if item["pid"] else {"pid": None, "name": "", "cmdline": "", "cwd": ""}
        key = proc["pid"] if proc["pid"] else f"port-{item['port']}"
        g = groups.setdefault(key, {"proc": proc, "ports": {}, "public": False})
        g["ports"][item["port"]] = True
        g["public"] = g["public"] or is_public

    base = derive_preview_base(request)
    cards = []
    for g in groups.values():
        ports = sorted(g["ports"])
        proc = g["proc"]
        text = (proc["cwd"] + " " + proc["cmdline"]).lower()
        ann = None
        for p in ports:
            ann = find_annotation(annotations, p, text)
            if ann:
                break
        if ann:
            title = str(ann.get("title") or f"端口 {ports[0]}")
            desc = str(ann.get("desc") or "")
            auth = str(ann.get("auth") or "未知")
            annotated = True
        else:
            title = proc["name"] or f"端口 {ports[0]}"
            desc = f"进程：{short_cmdline(proc['cmdline']) or '未知'}；目录：{proc['cwd'] or '未知'}"
            auth = "未知"
            annotated = False
        preview = None
        if g["public"] and base and annotated and len(ports) == 1:
            preview = f"{PREVIEW_SCHEME}://{ports[0]}-{base}"
        cards.append({
            "title": title,
            "ports": ports,
            "preview": preview,
            "desc": desc,
            "auth": auth,
            "public": g["public"],
            "annotated": annotated,
            "pid": proc["pid"],
            "proc_name": proc["name"],
            "cwd": proc["cwd"],
            "cmdline": short_cmdline(proc["cmdline"]),
        })

    cards.sort(key=lambda c: c["ports"][0])
    query = q.strip().lower()
    if query:
        words = query.split()
        cards = [
            c for c in cards
            if all(w in (c["title"] + " " + c["desc"] + " " + c["auth"] + " " + c["proc_name"] + " " + c["cwd"] + " " + " ".join(map(str, c["ports"]))).lower() for w in words)
        ]
    return {
        "count": len(cards),
        "total": len(cards),
        "preview_base": base,
        "q": q,
        "include_local": bool(include_local),
        "apps": cards,
    }


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


ensure_data()

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT)
