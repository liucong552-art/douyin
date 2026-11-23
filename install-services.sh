#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

fail() {
    printf '安装失败，%s\n' "$*" >&2
    exit 1
}

download() {
    curl --proto '=https' --connect-timeout 15 --max-time 90 --retry 3 -fsSL "$1" -o "$2"
}

ensure_docker() {
    local packages=()
    local needs_docker_repo=0

    command -v python3 >/dev/null || packages+=(python3)
    if ! command -v docker >/dev/null; then
        packages+=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
        needs_docker_repo=1
    elif ! docker compose version >/dev/null 2>&1; then
        packages+=(docker-compose-plugin)
        needs_docker_repo=1
    fi

    if (( ${#packages[@]} > 0 )); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o Acquire::Retries=3 update
        if (( needs_docker_repo )) && ! apt-cache show docker-compose-plugin >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends ca-certificates
            download "https://download.docker.com/linux/$ID/gpg" "$scratch/docker.asc"
            install -d -m 0755 /etc/apt/keyrings
            install -m 0644 "$scratch/docker.asc" /etc/apt/keyrings/cloud-video-docker.asc
            cat > /etc/apt/sources.list.d/cloud-video-docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/cloud-video-docker.asc
EOF
            apt-get -o Acquire::Retries=3 update
        fi
        apt-get install -y --no-install-recommends "${packages[@]}"
    fi

    unset DOCKER_CONTEXT
    export DOCKER_HOST='unix:///var/run/docker.sock'
    if ! docker info >/dev/null 2>&1; then
        systemctl enable --now docker.service
        docker info >/dev/null
    fi
}

read_domain() {
    local prompt="$1" domain
    local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
    printf '%s' "$prompt" >&2
    IFS= read -r domain || fail '没有读到域名'
    domain="${domain,,}"
    domain="${domain%.}"
    if [[ ${#domain} -gt 253 || ! "$domain" =~ ^($label\.)+[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
        fail "域名格式无效，请输入类似 cloud.example.com 的域名"
    fi
    printf '%s' "$domain"
}

install_cloud_video() {
    local base=/opt/cloud-video
    local cloud_site="$cloud_domain" video_site="$video_domain"
    local reload_attempt

    if [[ "${SUITE_LOCAL_HTTP:-0}" == 1 ]]; then
        cloud_site="http://$cloud_domain"
        video_site="http://$video_domain"
        export PROXY_HTTP_BIND=127.0.0.1:18080:80
        export PROXY_HTTPS_BIND=127.0.0.1:18443:443
    else
        export PROXY_HTTP_BIND=80:80
        export PROXY_HTTPS_BIND=443:443
    fi

    if [[ -L "$base" || ( -e "$base" && ! -d "$base" ) ]]; then
        fail "请检查目录 $base"
    fi
    if [[ -d "$base" && ! -f "$base/.managed-by-cloud-video" ]] &&
       [[ -n "$(find "$base" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        fail "$base 已有其他文件，请检查后重试"
    fi
    install -d -m 0755 "$base"
    touch "$base/.managed-by-cloud-video"
    for directory in data data/files data/photos data/media data/backup jellyfin upload-tmp; do
        [[ -L "$base/$directory" ]] && fail "请检查目录 $base/$directory"
        if [[ ! -d "$base/$directory" ]]; then
            install -d -m 0755 -o 10001 -g 10001 "$base/$directory"
        fi
    done
    install -d -m 0755 "$base/caddy-data" "$base/caddy-state"
    cd "$base"
    if ! cmp -s "$scratch/compose.yaml" compose.yaml; then
        install -m 0644 "$scratch/compose.yaml" compose.yaml
    fi
    if ! cmp -s "$scratch/simplecloud.py" simplecloud.py; then
        install -m 0644 "$scratch/simplecloud.py" simplecloud.py
    fi
    (
        umask 077
        python3 - <<'PY'
import json
from pathlib import Path
import secrets

path = Path("credentials.json")
if not path.exists():
    credentials = {
        "cloud_user": "admin",
        "cloud_password": secrets.token_urlsafe(24),
        "jellyfin_user": "admin",
        "jellyfin_password": secrets.token_urlsafe(24),
    }
    path.write_text(json.dumps(credentials, indent=2) + "\n", encoding="utf-8")
credentials = json.loads(path.read_text(encoding="utf-8"))
env_file = Path("cloud.env")
if not env_file.exists():
    env_file.write_text(
        f"CLOUD_USER={credentials['cloud_user']}\nCLOUD_PASS={credentials['cloud_password']}\n",
        encoding="utf-8",
    )
PY
    )
    printf 'PROXY_HTTP_BIND=%s\nPROXY_HTTPS_BIND=%s\n' "$PROXY_HTTP_BIND" "$PROXY_HTTPS_BIND" > .env

    printf '%s\n' '正在启动网盘和 Jellyfin'
    docker compose up -d cloud video
    if [[ ! -f .jellyfin-initialized ]]; then
        python3 "$scratch/setup-jellyfin.py" "$base/credentials.json"
        touch .jellyfin-initialized
    fi

    cat > "$scratch/Caddyfile" <<EOF
$cloud_site {
    reverse_proxy cloud:8080 {
        transport http {
            versions 1.1
        }
    }
}
$video_site {
    @startup path /Startup/*
    respond @startup 404
    reverse_proxy video:8096
}
EOF
    if ! cmp -s "$scratch/Caddyfile" Caddyfile; then
        cat "$scratch/Caddyfile" > Caddyfile
    fi
    docker compose up -d proxy
    for (( reload_attempt=0; reload_attempt<10; reload_attempt++ )); do
        if docker compose exec -T proxy caddy reload --config /etc/caddy/Caddyfile; then
            break
        fi
        sleep 1
    done
    (( reload_attempt < 10 )) || fail 'Caddy 配置加载失败'

    printf '%s\n' '正在验证两个站点'
    if [[ "${SUITE_LOCAL_HTTP:-0}" == 1 ]]; then
        check_sites http 18080
    else
        check_sites https 443
    fi
    printf '账号初始密码保存在 %s/credentials.json，仅 root 应读取。\n' "$base"
}

check_sites() {
    local scheme="$1" port="$2" cloud_code video_code attempts
    for (( attempts=0; attempts<60; attempts++ )); do
        cloud_code="$(curl --noproxy '*' -s --max-time 5 -o /dev/null -w '%{http_code}' \
            --resolve "$cloud_domain:$port:127.0.0.1" "$scheme://$cloud_domain:$port/" || true)"
        video_code="$(curl --noproxy '*' -s --max-time 5 -o /dev/null -w '%{http_code}' \
            --resolve "$video_domain:$port:127.0.0.1" "$scheme://$video_domain:$port/System/Info/Public" || true)"
        if [[ "$cloud_code" == 401 && "$video_code" == 200 ]]; then
            printf '网盘 %s://%s，视频 %s://%s\n' "$scheme" "$cloud_domain" "$scheme" "$video_domain"
            return
        fi
        sleep 2
    done
    fail "站点未通过验证，网盘 HTTP $cloud_code，视频 HTTP $video_code。请检查 DNS、端口和 docker compose logs proxy。"
}

write_payload() {
    cat > "$scratch/compose.yaml" <<'CLOUD_SUITE_PAYLOAD_0'
services:
  cloud:
    image: python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
    command: ["python", "/app/simplecloud.py"]
    user: "10001:10001"
    env_file: cloud.env
    environment:
      CLOUD_BIND: 0.0.0.0
      CLOUD_ROOT: /data/cloud
    volumes:
      - ./simplecloud.py:/app/simplecloud.py:ro
      - ./data:/data/cloud
      - ./upload-tmp:/tmp
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    restart: unless-stopped

  video:
    image: lscr.io/linuxserver/jellyfin@sha256:aef1046ab41bbd7b48e205e711aa31dfb1fa55a3fb8e22cbbb150a323c4a48c7
    environment:
      PUID: "10001"
      PGID: "10001"
      TZ: Asia/Shanghai
    ports:
      - "127.0.0.1:18096:8096"
    volumes:
      - ./jellyfin:/config
      - ./data/media:/media:ro
    restart: unless-stopped

  proxy:
    image: caddy:2-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
    ports:
      - "${PROXY_HTTP_BIND}"
      - "${PROXY_HTTPS_BIND}"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-state:/config
    restart: unless-stopped
CLOUD_SUITE_PAYLOAD_0
    cat > "$scratch/simplecloud.py" <<'CLOUD_SUITE_PAYLOAD_1'
#!/usr/bin/env python3
import os
import html
import hmac
import base64
import shutil
import urllib.parse
import cgi
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

ROOT = os.environ.get("CLOUD_ROOT", "/data/cloud")
USER = os.environ["CLOUD_USER"]
PASS = os.environ["CLOUD_PASS"]

def safe_path(url_path):
    decoded = urllib.parse.unquote(url_path)
    rel = decoded.lstrip("/")
    full = os.path.realpath(os.path.join(ROOT, rel))
    root = os.path.realpath(ROOT)
    if not (full == root or full.startswith(root + os.sep)):
        raise ValueError("bad path")
    return full, rel

def safe_name(name):
    name = os.path.basename(name.strip())
    if name in ["", ".", ".."]:
        return ""
    return name

def human_size(n):
    try:
        n = float(n)
    except Exception:
        return "-"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def auth_ok(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            return False
        try:
            raw = base64.b64decode(h.split(" ", 1)[1]).decode()
            u, p = raw.split(":", 1)
            return hmac.compare_digest(u.encode(), USER.encode()) and hmac.compare_digest(p.encode(), PASS.encode())
        except Exception:
            return False

    def require_auth(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="SimpleCloud"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self.auth_ok():
            return self.require_auth()

        try:
            parsed = urllib.parse.urlparse(self.path)
            full, rel = safe_path(parsed.path)
        except Exception:
            self.send_error(403)
            return

        if os.path.isfile(full):
            size = os.path.getsize(full)
            name = os.path.basename(full)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(name))
            self.end_headers()
            with open(full, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
            return

        if not os.path.isdir(full):
            self.send_error(404)
            return

        current = "/" + rel if rel else "/"
        parent_rel = "/".join(rel.split("/")[:-1]) if rel else ""
        parent_href = "/" + urllib.parse.quote(parent_rel) if parent_rel else "/"

        rows = []

        if rel:
            rows.append(f'''
<tr>
<td>📁</td>
<td><a href="{html.escape(parent_href)}">.. 返回上级</a></td>
<td></td>
<td></td>
</tr>
''')

        try:
            names = sorted(os.listdir(full), key=lambda x: (not os.path.isdir(os.path.join(full, x)), x.lower()))
        except Exception:
            names = []

        for name in names:
            path = os.path.join(full, name)
            href = "/" + urllib.parse.quote((rel + "/" + name).strip("/"))
            esc = html.escape(name)

            rename_form = f'''
<form method="post" class="inline-form">
<input type="hidden" name="action" value="rename">
<input type="hidden" name="target" value="{esc}">
<input class="rename-input" name="newname" placeholder="新名称">
<button>改名</button>
</form>
'''

            delete_form = f'''
<form method="post" class="inline-form" onsubmit="return confirm('确定删除此条目？')">
<input type="hidden" name="action" value="delete">
<input type="hidden" name="target" value="{esc}">
<button class="danger">删除</button>
</form>
'''

            if os.path.isdir(path):
                rows.append(f'''
<tr>
<td>📁</td>
<td><a href="{href}">{esc}/</a></td>
<td>-</td>
<td>{rename_form}{delete_form}</td>
</tr>
''')
            else:
                size = human_size(os.path.getsize(path))
                rows.append(f'''
<tr>
<td>📄</td>
<td><a href="{href}">{esc}</a></td>
<td>{size}</td>
<td>
<a class="btn" href="{href}">下载</a>
{rename_form}
{delete_form}
</td>
</tr>
''')

        body = f'''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>SimpleCloud</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body {{
  font-family: Arial, "Microsoft YaHei", sans-serif;
  margin: 0;
  background: #f5f6f8;
  color: #222;
}}
.header {{
  background: #202124;
  color: white;
  padding: 16px 24px;
}}
.container {{
  max-width: 1200px;
  margin: 24px auto;
  padding: 0 16px;
}}
.card {{
  background: white;
  border-radius: 14px;
  padding: 20px;
  box-shadow: 0 4px 18px rgba(0,0,0,.08);
  margin-bottom: 18px;
}}
.path {{
  color: #555;
  word-break: break-all;
}}
.grid {{
  display: grid;
  gap: 12px;
  grid-template-columns: 1fr;
}}
input[type=file], input[type=text], .rename-input {{
  padding: 8px;
  border: 1px solid #ddd;
  border-radius: 8px;
}}
.rename-input {{
  width: 150px;
}}
button, .btn {{
  background: #1677ff;
  color: white;
  border: none;
  padding: 8px 12px;
  border-radius: 8px;
  cursor: pointer;
  text-decoration: none;
  display: inline-block;
  margin: 2px;
}}
button:hover, .btn:hover {{
  opacity: .9;
}}
.danger {{
  background: #d93025;
}}
table {{
  width: 100%;
  border-collapse: collapse;
  margin-top: 12px;
}}
td, th {{
  border-bottom: 1px solid #eee;
  padding: 10px;
  text-align: left;
  vertical-align: middle;
}}
.progress-wrap {{
  display: none;
  margin-top: 12px;
}}
progress {{
  width: 100%;
  height: 22px;
}}
.note {{
  color: #666;
  font-size: 14px;
  line-height: 1.7;
}}
.quick a {{
  margin-right: 8px;
  margin-bottom: 8px;
}}
.inline-form {{
  display: inline-block;
}}
</style>
</head>
<body>
<div class="header">
  <h2>SimpleCloud 私有网盘</h2>
</div>

<div class="container">

<div class="card">
  <p class="path">当前位置：<b>{html.escape(current)}</b></p>
  <div class="quick">
    <a class="btn" href="/media">media 视频目录</a>
    <a class="btn" href="/files">files 普通文件</a>
    <a class="btn" href="/photos">photos 照片</a>
    <a class="btn" href="/backup">backup 备份</a>
  </div>
</div>

<div class="card">
  <h3>上传文件到当前目录</h3>
  <div class="grid">
    <input id="fileInput" type="file" multiple>
    <button onclick="uploadFiles()">开始上传</button>
  </div>
  <div class="progress-wrap" id="progressWrap">
    <p id="uploadText">准备上传...</p>
    <progress id="progressBar" value="0" max="100"></progress>
  </div>
  <p class="note">
    大视频建议用 PowerShell sftp 上传；网页上传适合小文件。视频请放到 <b>/media</b>。
    改名时请填写完整文件名，包括后缀，例如：<b>电影.mp4</b>。
  </p>
</div>

<div class="card">
  <h3>新建文件夹</h3>
  <form method="post">
    <input type="hidden" name="action" value="mkdir">
    <input type="text" name="dirname" placeholder="文件夹名称">
    <button type="submit">新建</button>
  </form>
</div>

<div class="card">
  <h3>文件列表</h3>
  <table>
    <tr>
      <th></th>
      <th>名称</th>
      <th>大小</th>
      <th>操作</th>
    </tr>
    {''.join(rows)}
  </table>
</div>

</div>

<script>
function uploadFiles() {{
  const input = document.getElementById('fileInput');
  const files = input.files;
  if (!files.length) {{
    alert('请选择文件');
    return;
  }}

  const wrap = document.getElementById('progressWrap');
  const bar = document.getElementById('progressBar');
  const text = document.getElementById('uploadText');

  wrap.style.display = 'block';

  let index = 0;

  function uploadOne() {{
    if (index >= files.length) {{
      text.innerText = '全部上传完成，页面即将刷新...';
      setTimeout(() => location.reload(), 1000);
      return;
    }}

    const file = files[index];
    const form = new FormData();
    form.append('file', file);

    const xhr = new XMLHttpRequest();
    xhr.open('POST', window.location.pathname, true);

    xhr.upload.onprogress = function(e) {{
      if (e.lengthComputable) {{
        const percent = Math.round((e.loaded / e.total) * 100);
        bar.value = percent;
        text.innerText = '正在上传 ' + (index + 1) + '/' + files.length + '：' + file.name + '，' + percent + '%';
      }}
    }};

    xhr.onload = function() {{
      if (xhr.status >= 200 && xhr.status < 400) {{
        index++;
        bar.value = 0;
        uploadOne();
      }} else {{
        alert('上传失败：' + file.name + '，HTTP ' + xhr.status);
      }}
    }};

    xhr.onerror = function() {{
      alert('上传失败：' + file.name);
    }};

    xhr.send(form);
  }}

  uploadOne();
}}
</script>
</body>
</html>
'''
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if not self.auth_ok():
            return self.require_auth()

        try:
            parsed = urllib.parse.urlparse(self.path)
            full, rel = safe_path(parsed.path)
        except Exception:
            self.send_error(403)
            return

        if not os.path.isdir(full):
            self.send_error(404)
            return

        ctype = self.headers.get("Content-Type", "")

        if ctype.startswith("multipart/form-data"):
            form = cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={
                    "REQUEST_METHOD": "POST",
                    "CONTENT_TYPE": ctype,
                }
            )

            files = []
            if "file" in form:
                item = form["file"]
                files = item if isinstance(item, list) else [item]

            for item in files:
                if not getattr(item, "filename", ""):
                    continue
                filename = safe_name(item.filename)
                if not filename:
                    continue
                dest = os.path.join(full, filename)
                if os.path.islink(dest):
                    self.send_error(403)
                    return
                flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
                with os.fdopen(os.open(dest, flags, 0o664), "wb") as out:
                    shutil.copyfileobj(item.file, out)
                os.chmod(dest, 0o664)

        else:
            length = int(self.headers.get("Content-Length", "0"))
            data = self.rfile.read(length).decode("utf-8", errors="ignore")
            params = urllib.parse.parse_qs(data)
            action = params.get("action", [""])[0]

            if action == "delete":
                target = safe_name(params.get("target", [""])[0])
                if target:
                    dest = os.path.join(full, target)
                    if os.path.isfile(dest):
                        os.remove(dest)
                    elif os.path.isdir(dest):
                        shutil.rmtree(dest)

            elif action == "mkdir":
                dirname = safe_name(params.get("dirname", [""])[0])
                if dirname:
                    directory = os.path.join(full, dirname)
                    if os.path.islink(directory):
                        self.send_error(403)
                        return
                    os.makedirs(directory, mode=0o775, exist_ok=True)

            elif action == "rename":
                target = safe_name(params.get("target", [""])[0])
                newname = safe_name(params.get("newname", [""])[0])

                if target and newname:
                    src = os.path.join(full, target)
                    dst = os.path.join(full, newname)

                    if not os.path.exists(src):
                        self.send_error(404, "原文件不存在")
                        return

                    if os.path.lexists(dst):
                        self.send_error(409, "新名称已存在")
                        return

                    os.rename(src, dst)

        self.send_response(303)
        self.send_header("Location", self.path)
        self.send_header("Content-Length", "0")
        self.end_headers()

if __name__ == "__main__":
    os.makedirs(ROOT, exist_ok=True)
    bind = os.environ.get("CLOUD_BIND", "127.0.0.1")
    server = ThreadingHTTPServer((bind, 8080), Handler)
    print(f"SimpleCloud listening on {bind}:8080", flush=True)
    server.serve_forever()
CLOUD_SUITE_PAYLOAD_1
    cat > "$scratch/setup-jellyfin.py" <<'CLOUD_SUITE_PAYLOAD_2'
import json
from pathlib import Path
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener


BASE = "http://127.0.0.1:18096"
CLIENT = 'MediaBrowser Client="Cloud Video Setup", Device="Server", DeviceId="cloud-video-install", Version="1.0"'
opener = build_opener(ProxyHandler({}))


def call(method, path, data=None, token=None):
    headers = {"X-Emby-Authorization": CLIENT}
    if token:
        headers["X-Emby-Token"] = token
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data).encode()
    request = Request(BASE + path, headers=headers, data=data, method=method)
    try:
        with opener.open(request, timeout=15) as response:
            payload = response.read()
    except HTTPError as exc:
        raise RuntimeError(f"Jellyfin {method} {path} HTTP {exc.code}") from exc
    return json.loads(payload) if payload else None


def wait_for_api():
    deadline = time.monotonic() + 180
    last_error = None
    while time.monotonic() < deadline:
        try:
            information = call("GET", "/System/Info/Public")
            if not information.get("StartupWizardCompleted", False):
                call("GET", "/Startup/User")
            return information
        except (RuntimeError, URLError, TimeoutError, ConnectionError) as exc:
            last_error = exc
            time.sleep(2)
    raise RuntimeError(f"Jellyfin did not become ready within 180 seconds: {last_error}")


def main():
    credentials = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    information = wait_for_api()
    if not information.get("StartupWizardCompleted", False):
        call("POST", "/Startup/User", {
            "Name": credentials["jellyfin_user"], "Password": credentials["jellyfin_password"],
        })
        call("POST", "/Startup/RemoteAccess", {"EnableRemoteAccess": True, "EnableAutomaticPortMapping": False})
        call("POST", "/Startup/Complete")

    session = call("POST", "/Users/AuthenticateByName", {
        "Username": credentials["jellyfin_user"], "Pw": credentials["jellyfin_password"],
    })
    token = session["AccessToken"]
    try:
        folders = call("GET", "/Library/VirtualFolders", token=token)
        if not any("/media" in folder["Locations"] for folder in folders):
            query = urlencode({"name": "网盘视频", "paths": "/media", "refreshLibrary": "true"})
            call("POST", "/Library/VirtualFolders?" + query, {}, token)
        print(f"Jellyfin {information['Version']} 已初始化并接入网盘 media 目录。")
    finally:
        call("POST", "/Sessions/Logout", token=token)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, URLError, TimeoutError, ConnectionError) as exc:
        sys.exit(str(exc))
CLOUD_SUITE_PAYLOAD_2
    cat > "$scratch/install-douyin.sh" <<'CLOUD_SUITE_PAYLOAD_3'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

repo='https://raw.githubusercontent.com/liucong552-art/douyin/2d45ee54ee142fe8376fd171f32cea142b677463'
base='/opt/douyin-recorder'
container='douyin-recorder'
launcher='/usr/local/bin/dyrec'

fail() {
    printf '安装失败，%s\n' "$*" >&2
    exit 1
}

download() {
    curl --proto '=https' --connect-timeout 15 --max-time 90 --retry 3 -fsSL "$1" -o "$2"
}

install_dependencies() {
    local packages=()
    local needs_docker_repo=0

    command -v python3 >/dev/null || packages+=(python3)
    if ! command -v docker >/dev/null; then
        packages+=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
        needs_docker_repo=1
    elif ! docker compose version >/dev/null 2>&1; then
        packages+=(docker-compose-plugin)
        needs_docker_repo=1
    fi
    if (( ${#packages[@]} == 0 )); then
        return
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=3 update
    if (( needs_docker_repo )) && ! apt-cache show docker-compose-plugin >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends ca-certificates
        download "https://download.docker.com/linux/$ID/gpg" "$scratch/docker.asc"
        install -d -m 0755 /etc/apt/keyrings
        install -m 0644 "$scratch/docker.asc" /etc/apt/keyrings/dyrec-docker.asc
        cat > /etc/apt/sources.list.d/dyrec-docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/dyrec-docker.asc
EOF
        apt-get -o Acquire::Retries=3 update
    fi
    apt-get install -y --no-install-recommends "${packages[@]}"
}

install_default() {
    local source="$1" target="$2" mode="$3"
    if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
        fail "请检查文件路径 $target"
    fi
    if [[ ! -e "$target" ]]; then
        install -m "$mode" "$source" "$target"
    fi
}

[[ $EUID -eq 0 ]] || fail '请以 root 身份运行'
[[ -r /etc/os-release ]] || fail '无法读取系统版本'
# shellcheck source=/dev/null
source /etc/os-release
case "${ID:-}:${VERSION_CODENAME:-}" in
    debian:bookworm|debian:trixie|ubuntu:jammy|ubuntu:noble) ;;
    *) fail '支持 Debian 12/13 和 Ubuntu 22.04/24.04' ;;
esac
arch="$(dpkg --print-architecture)"
[[ "$arch" =~ ^(amd64|arm64)$ ]] || fail "镜像不支持 $arch"
command -v curl >/dev/null || fail '请先安装 curl'
command -v systemctl >/dev/null || fail '请在使用 systemd 的服务器上运行'

exec 9>/run/lock/dyrec-install.lock
flock -n 9 || fail '已有一个安装进程在运行'
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

printf '%s\n' '正在下载录播配置和 dyrec 命令'
download "$repo/docker-compose.yaml" "$scratch/docker-compose.yaml"
download "$repo/config/config.ini.example" "$scratch/config.ini"
download "$repo/config/URL_config.ini.example" "$scratch/URL_config.ini"
download "$repo/admin/dyrec" "$scratch/dyrec"
bash -n "$scratch/dyrec"

if [[ -L "$base" || ( -e "$base" && ! -d "$base" ) || -L "$launcher" || ( -e "$launcher" && ! -f "$launcher" ) ]]; then
    fail "请检查 $base 和 $launcher"
fi
if [[ -e "$launcher" && ! -f "$base/docker-compose.yaml" ]]; then
    fail "$launcher 已存在，请先确认它属于这套录播服务"
fi

printf '%s\n' '正在准备 Docker 和系统依赖'
install_dependencies
unset DOCKER_CONTEXT
export DOCKER_HOST='unix:///var/run/docker.sock'
if ! docker info >/dev/null 2>&1; then
    systemctl enable --now docker.service
    docker info >/dev/null
fi

if docker container inspect "$container" >/dev/null 2>&1; then
    owner="$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$container")"
    [[ "$owner" == "$base/app" ]] || fail "容器名 $container 已被其他部署使用"
fi

[[ -d "$base" ]] || install -d -m 0755 "$base"
for dir in config backup_config; do
    [[ ! -L "$base/$dir" ]] || fail "请检查目录 $base/$dir"
    [[ -d "$base/$dir" ]] || install -d -m 0700 "$base/$dir"
done
for dir in logs downloads; do
    [[ ! -L "$base/$dir" ]] || fail "请检查目录 $base/$dir"
    [[ -d "$base/$dir" ]] || install -d -m 0755 "$base/$dir"
done
install_default "$scratch/docker-compose.yaml" "$base/docker-compose.yaml" 0644
install_default "$scratch/config.ini" "$base/config/config.ini" 0600
install_default "$scratch/URL_config.ini" "$base/config/URL_config.ini" 0600

printf '%s\n' '正在启动录播容器'
cd "$base"
docker compose -f docker-compose.yaml config --quiet
docker compose -f docker-compose.yaml up -d --no-recreate --wait --wait-timeout 60 app
docker exec "$container" ffmpeg -version >/dev/null
if ! cmp -s "$scratch/dyrec" "$launcher" || [[ ! -x "$launcher" ]]; then
    install -m 0755 "$scratch/dyrec" "$launcher"
fi
"$launcher" status
printf '\n安装完成。运行 dyrec help 查看命令。\n'
CLOUD_SUITE_PAYLOAD_3
}

[[ $EUID -eq 0 ]] || fail '请以 root 身份运行'
source /etc/os-release
case "${ID:-}:${VERSION_CODENAME:-}" in
    debian:bookworm|debian:trixie|ubuntu:jammy|ubuntu:noble) ;;
    *) fail '支持 Debian 12/13 和 Ubuntu 22.04/24.04' ;;
esac
arch="$(dpkg --print-architecture)"
[[ "$arch" =~ ^(amd64|arm64)$ ]] || fail "镜像不支持 $arch"
command -v curl >/dev/null || fail '请先安装 curl'

printf '%s\n' '1. 网盘和视频' '2. 抖音录播' '3. 全部安装'
printf '%s' '选择项目 [3] ' >&2
IFS= read -r selection || fail '没有读到安装选项'
selection="${selection:-3}"
case "$selection" in
    1|2|3) ;;
    *) fail '请输入 1、2 或 3' ;;
esac
if [[ "$selection" != 2 ]]; then
    cloud_domain="$(read_domain '网盘域名 ')"
    video_domain="$(read_domain '视频域名 ')"
    [[ "$cloud_domain" != "$video_domain" ]] || fail '请输入两个不同的域名'
fi

exec 9>/run/lock/cloud-video-install.lock
flock -n 9 || fail '已有一个安装进程在运行'
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
write_payload

if [[ "$selection" != 2 ]]; then
    ensure_docker
    install_cloud_video
fi
if [[ "$selection" != 1 ]]; then
    bash "$scratch/install-douyin.sh"
fi
printf '%s\n' '安装和服务检查完成。'
