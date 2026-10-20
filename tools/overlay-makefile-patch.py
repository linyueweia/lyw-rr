#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# 把本仓自带的内核 overlay（config/overlays/*.dtso）登记进框架的 overlay Makefile
#
# 背景（2026-10-19 lyw-rr run #21：镜像 4.7GiB 编好、产物已上传，倒在自证上一行）：
#   框架的 arch/arm64/boot/dts/rockchip/overlay/Makefile 是【显式枚举】每个 dtbo 的：
#
#       dtbo-$(CONFIG_ARCH_ROCKCHIP) += \
#           rockchip-rk3568-nanopi-r5s-leds.dtbo \
#           ...
#       dtb-y += $(dtbo-y) $(scr-y) $(dtbotxt-y)
#
#   armbian 的 "Bare OVERLAY auto-patch" 只把
#   patch/kernel/archive/<family>-<ver>/overlay/ 里的【文件】原样拷进内核树
#   （连 Makefile 一起拷），它【不会】为新加的 .dtso 补登记。
#   ⇒ 我们只拷 .dtso 不登记，结果只有 leds 被 DTC 编译（上游那行在 Makefile 里），
#     fan 不编译 → 镜像里没有 rockchip-rk3568-nanopi-r5s-fan.dtbo：
#     自证判红，而且风扇根本没有 cooling device（功能性缺口，不只是断言）。
#
# 本脚本做的事（每个含本仓 dtso 的 rockchip64-* 分支都做）：
#   1. 找到 <archive>/rockchip64-*/overlay/ 里与本仓同名、真实存在的 .dtso；
#   2. 断言该目录有 Makefile（没有就是结构变了，直接失败，别静默跳过）；
#   3. 确保同名 .dtbo 在 dtbo-$(CONFIG_…) 列表里【恰好一次】（缺则插入，幂等）；
#   4. 断言 Makefile 里有 `dtb-y … $(dtbo-y)`（否则登记了也不会编译）；
#   5. 打印每个分支的处理结果，异常一律 rc=1。
#
# 用法：
#   overlay-makefile-patch.py <archive_root> [--overlay-src DIR] [--check]
#     <archive_root>  = build/patch/kernel/archive
#     --overlay-src   = 本仓 config/overlays（默认按脚本位置推导）
#     --check         = 只检查不写（缺登记则 rc=1，用于 lint / 自测）
#
# 退出码：0 = 全部就绪；1 = 有缺登记或结构异常。
# ─────────────────────────────────────────────────────────────────────────────
import argparse
import glob
import os
import re
import sys

VAR_RE = re.compile(r"^[ \t]*dtbo-\$\(([A-Za-z0-9_]+)\)[ \t]*\+=", re.MULTILINE)
DTB_Y_RE = re.compile(r"^[ \t]*dtb-y[ \t]*\+?=.*\$\(dtbo-y\)", re.MULTILINE)
DTB_Y_ANY_RE = re.compile(r"^[ \t]*dtb-y[ \t]*\+?=", re.MULTILINE)


def entry_count(text: str, name: str) -> int:
    """统计 `<name>.dtbo` 作为独立词出现的次数（不会被 xxx-<name>.dtbo 误命中）。"""
    pat = re.compile(r"(?<![\w.\-])" + re.escape(name) + r"\.dtbo(?![\w.\-])")
    return len(pat.findall(text))


def default_overlay_src() -> str:
    here = os.path.dirname(os.path.abspath(__file__))          # <repo>/tools
    return os.path.join(os.path.dirname(here), "config", "overlays")


