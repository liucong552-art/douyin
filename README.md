# 网盘、视频和抖音直播录播

## 一行安装

在使用 systemd 的 Debian 12/13 或 Ubuntu 22.04/24.04 服务器上，以 root 执行下面一行。已在 Debian 13 真机和 Ubuntu 24.04 隔离环境验证。

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/douyin/main/install-services.sh' -o /root/install-services.sh && chmod 700 /root/install-services.sh && bash /root/install-services.sh
```

- 输入 `1` 安装网盘和 Jellyfin，或输入 `3` 安装全部服务。脚本会依次询问网盘域名和视频域名。两个域名应提前解析到服务器，`80` 和 `443` 端口需要可用并允许公网访问。反向代理会自动申请 HTTPS 证书。
- 输入 `2` 只安装抖音录播。录播服务无需域名，安装后可直接使用 `dyrec`。
- 网盘和 Jellyfin 的初始登录信息在 `/opt/cloud-video/credentials.json`，以 root 查看。把视频上传到网盘的 `media` 目录，Jellyfin 会从这里读取视频。

## 只安装抖音录播的直达命令

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/douyin/main/install.sh' -o /root/douyin-install.sh && chmod 700 /root/douyin-install.sh && bash /root/douyin-install.sh
```

## 安装后怎么用

第一次使用时，先用 `dyrec add` 添加你想录制的直播间，再用 `dyrec list` 确认。把示例里引号内的文字换成从抖音复制的直播分享链接或整段分享文字，保留两边的单引号。下面每行都是一条独立命令，`#` 后面是说明，复制整行也可以执行。

```bash
dyrec add '抖音分享链接或整段分享文字'  # 添加直播间，开播后自动录制
dyrec list                              # 查看所有直播间的编号和监测状态
dyrec del 1                             # 暂停编号 1 的直播间，保留条目和已有录像
dyrec enable 1                          # 恢复监测编号 1 的直播间
dyrec status                            # 查看服务是否运行、是否正在录制、最近录像和剩余磁盘
dyrec cookie                            # 更新抖音 Cookie，按提示粘贴后按回车
dyrec logs                              # 查看最近 100 行日志并持续跟踪，按 Ctrl+C 退出查看
```

- 暂停或恢复直播间时，把 `del 1` 和 `enable 1` 里的 `1` 换成 `dyrec list` 第一列显示的编号。比如要暂停第 3 个直播间，执行 `dyrec del 3`。`list` 显示「监测中」表示已启用自动监测，想确认此刻是否正在录像，用 `dyrec status`。
- 更新 Cookie 时，终端会隐藏粘贴的内容。空闲时服务会重启以应用新 Cookie，正在录像时会等录像结束后再应用。
- 在日志界面按 `Ctrl+C` 只退出查看，录播服务会继续运行。

## 只清理已暂停的直播间条目

`dyrec del 1` 会暂停编号 1 的直播间并保留条目。下面这段命令会从列表中移除所有标为「已暂停」的条目，保留标为「监测中」的直播间和已有录像。录播服务会继续运行。

如果刚执行 `dyrec del`，等程序处理完暂停再清理。以 root 在录播服务器执行下面整段命令，原列表会先备份到 `/opt/douyin-recorder/backup_config/`。

```bash
(
    set -e
    cd /opt/douyin-recorder
    list=config/URL_config.ini
    test -f "$list"
    backup="$(mktemp backup_config/URL_config.ini.before-remove-paused.XXXXXXXX)"
    cp -- "$list" "$backup"
    updated="$(mktemp config/.URL_config.ini.XXXXXXXX)"
    trap 'rm -f -- "$updated"' EXIT
    cp -p -- "$list" "$updated"

    removed="$(python3 - "$backup" "$updated" <<'PY'
from codecs import BOM_UTF8
from pathlib import Path
import sys

backup, updated = map(Path, sys.argv[1:])
original = backup.read_bytes()
lines = original.decode("utf-8-sig").splitlines(keepends=True)
kept = [line for line in lines if not line.lstrip().startswith("#")]
bom = BOM_UTF8 if original.startswith(BOM_UTF8) else b""
updated.write_bytes(bom + "".join(kept).encode("utf-8"))
print(len(lines) - len(kept))
PY
    )"

    if [ "$removed" -gt 0 ]; then
        if ! cmp -s -- "$list" "$backup"; then
            printf '直播间列表刚被更新，请重新执行。\n' >&2
            exit 1
        fi
        mv -fT -- "$updated" "$list"
    fi
    printf '已移除 %s 个暂停条目。原列表备份在 %s/%s\n' "$removed" "$PWD" "$backup"
    dyrec list
)
```

清理后，剩余条目会重新编号。下次暂停或恢复直播间时，以 `dyrec list` 显示的编号为准。

## 获取并更新抖音 Cookie

1. 在电脑上的 Chrome 或 Edge 打开抖音网页版，登录你自己的账号，再进入任意抖音直播间。旧 Cookie 已失效时，先重新登录。
2. 按 `F12` 打开开发者工具，切到 **网络（Network）**，然后刷新直播间页面，让浏览器重新记录请求。
3. 点开一个请求网址以 `https://live.douyin.com/` 开头的请求。如果列表里有 `webcast/room/web/enter`，可以先点它。在右侧 **标头（Headers）** 里找到 **请求标头（Request Headers）**。
4. 找到 `cookie`，复制它的完整值。若复制出来包含开头的 `cookie:`，粘贴前去掉这个字段名。当前请求没有 `cookie` 时，换一个发往 `live.douyin.com` 的请求查看。
5. 在录播服务器执行 `dyrec cookie`。看到提示后粘贴并按回车。输入内容会隐藏，看到「Cookie 已写入」就表示录播配置已经保存。

Cookie 是账号的登录凭据，只粘贴到自己服务器上的 `dyrec cookie` 提示里。浏览器界面可参考 [Chrome 网络面板](https://developer.chrome.com/docs/devtools/network/reference/) 和 [Edge 网络面板](https://learn.microsoft.com/en-us/microsoft-edge/devtools/network/reference)。

## 录像和配置

新安装的主播列表和 Cookie 都是空的。项目数据在 `/opt/douyin-recorder/`，录像在 `/opt/douyin-recorder/downloads/`。重复执行安装命令会保留已有配置、录像和运行中的容器。

如果自行从源码运行，先将 `config/` 中的两个 `.ini.example` 文件复制为对应的 `.ini` 文件。

录制程序及许可证来自 [DouyinLiveRecorder v4.0.7](https://github.com/ihmily/DouyinLiveRecorder/releases/tag/v4.0.7)。上游文档见 [UPSTREAM.md](UPSTREAM.md)。
