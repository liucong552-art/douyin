#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

repo='https://raw.githubusercontent.com/liucong552-art/douyin/main'
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