def process(overlay_dir: str, dtso_names, check_only: bool):
    """返回 (changed, errors)。errors 是字符串列表，非空即失败。"""
    errors = []
    changed = False
    makefile = os.path.join(overlay_dir, "Makefile")
    present = [n for n in dtso_names if os.path.isfile(os.path.join(overlay_dir, n))]
    if not present:
        return changed, errors

    if not os.path.isfile(makefile):
        return changed, [f"{overlay_dir}: 有本仓 dtso 但没有 Makefile（框架结构变了？）"]

    with open(makefile, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    eol = "\r\n" if "\r\n" in text else "\n"

    if not DTB_Y_RE.search(text):
        # 没有 dtb-y 聚合行，登记了也不编译 —— 必须失败，不能假绿
        return changed, [f"{makefile}: 缺 `dtb-y … $(dtbo-y)` 聚合行（dtbo 不会进 dtb-y）"]

    var_of = VAR_RE.findall(text)
    if not var_of:
        return changed, [f"{makefile}: 找不到 `dtbo-$(CONFIG_…) +=` 列表"]
    var = var_of[0]

    for name in sorted(present):
        base = name[:-len(".dtso")] if name.endswith(".dtso") else name
        n = entry_count(text, base)
        if n == 1:
            print(f"  OK   {base}.dtbo 已登记（{overlay_dir}）")
            continue
        if n > 1:
            errors.append(f"{makefile}: {base}.dtbo 被重复登记 {n} 次")
            continue
        if check_only:
            errors.append(f"{makefile}: 未登记 {base}.dtbo（只拷 dtso 不会编译）")
            continue
        # 插在 dtb-y 聚合行【之前】（之后写就没意义了）
        line = f"dtbo-$({var}) += {base}.dtbo"
        lines = text.splitlines(keepends=True)
        out, done = [], False
        for ln in lines:
            if not done and DTB_Y_ANY_RE.match(ln):
                out.append(line + eol)
                done = True
            out.append(ln)
        if not done:
            if out and not out[-1].endswith(("\n", "\r")):
                out[-1] += eol
            out.append(line + eol)
        text = "".join(out)
        with open(makefile, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        changed = True
        n2 = entry_count(text, base)
        if n2 != 1:
            errors.append(f"{makefile}: 插入 {base}.dtbo 后计数为 {n2}（应为 1）")
        else:
            print(f"  ADD  {base}.dtbo 已登记（{overlay_dir}）")
    return changed, errors


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("archive_root", help="build/patch/kernel/archive")
    ap.add_argument("--overlay-src", default=None, help="本仓 config/overlays（默认推导）")
    ap.add_argument("--check", action="store_true", help="只检查不写")
    a = ap.parse_args()

    src = a.overlay_src or default_overlay_src()
    if not os.path.isdir(src):
        print(f"!! 找不到 overlay 源目录: {src}", file=sys.stderr)
        return 1
    dtso_names = sorted(os.path.basename(p) for p in glob.glob(os.path.join(src, "*.dtso")))
    if not dtso_names:
        print(f"!! {src} 里没有 .dtso", file=sys.stderr)
        return 1

    dirs = sorted(glob.glob(os.path.join(a.archive_root, "rockchip64-*", "overlay")))
    if not dirs:
        print(f"!! {a.archive_root} 下没有 rockchip64-*/overlay", file=sys.stderr)
        return 1

    print(f"本仓 overlay: {', '.join(dtso_names)}")
    print(f"框架 overlay 目录: {len(dirs)} 个" + ("（--check 只读）" if a.check else ""))
    errors, touched, seen = [], [], 0
    for d in dirs:
        changed, errs = process(d, dtso_names, a.check)
        errors.extend(errs)
        if changed:
            touched.append(d)
        if any(os.path.isfile(os.path.join(d, n)) for n in dtso_names):
            seen += 1

    if seen == 0:
        print("!! 没有任何 rockchip64-*/overlay 目录含本仓 dtso（注入步骤没跑？）", file=sys.stderr)
        return 1

    if errors:
        print("\n!! 失败：", file=sys.stderr)
        for e in errors:
            print("   - " + e, file=sys.stderr)
        return 1

    print(f"\n== overlay Makefile 登记就绪：{seen} 个分支覆盖本仓 dtso"
          + (f"，本次写入 {len(touched)} 个 Makefile" if touched else "（无需改动）") + " ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
