#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""NanoPi R5S 网口角色映射（ROLE_MAP）判据 —— 单点真源（policy as code）

同一份判据，两个检查点：
  ① 构建早期（秒级，红得便宜）:  --src extensions/lyw-rr-net-roles.sh
     读「扩展将要写进镜像的默认 ROLE_MAP」；
  ② 镜像自证（产物级，最后一道门）: --conf <rootfs>/etc/lyw-rr-net-roles.conf
     读「镜像里实际落盘的那一份」。

本板口径（2026-10-17 定案，见 README）：
  · 板载千兆 eth0（fe2a0000.ethernet，丝印 WAN）= 必须是【单口】wan 角色；
  · 两个 2.5G eth1/eth2（PCIe domain0/1）必须同属【同一个】lan 角色（同一网桥，
    插任一口都能进 192.168.100.1）；
  · 三个口各出现且仅出现一次 —— 漏口 = 那个口插线什么都通不了；重复 = 两口争用。

为什么断言语义而不是字面量（2026-10-17 run #14 的事故）：
  默认值从「wan1/lan1/lan2 三口各自一个角色」改成「wan1=eth0 lan1=eth1,eth2」时，
  verify-image.sh 里还留着 `grep -q 'lan2=eth2'` → 镜像 4.7 GB 全部断言绿、只这一行红，
  117 分钟构建白跑。凡「某次定案的字符串」都不该出现在断言里，只该断言它的语义。
  同一类事故的成本极高，所以 --src 模式还会拒绝「把 ROLE_MAP 字面量再写死一份」的做法
  （自检/文档里复制一份值 = 下次改默认值必然漏改）。
"""

import argparse
import re
import sys

OK = "  OK   "
BAD = "  !!   "

# 扩展源码里的默认值赋值行（行级锚定：避免把 startswith("ROLE_MAP=") 这种代码当字面量）
ASSIGN_RE = re.compile(r'^[ \t]*ROLE_MAP="([^"]*)"[ \t]*$', re.M)
# 行内任意位置的 ROLE_MAP="..."（用来发现「值被复制了第二份」）
LITERAL_RE = re.compile(r'ROLE_MAP="([^"]*)"')
# 像一条真映射的值（wan1=eth0 lan1=eth1,eth2），用来排除代码片段里的假命中
MAP_SHAPE_RE = re.compile(r'[A-Za-z0-9_]+\s*=\s*eth\d+(?:[,\s+]+[A-Za-z0-9_]+\s*=\s*eth\d+)*')


def parse_role_map(raw):
    """与镜像里 /usr/local/sbin/lyw-rr-net-roles.py 的 want_map() 逐字同语义：
    空格分角色、'=' 左角色名右端口、逗号或 '+' 分同桥多口。"""
    roles = {}
    order = []
    for item in raw.split():
        if "=" not in item:
            continue
        k, v = item.split("=", 1)
        k = k.strip()
        if not k:
            continue
        devs = [x for x in v.replace("+", ",").split(",") if x]
        roles[k] = devs
        order.append(k)
    return roles, order


def read_conf(path):
    raw = ""
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s.startswith("ROLE_MAP="):
                raw = s.split("=", 1)[1].strip().strip('"')
    return raw


def read_src(path):
    """从扩展源码里取「将要写进镜像的默认 ROLE_MAP」。
    另外检查它是否被复制成第二份字面量（自检 grep / 注释里的同一串值）——
    默认值一旦有两份，改一份漏一份就是 run #14 那类事故。"""
    txt = open(path, encoding="utf-8").read()
    assigns = ASSIGN_RE.findall(txt)
    if not assigns:
        return None, "扩展里找不到默认值赋值行  ROLE_MAP=\"...\"（heredoc 被改坏了？）"
    if len(assigns) > 1:
        return None, ("默认值赋值行出现 %d 次（%s）—— 只能有一处默认值"
                      % (len(assigns), " / ".join(assigns)))
    raw = assigns[0]
    # 行内的 ROLE_MAP="..." 出现次数（含上面那条赋值）：>1 说明值被复制到了自检/注释里
    lits = [m.strip() for m in LITERAL_RE.findall(txt) if MAP_SHAPE_RE.match(m.strip())]
    if len(lits) > 1:
        return None, ("同一条 ROLE_MAP 字面量在扩展里出现 %d 次（%s）—— 值被复制到了自检/注释里，"
                      "改默认值时必然漏改一处。自检请改成语义检查（本脚本 --conf 模式）"
                      % (len(lits), " | ".join(sorted(set(lits)))))
    return raw, None


