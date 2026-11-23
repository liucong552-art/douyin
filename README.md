# 抖音直播录播

在使用 systemd 的 Debian 12（Bookworm）或 Debian 13（Trixie）服务器上，以 root 执行下面一行。支持 amd64 和 arm64。安装脚本会准备 Docker、Compose 和 Python 3，启动 DouyinLiveRecorder v4.0.7，并安装 `dyrec`。

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

## 录像和配置

新安装的主播列表和 Cookie 都是空的。项目数据在 `/opt/douyin-recorder/`，录像在 `/opt/douyin-recorder/downloads/`。重复执行安装命令会保留已有配置、录像和运行中的容器。

如果自行从源码运行，先将 `config/` 中的两个 `.ini.example` 文件复制为对应的 `.ini` 文件。

录制程序及许可证来自 [DouyinLiveRecorder v4.0.7](https://github.com/ihmily/DouyinLiveRecorder/releases/tag/v4.0.7)。上游文档见 [UPSTREAM.md](UPSTREAM.md)。
