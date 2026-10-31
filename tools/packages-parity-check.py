#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
packages-parity-check.py —— 「镜像包集合 = 官方 minimal 口径」的单一判据点。

背景（2026-10-31 rr/hh 两仓同时红在自证最后一步，各 15 条）：
    旧写法把框架的 `config/cli/<rel>/main/packages.additional` 整份当黑名单，
    只要某个成员出现在镜像 dpkg 里就判红。这条判据本身是错的 ——
    packages.additional 的成员至少有四个【官方 minimal 镜像里同样存在】的合法来源：

      ① 框架自己的 rootfs 包清单里也列了它（aggregate 后叫 AGGREGATED_PACKAGES_ROOTFS，
         来自 config/cli/<rel>/main/packages + config/optional/_any_board/_config/… +
         config/optional/architectures/<arch>/_config/… 三层合并）
         —— 例：sudo / wget / bash-completion / htop / wireless-regdb / **gpiod**
            （gpiod 只在 `config/optional/architectures/arm64/_config/cli/trixie/main/packages`
             里，只看 config/cli/<rel>/main/packages 会误判成「多出来的包」）
      ② 上游 `extensions/istorenext.sh` 的 add_packages_to_image 带进来的
         —— 例：git / unzip / ntfs-3g / nfs-common / smartmontools / wget
      ③ ①② 的 Depends/Recommends 传递依赖
         —— 例：keyboard-configuration ← console-setup；libpam-systemd ← systemd；
                iptables ← docker.io；apt-utils ← apt 相关包
      ④ apt 记为 Auto-Installed 的依赖（镜像里若保留 /var/lib/apt/extended_states）
    ⇒ BUILD_MINIMAL=yes 明明生效了，旧判据照样打出 15 条红，整轮构建白跑。

真正要守的性质只有一条：
    **packages.additional 里那些「只能靠 BUILD_MINIMAL=no 才会进镜像」的包，
    不许以【手工安装】身份出现在镜像里。**

判据 = 来源减法（全部取自构建树原文，不抄第二份名单）：
    出现 ∩ ¬rootfs清单 ∩ ¬扩展 add_packages_to_image ∩ ¬依赖闭包 ∩ ¬apt auto ⇒ 违规

用法：
    # 推荐：直接从构建树复现框架的聚合口径（不需要 CI 传一堆路径）
    python3 tools/packages-parity-check.py --root /mnt/ir --build-tree build \
        --release trixie --arch arm64

    # 也可以显式给清单文件
    python3 tools/packages-parity-check.py --root /mnt/ir \
        --additional <packages.additional> --base <packages> \
        --extension build/extensions/istorenext.sh

    python3 tools/packages-parity-check.py --selftest

退出码：0 = 通过；1 = 有成员无合法来源（BUILD_MINIMAL 没生效 / 有人手工装了 additional 包）；
        2 = 输入缺失或不可解析（不给出「绿」的假结论）。
"""

import argparse
import io
import os
import re
import shutil
import sys
import tempfile

# ─────────────────────── 复现框架的 CLI 包清单聚合 ───────────────────────
# 与 lib/tools/aggregation.py 的 AGGREGATION_SEARCH_ROOT_ABSOLUTE_DIRS +
# CLI_SEARCH_RELATIVE_DIRS 同构（cli/_all_distributions/main 与 cli/<rel>/main）。
CLI_RELATIVE_DIRS = ("cli/_all_distributions/main", "cli/{release}/main")


def aggregate_search_roots(build_tree, arch, userpatches_path=None):
    roots = [
        os.path.join(build_tree, "config"),
        os.path.join(build_tree, "config/optional/_any_board/_config"),
        os.path.join(build_tree, "config/optional/architectures/%s/_config" % arch),
    ]
    if userpatches_path and os.path.isdir(userpatches_path):
        roots.append(userpatches_path)
    return roots


def aggregate_list(build_tree, fname, release, arch, userpatches_path=None):
    """把框架会合并的所有同名清单取并集（包清单是集合语义）。"""
    found = set()
    for root in aggregate_search_roots(build_tree, arch, userpatches_path):
        for rel in CLI_RELATIVE_DIRS:
            path = os.path.join(root, rel.format(release=release), fname)
            if os.path.isfile(path):
                found |= set(read_list_file(path))
    return found


# ─────────────────────────── 解析工具 ───────────────────────────


def read_list_file(path):
    """包清单：一行一个包名，忽略空行与 # 注释，容忍行尾注释。"""
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            out.append(line)
    return out


