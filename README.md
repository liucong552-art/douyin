# 抖音直播录播

在使用 systemd 的 Debian 12（Bookworm）或 Debian 13（Trixie）服务器上，以 root 执行下面一行。支持 amd64 和 arm64。安装脚本会准备 Docker、Compose 和 Python 3，启动 DouyinLiveRecorder v4.0.7，并安装 `dyrec`。

```bash
curl -fsSL 'https://raw.githubusercontent.com/liucong552-art/douyin/main/install.sh' -o /root/douyin-install.sh && chmod 700 /root/douyin-install.sh && bash /root/douyin-install.sh
```

## 使用

```bash
dyrec add '抖音分享链接或整段分享文字'
dyrec list
dyrec del 1
dyrec enable 1
dyrec status
dyrec cookie
dyrec logs
```

- `dyrec list` 显示直播间编号。`dyrec del 1` 暂停编号 1 的监测，`dyrec enable 1` 恢复监测。
- Cookie 通过交互提示输入，终端不回显。新安装的主播列表和 Cookie 均为空。
- 项目数据在 `/opt/douyin-recorder`，录像在它的 `downloads/` 子目录。重复执行安装命令会保留已有配置、录像和运行中的容器。
- 如果自行从源码运行，先将 `config/` 中的两个 `.ini.example` 文件复制为对应的 `.ini` 文件。

录制程序及许可证来自 [DouyinLiveRecorder v4.0.7](https://github.com/ihmily/DouyinLiveRecorder/releases/tag/v4.0.7)。上游文档见 [UPSTREAM.md](UPSTREAM.md)。
