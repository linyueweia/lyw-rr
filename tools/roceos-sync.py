#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""roceos-sync.py —— 全自动跟官方 roceos（iNextOS 网页后台）版本（四仓各跑一份）。

不依赖任何 secret，只用 job 自带的 GITHUB_TOKEN：下官方包 → 按官方安装映射重建本仓载荷 →
打包算 sha → 交回 workflow 发 release / 改三处 pin / 触发整机构建。

官方渠道（2026-10-31 从 roceos 二进制里取的常量，不是文档抄录）：
    查版本  GET http://update.roceos.com:14380/api/v1/updates/check
              ?version=<当前>&channel=stable_arm&arch=arm64
    取包    GET http://update.roceos.com:14380/api/v1/updates/packages/<filename>
            （注意：该路径 **HEAD 返回 404、GET 返回 206/200** —— 别用 HEAD 探活）

官方包 → 镜像落点的映射（官方 3.0.2 包 vs 实机 OTA 后的 /opt/roceos 逐哈希对出来：
767 个唯一哈希里 760 个同哈希同路径，剩下 7 个就是要挪位置的这批）：
    www/**、bin/**、roceos*、version.json  → /opt/roceos/<同路径>
    assets/librkllmrt.so                  → /opt/roceos-ai/librkllmrt.so
    assets/roceos-ai-server.py            → /opt/roceos-ai/server.py
    systemd/*.service                     → /etc/systemd/system/
    manifest.json、required-packages.json  → 安装器消费，不进镜像

用法：
    python3 tools/roceos-sync.py --repo lyw-rr                # 有新版本才动
    python3 tools/roceos-sync.py --repo lyw-rr --dry-run      # 只探测 + 下载校验
    python3 tools/roceos-sync.py --repo lyw-rr --force 3.0.2  # 强制按指定版本重建（测试）
退出码：0 = 已是最新（未改动）；10 = 已重建并改好三处 pin；2 = 输入/网络/校验失败。
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.request

BASE = "http://update.roceos.com:14380"
CHANNEL = "stable_arm"
ARCH = "arm64"
UA = "lyw-ci/1.0 (+github actions)"

# 这些目录整棵替换（旧版本带 hash 名的资产不清掉会越滚越大）
WHOLE_DIRS = ("www",)

REPO_META = {
    "lyw-kk": "extensions/kickpi-k1-roceos.sh",
    "lyw-OS": "extensions/t68m-roceos.sh",
    "lyw-rr": "extensions/lyw-rr-roceos.sh",
    "lyw-hh": "extensions/lyw-hh-roceos.sh",
}


# ────────────────────────── 小工具 ──────────────────────────

def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def http_get(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def download(url, dest, timeout=900, chunk=1 << 20, attempts=3):
    """下载到 dest；与 Content-Length 不符就重来（实测被截断过一次：92MB 变 67MB，静默成功）。"""
    last = None
    for i in range(1, attempts + 1):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        total = 0
        with urllib.request.urlopen(req, timeout=timeout) as r, open(dest, "wb") as f:
            want = r.headers.get("Content-Length")
            while True:
                b = r.read(chunk)
                if not b:
                    break
                f.write(b)
                total += len(b)
        if want is None or int(want) == total:
            return total
        last = (int(want), total)
        print("  …下载不完整（%d/%d B），第 %d 次重试" % (total, int(want), i), file=sys.stderr)
        time.sleep(2 * i)
    raise SystemExit("!! 下载始终不完整：期望 %d B，实际 %d B" % (last if last else (0, 0)))


def read_kv(path):
    kv = {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if ":" in line:
            k, v = line.split(":", 1)
            kv[k.strip()] = v.strip()
    return kv


def write_kv(path, kv, header):
    out = list(header) + [""]
    for k, v in kv.items():
        out.append("%s: %s" % (k, v))
    open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")


# ────────────────────────── 官方接口 ──────────────────────────

def query_latest(cur):
    url = "%s/api/v1/updates/check?version=%s&channel=%s&arch=%s" % (BASE, cur, CHANNEL, ARCH)
    return url, (json.loads(http_get(url).decode("utf-8")).get("latest") or {})


# ────────────────────────── 载荷重建 ──────────────────────────

def map_member(rel):
    """官方包内相对路径 → 载荷内相对路径；None = 不进镜像。

    逐哈希核对官方 3.0.2 包 vs 实机 /opt/roceos 得出的对应表（761/773 命中唯一同哈希）：
        bin/<x>              → /opt/roceos/<x>        ← 注意 bin/ 前缀要去掉，实机没有 bin/ 这一层
        version.json         → /opt/roceos/version.json
        www/**               → /opt/roceos/www/**
        assets/librkllmrt.so → /opt/roceos-ai/librkllmrt.so
        assets/roceos-ai-server.py → /opt/roceos-ai/server.py
        systemd/*.service    → /etc/systemd/system/*.service
        manifest.json / required-packages.json → 安装器消费，不进镜像
    """
    if rel in ("manifest.json", "required-packages.json", ""):
        return None
    if rel.startswith("systemd/"):
        return "etc/systemd/system/" + rel[len("systemd/"):]
    if rel == "assets/librkllmrt.so":
        return "opt/roceos-ai/librkllmrt.so"
    if rel == "assets/roceos-ai-server.py":
        return "opt/roceos-ai/server.py"
    if rel.startswith("assets/"):
        return None
    if rel.startswith("bin/"):
        return "opt/roceos/" + rel[len("bin/"):]
    return "opt/roceos/" + rel


def build_payload(prev_payload, pkg_path, out_path, log=print):
    work = tempfile.mkdtemp(prefix="roceos-sync.")
    stage = os.path.join(work, "stage")
    os.makedirs(stage, exist_ok=True)

    with tarfile.open(prev_payload) as tf:
        tf.extractall(stage)

    for d in WHOLE_DIRS:
        p = os.path.join(stage, "opt", "roceos", d)
        if os.path.isdir(p):
            shutil.rmtree(p)
    for d in ("data", "logs"):
        p = os.path.join(stage, "opt", "roceos", d)
        if os.path.exists(p):
            shutil.rmtree(p)

    n_done, skipped = 0, []
    with tarfile.open(pkg_path) as tf:
        files = [m for m in tf.getmembers() if m.isfile()]
        top = files[0].name.split("/")[0] + "/" if files else ""
        for m in files:
            rel = (m.name[len(top):] if m.name.startswith(top) else m.name).replace("\\", "/")
            dst_rel = map_member(rel)
            if dst_rel is None:
                skipped.append(rel)
                continue
            data = tf.extractfile(m).read()
            dst = os.path.join(stage, dst_rel.replace("/", os.sep))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as f:
                f.write(data)
            os.chmod(dst, (m.mode & 0o777) or 0o644)
            n_done += 1
    log("  官方包覆盖 %d 个文件；跳过 %d 个（%s%s）"
        % (n_done, len(skipped), ", ".join(skipped[:6]), " …" if len(skipped) > 6 else ""))

    def norm(ti):
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        return ti

    entries = []
    for dirpath, dirnames, filenames in os.walk(stage):
        dirnames.sort()
        entries += [os.path.join(dirpath, d) for d in dirnames]
        entries += [os.path.join(dirpath, f) for f in sorted(filenames)]
    entries.sort()
    with tarfile.open(out_path, "w:gz", compresslevel=9) as tf:
        tf.add(stage, arcname=".", filter=norm, recursive=False)
        for e in entries:
            rel = os.path.relpath(e, stage).replace(os.sep, "/")
            tf.add(e, arcname="./" + rel, filter=norm, recursive=False)
    shutil.rmtree(work, ignore_errors=True)
    return out_path


def verify_payload(path, expect_version, expect_roceos_sha=None, log=print):
    with tarfile.open(path) as tf:
        names = set(tf.getnames())
        for n in ("./opt/roceos/roceos", "./opt/roceos/version.json",
                  "./opt/roceos-ai/server.py", "./etc/nginx/sites-available/roceos.conf"):
            if n not in names:
                raise SystemExit("!! 新载荷里缺 %s" % n)
        roceos = tf.extractfile("./opt/roceos/roceos").read()
        ver = json.loads(tf.extractfile("./opt/roceos/version.json").read().decode("utf-8"))
        size = tf.getmember("./opt/roceos/roceos").size
        if str(ver.get("version")) != str(expect_version):
            raise SystemExit("!! version.json=%s ≠ 目标 %s" % (ver.get("version"), expect_version))
        rsha = hashlib.sha256(roceos).hexdigest()
        if expect_roceos_sha and rsha != expect_roceos_sha:
            raise SystemExit("!! roceos 二进制 sha=%s ≠ 期望 %s" % (rsha, expect_roceos_sha))
        if any(n.startswith("./opt/roceos/data") or n.startswith("./opt/roceos/logs") for n in names):
            raise SystemExit("!! data/ 或 logs/ 被打进载荷了")
    log("  载荷自检：roceos=%s（%d B） version.json=%s，data/logs 未混入"
        % (rsha[:24], size, ver.get("version")))
    return rsha, size


def patch_pins(repo_dir, repo, old_sha, new_sha, old_url, new_url, kv, txt, header, log=print):
    ext = os.path.join(repo_dir, REPO_META[repo])
    s = open(ext, encoding="utf-8", newline="").read()
    if old_sha not in s:
        raise SystemExit("!! %s 里找不到旧 sha %s" % (ext, old_sha[:16]))
    open(ext, "w", encoding="utf-8", newline="").write(s.replace(old_sha, new_sha))

    wf = os.path.join(repo_dir, ".github/workflows/build.yml")
    s = open(wf, encoding="utf-8", newline="").read()
    if old_sha not in s or old_url not in s:
        raise SystemExit("!! %s 里找不到旧 sha 或旧 URL（pin 漂移，先人工对齐）" % wf)
    open(wf, "w", encoding="utf-8", newline="").write(s.replace(old_sha, new_sha).replace(old_url, new_url))

    write_kv(txt, kv, header)
    log("  三处 pin 已更新：%s / build.yml / official-roceos.txt" % os.path.basename(ext))


# ────────────────────────── main ──────────────────────────

def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, choices=sorted(REPO_META))
    ap.add_argument("--repo-dir", default=".")
    ap.add_argument("--out", default="roceos-payload.tar.gz")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", default=None, help="强制按指定版本重建（测试用，跳过版本比对）")
    a = ap.parse_args(argv)

    repo_dir = os.path.abspath(a.repo_dir)
    txt = os.path.join(repo_dir, "official-roceos.txt")
    kv = read_kv(txt)
    old_sha = kv.get("payload_sha256", "")
    old_url = kv.get("payload_url", "")
    cur = a.force or kv.get("version", "")
    if not cur or not old_sha or not old_url:
        print("!! official-roceos.txt 缺 version / payload_sha256 / payload_url", file=sys.stderr)
        return 2

    url, lat = query_latest(cur)
    latest = lat.get("version")
    print("  当前 pin=%s   官方(%s/%s) latest=%s" % (cur, CHANNEL, ARCH, latest or "（接口未给）"))
    if not latest:
        print("  接口没给 latest ⇒ 视为已是最新")
        return 0
    if latest == cur and not a.force:
        print("  已是最新，无需重建")
        return 0

    fn = lat.get("filename") or ("roceos-v%s-%s.tar.gz" % (latest, ARCH))
    want_sha, want_size = lat.get("sha256"), lat.get("size")
    pkg_url = "%s/api/v1/updates/packages/%s" % (BASE, fn)
    print("  官方包 %s\n         %s" % (fn, pkg_url))

    tmp = tempfile.mkdtemp(prefix="roceos-pkg.")
    pkg = os.path.join(tmp, fn)
    got = download(pkg_url, pkg)
    got_sha = sha256_file(pkg)
    print("  下载 %d B  sha256=%s" % (got, got_sha[:24]))
    if want_size and got != int(want_size):
        print("!! 大小不符：接口 %s / 实际 %d" % (want_size, got), file=sys.stderr)
        return 2
    if want_sha and got_sha != want_sha:
        print("!! sha256 不符：接口 %s / 实际 %s" % (want_sha, got_sha), file=sys.stderr)
        return 2
    print("  ✅ 与官方接口给的大小/哈希一致")

    prev = os.path.join(tmp, "prev-payload.tar.gz")
    print("  上一份载荷 %s" % old_url)
    download(old_url, prev)
    if sha256_file(prev) != old_sha:
        print("!! 上一份载荷 sha 与 official-roceos.txt 记录不符", file=sys.stderr)
        return 2

    if a.dry_run:
        print("  --dry-run：探测与校验都通过，未生成新载荷")
        return 0

    out = os.path.join(repo_dir, a.out)
    build_payload(prev, pkg, out)
    new_sha = sha256_file(out)
    roceos_sha, roceos_size = verify_payload(out, latest)
    size = os.path.getsize(out)
    print("  新载荷 %.1f MiB  sha256=%s" % (size / 1048576, new_sha))

    new_tag = "roceos-payload-%s" % latest
    new_url = ("https://github.com/linyueweia/%s/releases/download/%s/roceos-payload.tar.gz"
               % (a.repo, new_tag))

    kv2 = dict(kv)
    kv2.update({
        "version": str(latest),
        "channel": "stable_arm（设备显示「稳定版」）",
        "arch": ARCH,
        "payload": new_tag,
        "payload_url": new_url,
        "payload_sha256": new_sha,
        "roceos_sha256": roceos_sha,
        "roceos_size": str(roceos_size),
        "synced_from": pkg_url,
    })
    header = [
        "# 本仓镜像内置的 roceos（iNextOS 网页后台）版本 —— 由 .github/workflows/sync-roceos.yml 自动维护。",
        "# 查版本：GET " + BASE + "/api/v1/updates/check?version=<当前>&channel=stable_arm&arch=arm64",
        "# 取包：  GET " + BASE + "/api/v1/updates/packages/<filename>（sha256 由接口给，脚本会校验）",
        "# 重建：  python3 tools/roceos-sync.py --repo <本仓>（四仓各一份，只用 GITHUB_TOKEN）",
        "# 别手改 version/payload_sha256/payload_url —— 下次同步会覆盖；要钉死请停用 sync 工作流。",
    ]
    # 保留原文件里人手写的解释性注释（历史取证备注），别被自动重写冲掉
    try:
        old_header = [l.rstrip() for l in open(txt, encoding="utf-8") if l.startswith("#")]
    except OSError:
        old_header = []
    for l in old_header:
        if l not in header:
            header.append(l)
    patch_pins(repo_dir, a.repo, old_sha, new_sha, old_url, new_url, kv2, txt, header)

    env = os.path.join(repo_dir, ".roceos-sync.env")
    with open(env, "w", encoding="utf-8", newline="\n") as f:
        for k, v in (("NEW_VERSION", latest), ("NEW_TAG", new_tag), ("NEW_URL", new_url),
                     ("NEW_SHA", new_sha), ("ROCEOS_SHA", roceos_sha), ("PKG_FILENAME", fn)):
            f.write("%s=%s\n" % (k, v))
    print("  已写好 %s 与三处 pin；产物留在 %s（由 workflow 上传）" % (os.path.basename(env), a.out))
    return 10


if __name__ == "__main__":
    sys.exit(main())
