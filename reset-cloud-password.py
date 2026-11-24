import fcntl
from getpass import GetPassWarning, getpass
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import warnings


BASE = Path("/opt/cloud-video")
PASSWORD_LINE = re.compile(rb"(?m)^CLOUD_PASS=[^\r\n]*")


def write_private(path, content):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as pending:
        temp_path = Path(pending.name)
        try:
            pending.write(content)
            pending.close()
            temp_path.replace(path)
        finally:
            temp_path.unlink(missing_ok=True)


def recreate_cloud():
    subprocess.run(
        ["docker", "compose", "up", "-d", "--no-deps", "--force-recreate",
         "--wait", "--wait-timeout", "30", "cloud"],
        cwd=BASE,
        check=True,
    )


def reset_password(password):
    env_path = BASE / "cloud.env"
    credentials_path = BASE / "credentials.json"
    with (BASE / ".cloud-password.lock").open("a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original_env = env_path.read_bytes()
        credentials = json.loads(credentials_path.read_bytes())
        new_env, count = PASSWORD_LINE.subn(b"CLOUD_PASS=" + password.encode("ascii"), original_env)
        if count != 1 or "cloud_password" not in credentials:
            raise ValueError("未找到安装脚本生成的网盘密码配置。")

        credentials["cloud_password"] = password
        new_credentials = (json.dumps(credentials, indent=2) + "\n").encode("utf-8")

        write_private(env_path, new_env)
        try:
            recreate_cloud()
            write_private(credentials_path, new_credentials)
        except (OSError, subprocess.CalledProcessError):
            write_private(env_path, original_env)
            try:
                recreate_cloud()
            except (OSError, subprocess.CalledProcessError):
                print("已恢复旧密码配置，网盘容器需要检查。", file=sys.stderr)
            raise


def main():
    if os.geteuid() != 0:
        sys.exit("请以 root 身份在服务器终端运行。")
    if not all((BASE / name).is_file() for name in ("compose.yaml", "cloud.env", "credentials.json")):
        sys.exit("未找到一键安装生成的网盘配置。")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", GetPassWarning)
            password = getpass("输入网盘新密码：")
            if not re.fullmatch(r"[A-Za-z0-9_-]{12,}", password):
                sys.exit("密码至少 12 位，可用字母、数字、下划线和短横线。")
            if password != getpass("再输入一次："):
                sys.exit("两次输入不一致，请重新执行。")
        reset_password(password)
    except GetPassWarning:
        sys.exit("请在交互式 SSH 终端中输入密码。")
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        sys.exit(f"网盘密码更新失败：{exc}")
    print("网盘密码已更新，请用原用户名和新密码登录。")


if __name__ == "__main__":
    main()
