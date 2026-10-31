#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""核对「镜像内置的 roceos 版本」与「官方在线升级通道的最新版」。

为什么需要它：roceos（iNextOS 网页后台）不随 armbian-easepi 框架更新，它有自己的在线
升级服务器；固件镜像里打进去的版本必然落后于线上最新版（实证：官方 2.9.1 固件镜像里是
2.9.x，而同一台实机 OTA 后已是 3.0.2）。

官方接口（2026-10-31 从 roceos 二进制里取到的常量，非文档抄录）：
    GET http://update.roceos.com:14380/api/v1/updates/check
        ?version=<当前版本>&channel=stable_arm&arch=arm64
    ⇒ {"up_to_date":false,"current_version":"2.9.1",
       "latest":{"version":"3.0.2","channel":"stable_arm","type":"app",
                 "filename":"roceos-v3.0.2-arm64.tar.gz","sha256":"a997a2f8…",
                 "size":60458760,"released_at":"2026-10-30T14:44:09+08:00","changelog":"…"}}

用法：
    python3 tools/check-roceos.py --pinned official-roceos.txt
    python3 tools/check-roceos.py --pinned official-roceos.txt --summary "$GITHUB_STEP_SUMMARY"
退出码：0 = 一致（或接口没给 latest）；1 = 落后（该重建载荷）；2 = 输入/网络错误。
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

DEFAULT_BASE = "http://update.roceos.com:14380"
CHANNEL = "stable_arm"   # arm64 设备走的通道；用 stable 只会拿到 x86_64 包
ARCH = "arm64"


def pinned_version(path):
    txt = open(path, encoding="utf-8").read()
    m = re.search(r"^version:\s*([0-9][\w.\-]*)\s*$", txt, re.M)
    return m.group(1) if m else None


def fetch_latest(base, cur, timeout=30, attempts=4):
    """单次超时不判死：runner 到 update.roceos.com:14380 有瞬时不可达（实测同 job 内上一步刚
    查询成功、下一步连接 120s 超时），必须重试；全部失败才把 rc=2 交给调用方。"""
    url = "%s/api/v1/updates/check?version=%s&channel=%s&arch=%s" % (base, cur, CHANNEL, ARCH)
    last = None
    for i in range(1, attempts + 1):
        req = urllib.request.Request(url, headers={"User-Agent": "lyw-ci/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return url, json.loads(r.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
            last = e
            print("  …查询失败（第 %d/%d 次）：%s" % (i, attempts, e), file=sys.stderr)
            if i < attempts:
                time.sleep(2 * i)
    raise last


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--pinned", default="official-roceos.txt")
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--summary", default=None, help="写到这个文件（CI 的 GITHUB_STEP_SUMMARY）")
    a = ap.parse_args(argv)

    cur = pinned_version(a.pinned)
    if not cur:
        print("!! %s 里取不到 version:" % a.pinned, file=sys.stderr)
        return 2
    try:
        url, data = fetch_latest(a.base, cur)
    except (urllib.error.URLError, OSError, ValueError) as e:
        print("!! 查询官方更新服务器失败: %s" % e, file=sys.stderr)
        return 2

    lat = data.get("latest") or {}
    new = lat.get("version")
    out = []
    out.append("## roceos 版本检查（%s）\n" % a.base)
    out.append("- 镜像内置：`%s`" % cur)
    if not new:
        out.append("- 官方接口没给 latest（多半已是最新）")
        rc = 0
    elif new == cur:
        out.append("- 官方最新：`%s` ✅ 一致" % new)
        rc = 0
    else:
        out.append("- 官方最新：**`%s`**（channel=%s, arch=%s）⚠️ 落后" % (new, lat.get("channel"), ARCH))
        out.append("- 包：`%s`  size=%s  sha256=`%s`" % (lat.get("filename"), lat.get("size"), lat.get("sha256")))
        out.append("- 发布：%s" % lat.get("released_at"))
        cl = (lat.get("changelog") or "").strip()
        if cl:
            out.append("\n<details><summary>changelog</summary>\n\n```\n%s\n```\n</details>" % cl[:3000])
        out.append("\n**下一步**：不用手工做 —— `.github/workflows/build.yml` 的 `roceos` job 会在同一次运行里 "
                   "自动重建载荷、发本仓 release、改三处 pin 并推送（tools/roceos-sync.py）；"
                   "本脚本 rc=1 只表示「镜像内置版本落后于官方在线通道」。")
        rc = 1
    text = "\n".join(out) + "\n"
    print(text)
    print("查询 URL: %s" % url)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(text)
    return rc


if __name__ == "__main__":
    sys.exit(main())