def check(raw, gig, lan_ports):
    fails = []
    notes = []

    def fail(msg):
        fails.append(msg)

    roles, order = parse_role_map(raw)
    if not roles:
        fail("ROLE_MAP 为空或无法解析：%r" % raw)
        return fails, notes, roles
    notes.append("ROLE_MAP = %s" % " ".join("%s=%s" % (k, ",".join(roles[k])) for k in order))

    # 端口名合法性
    all_ports = [p for k in order for p in roles[k]]
    for k in order:
        if not roles[k]:
            fail("角色 %s 没有成员口（空角色会让 roceos 建出空网桥）" % k)
    for p in all_ports:
        if not re.fullmatch(r"eth\d+", p):
            fail("端口名不是 ethN：%r（udev/eth_order 只产出 ethN）" % p)

    expected = [gig] + list(lan_ports)

    # 覆盖：每个口都必须有角色
    missing = [p for p in expected if p not in all_ports]
    if missing:
        fail("漏口：%s 没有任何角色（插上这个口什么都不通，等于少一个网口）" % "、".join(missing))
    extra = [p for p in all_ports if p not in expected]
    if extra:
        fail("出现本板不存在的端口：%s（本板只有 %s）" % ("、".join(sorted(set(extra))), "、".join(expected)))
    dups = sorted({p for p in all_ports if all_ports.count(p) > 1})
    if dups:
        fail("端口被多个角色同时占用：%s（两口争用，后建的网桥会把口抢走）" % "、".join(dups))
    if not missing and not extra and not dups:
        notes.append("三口各出现一次：%s" % " / ".join(expected))

    # WAN：板载千兆，单口
    wan_roles = [k for k in order if gig in roles[k]]
    if not wan_roles:
        fail("%s（板载千兆/丝印 WAN）没有任何 wan 角色" % gig)
    elif len(wan_roles) > 1:
        fail("%s 同时属于多个角色：%s" % (gig, "、".join(wan_roles)))
    else:
        k = wan_roles[0]
        if not k.startswith("wan"):
            fail("%s 落在角色 %s 里，但角色名不是 wan*（网页后台的 WAN 面板会对不上）" % (gig, k))
        elif len(roles[k]) != 1:
            fail("WAN 角色 %s 含 %d 个口（%s）：WAN 必须单口，否则 1G 与 2.5G 被塞进同一个桥"
                 % (k, len(roles[k]), ",".join(roles[k])))
        else:
            notes.append("WAN：%s = %s（板载千兆，单口）" % (k, gig))

    # LAN：两个 2.5G 同桥
    lan_roles = []
    for k in order:
        if all(p in roles[k] for p in lan_ports):
            lan_roles.append(k)
    if not lan_roles:
        holders = {}
        for k in order:
            for p in roles[k]:
                if p in lan_ports:
                    holders.setdefault(p, []).append(k)
        fail("两个 2.5G（%s）没有被放进同一个桥：%s —— 插另一个 2.5G 口就进不了 192.168.100.1"
             % ("、".join(lan_ports),
                " / ".join("%s→%s" % (p, ",".join(holders.get(p, ["无角色"]))) for p in lan_ports)))
    else:
        k = lan_roles[0]
        if not k.startswith("lan"):
            fail("两个 2.5G 在角色 %s 里，但角色名不是 lan*" % k)
        elif set(roles[k]) != set(lan_ports):
            fail("LAN 桥 %s 的成员 = %s，期望恰好是 %s（多了别的口会被 1G 口拖住）"
                 % (k, ",".join(roles[k]), ",".join(lan_ports)))
        else:
            notes.append("LAN：%s = %s（两个 2.5G 同桥，插任一口都能进 192.168.100.1）"
                         % (k, "+".join(lan_ports)))

    return fails, notes, roles


def main():
    ap = argparse.ArgumentParser(description="NanoPi R5S ROLE_MAP 判据（构建早期 + 镜像自证共用）")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--conf", help="镜像里的 /etc/lyw-rr-net-roles.conf")
    src.add_argument("--src", help="仓库里的 extensions/lyw-rr-net-roles.sh（读其默认 ROLE_MAP）")
    ap.add_argument("--gig", default="eth0", help="板载千兆（丝印 WAN）口名，默认 eth0")
    ap.add_argument("--lan-members", default="eth1,eth2", help="同桥的两个 2.5G 口，默认 eth1,eth2")
    a = ap.parse_args()
    lan_ports = [x for x in a.lan_members.split(",") if x]

    if a.src:
        raw, err = read_src(a.src)
        if err:
            print(BAD + err)
            return 1
        print("       来源: %s 的默认 ROLE_MAP" % a.src)
    else:
        raw = read_conf(a.conf)
        print("       来源: %s" % a.conf)

    fails, notes, _ = check(raw, a.gig, lan_ports)
    if notes:
        print("       " + notes[0])          # 回显解析出的 ROLE_MAP
    for n in notes[1:]:                      # 逐项通过
        print(OK + n)
    for f in fails:
        print(BAD + f)
    if fails:
        print("  !!   ROLE_MAP 不符合本板口径（wan=%s / lan=%s）" % (a.gig, "+".join(lan_ports)))
        return 1
    print("  OK   ROLE_MAP 符合本板口径（三口各一次 + 1G 当 WAN + 两个 2.5G 同 LAN 桥）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