def extension_added_packages(paths):
    """从扩展源码里抽 add_packages_to_image 的包名（拼续行后按逻辑行切词）。"""
    pkgs = set()
    for path in paths:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        text = re.sub(r"\\\r?\n", " ", text)
        for line in text.splitlines():
            m = re.search(r"\badd_packages_to_image\b(.*)$", line)
            if not m:
                continue
            rest = m.group(1).split("#", 1)[0]
            for tok in rest.split():
                if not tok or tok.startswith("-"):
                    continue
                if any(ch in tok for ch in "$=${}()\"'"):
                    continue
                pkgs.add(tok)
    return pkgs


def _dep_names(field_value):
    names = set()
    for group in field_value.split(","):
        for alt in group.split("|"):
            alt = alt.strip()
            if not alt:
                continue
            name = re.split(r"[\s(\[:]", alt, maxsplit=1)[0].strip()
            if name:
                names.add(name)
    return names


def read_dpkg_status(path):
    """返回 (installed:set, deps:dict[pkg]->set)；只收 install ok installed。"""
    installed, deps = set(), {}
    if not os.path.isfile(path):
        return installed, deps
    cur = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip():
                _commit(cur, installed, deps)
                cur = {}
                continue
            if line.startswith((" ", "\t")):
                continue
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            cur[k.strip()] = v.strip()
    _commit(cur, installed, deps)
    return installed, deps


def _commit(stanza, installed, deps):
    pkg = stanza.get("Package")
    if not pkg:
        return
    if "install ok installed" not in stanza.get("Status", ""):
        return
    installed.add(pkg)
    names = set()
    for f in ("Pre-Depends", "Depends", "Recommends"):
        if stanza.get(f):
            names |= _dep_names(stanza[f])
    deps.setdefault(pkg, set()).update(names)


def read_auto_installed(path):
    auto, cur_pkg = set(), None
    if not os.path.isfile(path):
        return auto
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip():
                cur_pkg = None
                continue
            if line.startswith("Package:"):
                cur_pkg = line.split(":", 1)[1].strip()
            elif line.startswith("Auto-Installed:") and cur_pkg:
                if line.split(":", 1)[1].strip() in ("1", "yes", "true"):
                    auto.add(cur_pkg)
    return auto


def dependency_closure(roots, deps, installed):
    """从 roots 出发沿 Depends/Recommends 求可达集合（只走镜像里真装了的包）。"""
    seen, stack = set(), [p for p in roots if p in installed]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        for nxt in deps.get(p, ()):
            if nxt in installed and nxt not in seen:
                stack.append(nxt)
    return seen


# ─────────────────────────── 判据本体 ───────────────────────────


def check(root, additional, base, extension_files, out=sys.stdout, trace=False):
    status_path = os.path.join(root, "var/lib/dpkg/status")
    if not os.path.isfile(status_path):
        print("  !!  %s 不存在 —— 无法核对包集合口径（不给假绿）" % status_path, file=out)
        return 2
    installed, deps = read_dpkg_status(status_path)
    if not installed:
        print("  !!  %s 里没有任何 installed 包 —— 解析失败，不给假绿" % status_path, file=out)
        return 2
    if not additional:
        print("  !!  packages.additional 清单为空/不存在 —— 不给假绿", file=out)
        return 2

    ext_added = extension_added_packages(extension_files or [])
    auto = read_auto_installed(os.path.join(root, "var/lib/apt/extended_states"))
    closure = dependency_closure(set(base) | ext_added, deps, installed)

    present = [p for p in sorted(additional) if p in installed]
    by_base, by_ext, by_dep, by_auto, violations = [], [], [], [], []
    for p in present:
        if p in base:
            by_base.append(p)
        elif p in ext_added:
            by_ext.append(p)
        elif p in closure:
            by_dep.append(p)
        elif p in auto:
            by_auto.append(p)
        else:
            violations.append(p)

    print("       packages.additional: %d 个成员，镜像里出现 %d 个（镜像共 %d 包）"
          % (len(additional), len(present), len(installed)), file=out)
    if by_base:
        print("       · 框架 rootfs 清单本身就有（官方 minimal 同款）: %s"
              % " ".join(by_base), file=out)
    if by_ext:
        print("       · 扩展 add_packages_to_image 带入（官方 istorenext 同款）: %s"
              % " ".join(by_ext), file=out)
    if by_dep:
        print("       · 依赖/推荐传递带入: %s" % " ".join(by_dep), file=out)
    if by_auto:
        print("       · apt Auto-Installed: %s" % " ".join(by_auto), file=out)
    if not os.path.isfile(os.path.join(root, "var/lib/apt/extended_states")):
        print("       （镜像里没有 /var/lib/apt/extended_states；auto 这条来源不可用，"
              "依赖闭包仍生效）", file=out)
    if trace:
        for p in by_dep:
            print("       ~ 依赖链: %s" % _explain(p, base, ext_added, deps, installed), file=out)

    if violations:
        print("  !!  packages.additional 成员进了镜像且没有合法来源（%d 条）: %s"
              % (len(violations), " ".join(violations)), file=out)
        print("       ⇒ BUILD_MINIMAL 应为 yes；或有人在构建期/镜像里手工装了 additional 包。"
              "两者都与官方 minimal 口径不一致。", file=out)
        return 1

    print("  OK   packages.additional %d 个成员全部有合法来源"
          "（BUILD_MINIMAL=yes 生效，与官方 minimal 同口径）" % len(additional), file=out)
    return 0


