#!/usr/bin/env python3
"""Project-local Sparkle key management. Never reads or writes the Keychain."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import stat

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[1]
KEY_PATH = ROOT / ".update-signing" / "ed25519.key"


def public_key_from_file(path=KEY_PATH):
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("更新私钥及其目录不能是符号链接")
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077 or metadata.st_uid != os.getuid():
        raise ValueError("更新私钥必须归当前用户所有且仅当前用户可读写（chmod 600）")
    seed = base64.b64decode(path.read_bytes().strip(), validate=True)
    key = Ed25519PrivateKey.from_private_bytes(seed)
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(public).decode("ascii")


def initialize():
    info_path = ROOT / "Info.plist"
    old = plistlib.loads(info_path.read_bytes()).get("SUPublicEDKey")
    if not KEY_PATH.exists():
        if old:
            raise ValueError("应用已有更新公钥，但本地私钥缺失。请从备份恢复，不能自动替换发布密钥。")
        if KEY_PATH.parent.is_symlink() or KEY_PATH.is_symlink():
            raise ValueError("密钥路径不能是符号链接")
        KEY_PATH.parent.mkdir(mode=0o700, exist_ok=True)
        os.chmod(KEY_PATH.parent, 0o700)
        seed = Ed25519PrivateKey.generate().private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        descriptor = os.open(KEY_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(base64.b64encode(seed) + b"\n")
            output.flush()
            os.fsync(output.fileno())
    public = public_key_from_file()
    if old and old != public:
        raise ValueError("本地私钥与应用公钥不一致，拒绝替换。请恢复正确的密钥文件。")
    if not old:
        source = info_path.read_text()
        source = source.replace("</dict>", "\t<key>SUPublicEDKey</key>\n\t<string>" + public + "</string>\n</dict>")
        info_path.write_text(source)
    print("项目本地更新密钥已就绪；仅公钥写入 Info.plist，未访问钥匙串。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "check"))
    args = parser.parse_args()
    if args.action == "init":
        initialize()
    else:
        info = plistlib.loads((ROOT / "Info.plist").read_bytes())
        if public_key_from_file() != info.get("SUPublicEDKey"):
            raise ValueError("更新私钥与应用公钥不一致，拒绝发布")
        print("本地更新密钥与应用公钥匹配。")


if __name__ == "__main__":
    main()
