# MC 预览列表

自动扫描当前服务器的全部 TCP 监听端口，按进程识别应用并匹配功能说明，展示：应用名称、功能说明、端口号、鉴权方式、预览地址（按访问域名自动推导）。支持用户名/密码登录（token 鉴权）。

## 一键部署 / 更新

```bash
curl -fsSL https://raw.githubusercontent.com/qq928820655/mc-preview-list/main/install.sh | sh
```

- 自动下载最新制品安装（已安装则自动升级，保留账号与配置）
- 默认目录：root 为 `/opt/mc-preview-list`，普通用户为 `~/mc-preview-list`
- 默认端口 `8010`，默认账号 `admin / pwd123`

首次安装自定义账号/端口/目录：

```bash
curl -fsSL https://raw.githubusercontent.com/qq928820655/mc-preview-list/main/install.sh | sh -s -- \
  --dir /opt/mc-preview-list --port 8010 --user myuser --password mypass
```

- 首次安装：未设置账号时走默认 `admin/pwd123`，设置了以设置为准
- 升级更新：**账号与密码无法也不会被重设**，自动保留 `data/`、`config.env`、`apps.json`

管理子命令：

```bash
sh install.sh status
sh install.sh start
sh install.sh stop
sh install.sh restart
```

交互菜单（本机终端直接执行 `sh install.sh`）：

```
1) 安装 / 升级最新制品（已有配置自动保留）
2) 修改登录账号
3) 启动    4) 停止    5) 重启
0) 退出
```

## 登录鉴权

- 页面与 `GET /api/apps` 均需登录；`POST /api/login` 换取 HMAC 长效 token（有效期 10 年，`data/secret.key` 不变则一直有效）
- token 存于浏览器 localStorage，登录后页面长期有效，无需重复登录
- token 可通过 `X-Auth-Token` 头或 `?token=` 查询串传递
- 制品默认账号 `admin / pwd123`，首次登录后请用交互菜单 [2] 修改

## 工作原理

1. 通过 `ss -tlnp`（回退 `netstat -tlnp`、`/proc/net/tcp`）扫描全部监听端口
2. 从 `/proc/<pid>/cwd` 与 `/proc/<pid>/cmdline` 读取进程信息，同一进程的多个端口合并为一张卡片
3. 用 `apps.json` 里的标注库匹配功能说明：先按 `match_keyword`（进程 cmdline/cwd 关键词），再按 `match_port`
4. 未命中的端口自动生成卡片（显示进程名/命令行/目录），不会遗漏任何监听服务
5. 预览地址：若当前访问域名形如 `8010-<id>.monkeycode-ai.live`，自动推导出其他端口的 `https://<端口>-<id>.monkeycode-ai.live`；否则不生成链接（可用 `MCPL_PREVIEW_SUFFIX=<id>.monkeycode-ai.live` 强制指定）

## 配置

- `apps.json`：标注库。新增应用后加一条 `{"match_keyword": "...", "title": "...", "desc": "...", "auth": "..."}` 即可；未知应用会以进程信息自动兜底展示（升级时该文件自动保留）
- `config.env`：`MCPL_PORT` / `MCPL_USER` / `MCPL_PASSWORD`（chmod 600，升级时保留）
- `data/`：`users.json`（登录账号）、`secret.key`（token 签名密钥），升级时保留
- 环境变量：`MCPL_PORT`（默认 8010）、`MCPL_PREVIEW_SUFFIX`、`MCPL_PREVIEW_SCHEME`（默认 https）
- API：`GET /api/apps?q=关键词&include_local=1&token=...`（include_local=1 时显示仅绑定 127.0.0.1 的监听）

## 手动部署（不用脚本）

```bash
pip3 install --break-system-packages -r requirements.txt
python3 -m uvicorn app:app --host 0.0.0.0 --port 8010
```

首次启动自动创建 `data/users.json`（默认 admin/pwd123）与 `data/secret.key`。

## 许可

MIT