def _explain(target, base, ext_added, deps, installed):
    """给 target 找一条从 root（base/扩展）出发的依赖路径，用于日志取证。"""
    roots = (set(base) | ext_added) & installed
    prev, seen = {}, set(roots)
    stack = list(roots)
    while stack:
        p = stack.pop()
        if p == target:
            break
        for nxt in deps.get(p, ()):
            if nxt in installed and nxt not in seen:
                seen.add(nxt)
                prev[nxt] = p
                stack.append(nxt)
    if target not in seen:
        return "%s（找不到来源链）" % target
    chain, cur = [target], target
    while cur in prev:
        cur = prev[cur]
        chain.append(cur)
    return " ← ".join(chain)


# ─────────────────────────── 负例自测 ───────────────────────────

BASE_FIXTURE = "# base\nsudo\nwget\nconsole-setup\nsystemd\ndocker.io\ngpiod\n"
ADDITIONAL_FIXTURE = (
    "# additional\nsudo\nwget\ngpiod\ngit\nsmartmontools\nkeyboard-configuration\n"
    "libpam-systemd\niptables\navahi-autoipd\nbuild-essential\nunattended-upgrades\n"
)
EXT_FIXTURE = (
    "function extension_prepare_config__x() {\n"
    "\tadd_packages_to_image python3-pip nginx \\\n"
    "\t\tgit smartmontools unzip wget\n"
    "}\n"
)


def _stanza(pkg, deps=None, rec=None):
    lines = ["Package: %s" % pkg, "Status: install ok installed",
             "Architecture: arm64", "Version: 1.0"]
    if deps:
        lines.append("Depends: %s" % deps)
    if rec:
        lines.append("Recommends: %s" % rec)
    return "\n".join(lines) + "\n\n"


def _mkroot(tmp, status_text, auto_pkgs=(), with_status=True):
    os.makedirs(tmp + "/var/lib/dpkg", exist_ok=True)
    if with_status:
        open(tmp + "/var/lib/dpkg/status", "w", encoding="utf-8").write(status_text)
    os.makedirs(tmp + "/var/lib/apt", exist_ok=True)
    open(tmp + "/var/lib/apt/extended_states", "w", encoding="utf-8").write(
        "".join("Package: %s\nArchitecture: arm64\nAuto-Installed: 1\n\n" % p for p in auto_pkgs))
    return tmp


