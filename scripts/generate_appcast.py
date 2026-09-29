#!/usr/bin/env python3
"""Generate and sign a feed bound to the exact app inside the release ZIP."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import plistlib
import re
import subprocess
from urllib.parse import quote
import xml.etree.ElementTree as ET
import zipfile

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_URL = "https://github.com/itxd/E-note/releases/latest/download/appcast.xml"
from update_keys import KEY_PATH, public_key_from_file


def read_release(archive):
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("E note.app/Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "com.weidong.noty":
        raise ValueError("拒绝为其他应用生成更新清单")
    if info.get("ENoteDevelopmentBuild"):
        raise ValueError("本地开发构建不能作为更新包发布")
    version = info["CFBundleShortVersionString"]
    build = str(info["CFBundleVersion"])
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("发布版本须为 x.y.z，构建号须为递增正整数")
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError("应用更新源与发布仓库不一致")
    for key in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
        if info.get(key) is not True:
            raise ValueError("发布应用必须启用 " + key)
    if info.get("SUSignedFeedFailureExpirationInterval") != 0:
        raise ValueError("更新清单验签失败不得自动放宽")
    if len(base64.b64decode(info["SUPublicEDKey"], validate=True)) != 32:
        raise ValueError("更新公钥无效")
    return info, version, build


def make_feed(info, version, build, archive_name, length, signature, notes):
    ET.register_namespace("sparkle", SPARKLE_NS)
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "E note 更新"
    ET.SubElement(channel, "link").text = "https://github.com/itxd/E-note/releases"
    ET.SubElement(channel, "language").text = "zh-cn"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "E note " + version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "description").text = notes
    for key, value in (("version", build), ("shortVersionString", version),
                       ("minimumSystemVersion", info["LSMinimumSystemVersion"])):
        ET.SubElement(item, "{" + SPARKLE_NS + "}" + key).text = str(value)
    ET.SubElement(item, "enclosure", {
        "url": "https://github.com/itxd/E-note/releases/download/v" + version + "/" + quote(archive_name),
        "length": str(length), "type": "application/octet-stream",
        "{" + SPARKLE_NS + "}edSignature": signature,
    })
    return ET.ElementTree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--sparkle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--notes", required=True, type=Path)
    args = parser.parse_args()
    info, version, build = read_release(args.archive)
    public_key = public_key_from_file()
    if public_key != info["SUPublicEDKey"]:
        raise ValueError("更新包内公钥与当前签名密钥不一致")
    signer = [str(args.sparkle / "bin/sign_update"), "--ed-key-file", str(KEY_PATH)]
    signature = subprocess.check_output(signer + ["-p", str(args.archive)], text=True).strip()
    subprocess.run(signer + ["--verify", str(args.archive), signature], check=True)
    feed = make_feed(info, version, build, args.archive.name, args.archive.stat().st_size,
                     signature, args.notes.read_text())
    temporary = args.output.with_name("appcast.pending.xml")
    try:
        feed.write(temporary, encoding="utf-8", xml_declaration=True)
        subprocess.run(signer + [str(temporary)], check=True)
        subprocess.run(signer + ["--verify", str(temporary)], check=True)
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)
    print("已验证安装包签名和清单签名：" + str(args.output))


if __name__ == "__main__":
    main()