def selftest():
    tmpd = tempfile.mkdtemp(prefix="pkgparity.")
    fails = []
    try:
        base = os.path.join(tmpd, "packages")
        add = os.path.join(tmpd, "packages.additional")
        ext = os.path.join(tmpd, "istorenext.sh")
        open(base, "w", encoding="utf-8").write(BASE_FIXTURE)
        open(add, "w", encoding="utf-8").write(ADDITIONAL_FIXTURE)
        open(ext, "w", encoding="utf-8").write(EXT_FIXTURE)
        base_set = set(read_list_file(base))
        add_set = set(read_list_file(add))

        def run(name, status, expect, auto=(), with_status=True):
            r = _mkroot(os.path.join(tmpd, "root." + re.sub(r"\W+", "_", name)),
                        status, auto, with_status)
            buf = io.StringIO()
            rc = check(r, add_set, base_set, [ext], out=buf)
            got = "pass" if rc == 0 else ("violation" if rc == 1 else "input-error")
            print("  %s %-44s 期望=%-12s 实际=%-12s"
                  % ("✓" if got == expect else "✗", name, expect, got))
            if got != expect:
                fails.append(name)
                print(buf.getvalue())

        # 正例（= 2026-10-31 真实镜像的形态：base / 扩展 / 依赖 三类全覆盖）
        good = (_stanza("sudo") + _stanza("wget") + _stanza("gpiod") + _stanza("git")
                + _stanza("smartmontools") + _stanza("unzip")
                + _stanza("console-setup", deps="keyboard-configuration")
                + _stanza("systemd", rec="libpam-systemd")
                + _stanza("docker.io", deps="iptables")
                + _stanza("keyboard-configuration") + _stanza("libpam-systemd")
                + _stanza("iptables"))
        run("正例：base+扩展+依赖全覆盖（= 真实镜像形态）", good, "pass",
            auto=("keyboard-configuration", "iptables"))
        run("正例：一个 additional 成员都没有", _stanza("sudo"), "pass", auto=())
        run("正例：只靠 apt Auto-Installed 解释",
            _stanza("sudo") + _stanza("keyboard-configuration"), "pass",
            auto=("keyboard-configuration",))

        # 负例 1：BUILD_MINIMAL=no 形态（整份 additional 进镜像）
        full = (good + _stanza("avahi-autoipd") + _stanza("build-essential")
                + _stanza("unattended-upgrades"))
        run("负例：整份 additional 进镜像", full, "violation",
            auto=("keyboard-configuration",))
        run("负例：手工装 avahi-autoipd", _stanza("sudo") + _stanza("avahi-autoipd"),
            "violation")
        run("负例：unattended-upgrades 无来源",
            _stanza("sudo") + _stanza("unattended-upgrades"), "violation")
        run("负例：rootfs 里没有 dpkg/status", "", "input-error", with_status=False)
        run("负例：dpkg/status 里 0 个 installed 包",
            "Package: x\nStatus: deinstall ok config-files\n\n", "input-error")

        buf = io.StringIO()
        r = _mkroot(os.path.join(tmpd, "root.emptyadd"), _stanza("sudo"))
        rc = check(r, set(), base_set, [ext], out=buf)
        got = "input-error" if rc == 2 else ("pass" if rc == 0 else "violation")
        print("  %s %-44s 期望=%-12s 实际=%-12s"
              % ("✓" if got == "input-error" else "✗", "负例：additional 清单为空",
                 "input-error", got))
        if got != "input-error":
            fails.append("empty-additional")

        # 聚合口径自测：gpiod 只在 config/optional/architectures/<arch>/_config 里
        fake_tree = os.path.join(tmpd, "tree")
        for rel, content in (
            ("config/cli/trixie/main/packages", "sudo\n"),
            ("config/optional/architectures/arm64/_config/cli/trixie/main/packages", "gpiod\n"),
            ("config/optional/_any_board/_config/cli/trixie/main/packages", "wget\n"),
        ):
            p = os.path.join(fake_tree, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w", encoding="utf-8").write(content)
        agg = aggregate_list(fake_tree, "packages", "trixie", "arm64")
        ok_agg = agg == {"sudo", "gpiod", "wget"}
        print("  %s %-44s 期望=%s 实际=%s"
              % ("✓" if ok_agg else "✗", "聚合口径：三层清单要合并",
                 "{gpiod,sudo,wget}", sorted(agg)))
        if not ok_agg:
            fails.append("aggregate")

        print()
        if fails:
            print("自测失败 %d 例: %s" % (len(fails), ", ".join(fails)))
            return 1
        print("自测全部通过（3 正例 + 6 负例 + 1 聚合口径）")
        return 0
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description="镜像包集合 vs 官方 minimal 口径")
    ap.add_argument("--root", help="已挂载的 rootfs（读 var/lib/dpkg/status）")
    ap.add_argument("--build-tree", help="框架源码树（复现包清单聚合，推荐）")
    ap.add_argument("--release", default="trixie")
    ap.add_argument("--arch", default="arm64")
    ap.add_argument("--userpatches", default=None, help="USERPATCHES_PATH（可选）")
    ap.add_argument("--additional", default=None, help="显式指定 packages.additional 文件")
    ap.add_argument("--base", action="append", default=[], help="显式指定 rootfs 包清单（可多次）")
    ap.add_argument("--extension", action="append", default=[],
                    help="启用的扩展源码（可多次；识别 add_packages_to_image 带入的包）")
    ap.add_argument("--base-manifest", default=None,
                    help="可选：一行一个包名的 rootfs 清单快照")
    ap.add_argument("--trace", action="store_true", help="对依赖带入的包打印来源链")
    ap.add_argument("--selftest", action="store_true", help="跑判据自身的正/负例自测")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()
    if not a.root:
        ap.error("需要 --root（或用 --selftest）")

    additional, base = set(), set()
    if a.base_manifest:
        base |= set(read_list_file(a.base_manifest))
    for f in a.base:
        base |= set(read_list_file(f))
    if a.build_tree:
        base |= aggregate_list(a.build_tree, "packages", a.release, a.arch, a.userpatches)
        additional |= aggregate_list(a.build_tree, "packages.additional",
                                     a.release, a.arch, a.userpatches)
        if not additional:
            print("  !! 在 %s 里没找到 packages.additional（release=%s arch=%s）"
                  % (a.build_tree, a.release, a.arch), file=sys.stderr)
            return 2
    if a.additional:
        additional |= set(read_list_file(a.additional))
    if not additional:
        print("  !! 没有可用的 packages.additional（--build-tree 或 --additional 二选一）",
              file=sys.stderr)
        return 2
    return check(a.root, additional, base, a.extension, trace=a.trace)


if __name__ == "__main__":
    sys.exit(main())
