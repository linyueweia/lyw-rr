#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# NanoPi R5S / iNextOS 镜像自证（构建产物级判据，不依赖上板）
#
# 用法：sudo -E bash tools/verify-image.sh <img> [adapted|official]
#   adapted  —— 本仓适配层（默认）：跑全部判据
#   official —— 纯官方基线（上游 csc + istorenext）：只跑"底座"判据，
#               跳过本仓适配层（roceos/EEE/角色/口名钉定）
#   --probe  —— 只探测分区布局并打印 LAYOUT 行（几秒），供 CI 前置自测使用
#
# 设计原则（照 board-image-forensics 技能）：
#   · 每个断言都指向一个【可复现的失败后果】，不是"文件存在就算过"；
#   · 正断言 + 反断言成对：既要求该在的在，也要求不该在的不在
#     （例如上游 wan1/lan1/lan2 命名必须已被替换、ttyFIQ0 getty 不得被启用）；
#   · 任何一条不过 → 非零退出，CI 直接判失败，绝不静默放过。
#
# ★ 分区布局自适应（2026-10-16 事故修正，必须保留）：
#   iNextOS 镜像有两种官方布局，取决于板级 csc 是否声明 BOOTFS_TYPE：
#     单分区（本板 nanopi-r5s 上游路径，同官方 H88K 镜像）：
#        16MiB 前导 + p1 = rootfs(ext4)，引导文件在 rootfs 的 /boot 里
#     双分区（官方 easepi-r1.csc 声明 BOOTFS_TYPE="fat"，同官方 R1 镜像）：
#        p1 = bootfs(vfat) + p2 = rootfs(ext4)
#   旧版本把 p1/p2 写死，遇到本板的单分区布局 → p1(其实是 rootfs) 被当 bootfs、
#   p2 不存在导致 rootfs 挂载点为空 → 全部断言误报失败，白跑一整轮构建。
#   因此这里【按分区名/文件系统类型探测】，并在探测结果不合理时立即响亮失败。
# ══════════════════════════════════════════════════════════════════════════
set -u

PROBE=0
if [ "${1:-}" = "--probe" ]; then
	PROBE=1
	IMG="${2:?用法: verify-image.sh --probe <img>}"
	PROFILE="probe"
else
	IMG="${1:?用法: verify-image.sh <img> [adapted|official]}"
	PROFILE="${2:-adapted}"
fi
FAIL=0

ok()   { echo "  OK   $*"; }
bad()  { echo "  !!   $*"; FAIL=1; }
info() { echo "       $*"; }

# 在目标 rootfs 里找某 unit 的 enable 链接（任意 *.wants/）：
#   WantedBy 由 unit 自己决定 —— fix-ifaces-name → sysinit.target、
#   istorenext-init-network → networking.service、本仓自制服务 → multi-user/timers.target
#   写死某个目录会在上游改 [Install] 时变成误报，所以只断言"确实被 enable"并打印实际路径。
wants_link() {  # $1 = unit 名；找到则输出链接路径
	find /mnt/ir/etc/systemd/system -maxdepth 2 -name "$1" -path '*.wants/*' 2>/dev/null | head -1
}

echo "=== 镜像: $IMG (profile=$PROFILE)"
ls -l "$IMG" || exit 1
echo "--- sha256:"; sha256sum "$IMG" || true
if [ -f "${IMG}.sha" ]; then
	EXP=$(awk '{print $1}' "${IMG}.sha" 2>/dev/null | head -c 64)
	ACT=$(sha256sum "$IMG" | awk '{print $1}')
	[ -n "$EXP" ] && { [ "$EXP" = "$ACT" ] && ok "构建产物 .sha 与实算 sha256 一致（$ACT）" \
		|| bad "构建产物 .sha 与实算 sha256 不一致（.sha=$EXP 实算=$ACT）"; }
fi

if ! command -v dtc >/dev/null 2>&1; then
	sudo apt-get update -qq >/dev/null 2>&1 || true
	sudo apt-get install -y -qq device-tree-compiler >/dev/null 2>&1 || true
fi

# ───────────────────────── 分区探测（布局自适应）─────────────────────────
LOOP=$(sudo losetup --show -f -P "$IMG") || { echo "losetup 失败"; exit 1; }
echo "--- loop: $LOOP"
sudo partprobe "$LOOP" >/dev/null 2>&1 || true
sleep 1
echo "--- 分区表:"
sudo parted -s "$LOOP" unit MiB print 2>&1 | sed 's/^/       /' || true

sudo mkdir -p /mnt/ib /mnt/ir
ROOTDEV=""
BOOTDEV=""
for p in ${LOOP}p*; do
	[ -b "$p" ] || continue
	ptype=$(sudo blkid -s TYPE -o value "$p" 2>/dev/null || true)
	plabel=$(sudo blkid -s PARTLABEL -o value "$p" 2>/dev/null || true)
	echo "       $(basename "$p")  type=${ptype:-?}  partlabel=${plabel:-?}"
	case " $plabel $ptype " in
		*' bootfs '*|*' vfat '*|*' msdos '*) [ -n "$BOOTDEV" ] || BOOTDEV="$p" ;;
	esac
	case " $plabel $ptype " in
		*' rootfs '*|*' ext4 '*|*' ext3 '*|*' btrfs '*|*' xfs '*) [ -n "$ROOTDEV" ] || ROOTDEV="$p" ;;
	esac
done

if [ -z "$ROOTDEV" ]; then
	echo "!! 探测不到 rootfs 分区（见上面的分区表）—— 中止，不做后续断言"
	sudo losetup -d "$LOOP" 2>/dev/null || true
	exit 1
fi
sudo mount "$ROOTDEV" /mnt/ir || { echo "!! 挂载 rootfs（$(basename "$ROOTDEV")）失败"; sudo losetup -d "$LOOP"; exit 1; }

# rootfs 合理性：探测错了就立刻响亮失败，别让它变成一屏假断言（2026-10-16 事故教训）
if [ ! -d /mnt/ir/etc ] || [ ! -d /mnt/ir/usr ]; then
	if [ "$PROBE" = "1" ]; then
		echo "       (probe: $(basename "$ROOTDEV") 里没有 /etc /usr —— mock 镜像属正常)"
	else
		echo "!! 探测到的 rootfs（$(basename "$ROOTDEV")）里没有 /etc /usr —— 分区判定失效，"
		echo "!! 先修自证脚本的分区探测，不要解读后面的断言（历史事故：分区假设错 → 全屏误报）"
		sudo umount /mnt/ir 2>/dev/null || true
		sudo losetup -d "$LOOP" 2>/dev/null || true
		exit 1
	fi
fi

# bootdir：独立 bootfs 分区优先（双分区布局），否则用 rootfs 里的 /boot（单分区布局）
BOOTDIR=/mnt/ir/boot
[ -f /mnt/ir/boot/firmware/armbianEnv.txt ] && BOOTDIR=/mnt/ir/boot/firmware
if [ -n "$BOOTDEV" ]; then
	if sudo mount "$BOOTDEV" /mnt/ib; then
		if [ -f /mnt/ib/armbianEnv.txt ]; then
			BOOTDIR=/mnt/ib
		else
			echo "       (bootfs $(basename "$BOOTDEV") 里没有 armbianEnv.txt，bootdir 仍用 rootfs 的 /boot)"
		fi
	else
		echo "       (bootfs $(basename "$BOOTDEV") 挂载失败，bootdir 回落到 rootfs 的 /boot)"
	fi
fi
echo "--- layout: rootfs=$(basename "$ROOTDEV")${BOOTDEV:+  bootfs=$(basename "$BOOTDEV")}  bootdir=$BOOTDIR"
echo "LAYOUT rootfs=${ROOTDEV:-none} bootfs=${BOOTDEV:-none} bootdir=$BOOTDIR"

if [ "$PROBE" = "1" ]; then
	mountpoint -q /mnt/ib && sudo umount /mnt/ib 2>/dev/null || true
	mountpoint -q /mnt/ir && sudo umount /mnt/ir 2>/dev/null || true
	sudo losetup -d "$LOOP" 2>/dev/null || true
	exit 0
fi

echo "--- bootdir 内容:"; ls "$BOOTDIR" 2>/dev/null | head -25 | sed 's/^/       /'

# ───────────────────────── 底座判据（两档都跑）─────────────────────────
echo
echo "=== [底座] boot 引导链"
if [ -f "$BOOTDIR/armbianEnv.txt" ]; then
	cat "$BOOTDIR/armbianEnv.txt" | sed 's/^/       /'
	grep -q 'rk3568-nanopi-r5s.dtb' "$BOOTDIR/armbianEnv.txt" \
		&& ok "armbianEnv.txt 指向 rk3568-nanopi-r5s.dtb" \
		|| bad "armbianEnv.txt 未指向 rk3568-nanopi-r5s.dtb（会引导到别的板子的 DTB）"
else
	bad "boot 目录（$BOOTDIR）缺 armbianEnv.txt（u-boot 读不到根分区参数）"
fi
# 引导链完整性：脚本 + 内核/initrd 必须都在 boot 目录（否则镜像根本起不来）
BOOTSCR=""
for f in "$BOOTDIR/boot.scr" "$BOOTDIR/boot.cmd" "$BOOTDIR/extlinux/extlinux.conf"; do
	[ -e "$f" ] && BOOTSCR="$f" && break
done
[ -n "$BOOTSCR" ] && ok "引导脚本在位: $BOOTSCR" \
	|| bad "boot 目录缺引导脚本（boot.scr / boot.cmd / extlinux.conf 都没有 → u-boot 无脚本可执行）"
KERNF=""
for f in "$BOOTDIR"/Image "$BOOTDIR"/vmlinuz-* "$BOOTDIR"/uInitrd "$BOOTDIR"/uInitrd-*; do
	[ -e "$f" ] && KERNF="$f" && break
done
[ -n "$KERNF" ] && ok "内核/initrd 在位: $(basename "$KERNF")（$(stat -c%s "$KERNF") B）" \
	|| bad "boot 目录缺内核镜像（Image / vmlinuz-* / uInitrd* 都没有）"
DTB=""
for c in "$BOOTDIR/dtb/rockchip/rk3568-nanopi-r5s.dtb" \
	/mnt/ir/boot/dtb/rockchip/rk3568-nanopi-r5s.dtb \
	/mnt/ir/boot/firmware/dtb/rockchip/rk3568-nanopi-r5s.dtb; do
	[ -f "$c" ] && DTB="$c" && break
done
if [ -n "$DTB" ]; then
	ok "DTB 在位: $DTB ($(stat -c%s "$DTB") B)"
	dtc -I dtb -O dts "$DTB" -o /tmp/r5s.dts 2>/dev/null || sudo dtc -I dtb -O dts "$DTB" -o /tmp/r5s.dts
	grep -q 'model = "FriendlyElec NanoPi R5S"' /tmp/r5s.dts \
		&& ok "DTB model = FriendlyElec NanoPi R5S" \
		|| bad "DTB model 不是 NanoPi R5S（拷错了板子的 DTB）"
	grep -q 'friendlyarm,nanopi-r5s' /tmp/r5s.dts \
		&& ok "DTB compatible 含 friendlyarm,nanopi-r5s" \
		|| bad "DTB compatible 缺 friendlyarm,nanopi-r5s"
	# 三口命门：千兆 gmac0 + 三个 PCIe 控制器（两个 2.5G 网卡 + M.2 NVMe）必须都 okay
	# 地址来源（v6.18 内核源码，2026-10-16 核实）：
	#   rk3568.dtsi      gmac0 = ethernet@fe2a0000 ; pcie3x1 = pcie@fe270000 ; pcie3x2 = pcie@fe280000
	#   rk356x-base.dtsi pcie2x1 = pcie@fe260000（M.2 NVMe 所在；R5S 的 M.2 是 PCIe 2.0 x1）
	# 域号↔控制器（与上游 udev 规则 0000:01:00.0 / 0001:11:00.0 吻合）：
	#   domain 0 = pcie3x2（2.5G #1） / domain 1 = pcie3x1（2.5G #2） / domain 2 = pcie2x1（NVMe）
	node_status() {  # $1=dts 文件 $2=节点名（如 pcie@fe280000）
		python3 - "$1" "$2" <<-'PY'
			import re, sys
			dts, want = sys.argv[1], sys.argv[2]
			txt = open(dts, encoding='utf-8', errors='replace').read()
			m = re.search(r'^\s*(?:[0-9A-Za-z_\-]+:\s*)?' + re.escape(want) + r'\s*\{', txt, re.M)
			if not m:
			    print('MISSING'); sys.exit(0)
			status = None
			for line in txt[m.end():].splitlines():
			    s = line.strip()
			    if s.endswith('{'):          # dtc 输出里属性在前、子节点在后：遇到子节点即结束
			        break
			    if s.startswith('};'):
			        break
			    if s.startswith('status'):
			        status = s
			        break
			print(status or 'NO-STATUS')
		PY
	}
	for node in 'ethernet@fe2a0000' 'pcie@fe260000' 'pcie@fe270000' 'pcie@fe280000'; do
		st=$(node_status /tmp/r5s.dts "$node")
		case "$st" in
			*okay*) ok "DTB $node = okay" ;;
			MISSING) bad "DTB 里找不到节点 $node（DTB 拷错或内核 DTS 变了）" ;;
			*)      bad "DTB $node 不是 okay（$st）—— 该控制器/网口不会起来" ;;
		esac
	done
	grep -q 'gpio-leds' /tmp/r5s.dts && ok "DTB 有 gpio-leds（板上四个 LED）" || bad "DTB 缺 gpio-leds"
else
	bad "镜像里找不到 rk3568-nanopi-r5s.dtb（搜索：$BOOTDIR/dtb 与 /rootfs/boot/dtb）"
fi

echo
echo "=== [底座] 内核配置（三口 + NVMe 的命门）"
CFG=$(ls "$BOOTDIR"/config-* /mnt/ir/boot/config-* /mnt/ir/boot/firmware/config-* 2>/dev/null | head -1 || true)
if [ -n "$CFG" ]; then
	info "config: $CFG"
	for sym in STMMAC_ETH R8169; do
		grep -qE "^CONFIG_${sym}=m" "$CFG" && ok "CONFIG_${sym}=m" \
			|| bad "CONFIG_${sym} 不是 =m（网口驱动无法随内核更新自愈）"
	done
	for sym in BLK_DEV_NVME LEDS_GPIO PCIE_DW_PLAT_HOST; do
		grep -qE "^CONFIG_${sym}=y" "$CFG" && ok "CONFIG_${sym}=y" \
			|| bad "CONFIG_${sym} 不是 =y"
	done
	grep -qE '^CONFIG_PCI_MSI=y' "$CFG" && ok "CONFIG_PCI_MSI=y（PCIe/NVMe 不退化 INTx）" \
		|| bad "CONFIG_PCI_MSI 未启用"
	grep -E '^CONFIG_(STMMAC_ETH|R8169|REALTEK_PHY|ROCKCHIP_PHY|BLK_DEV_NVME)=' "$CFG" | sed 's/^/       /'
else
	bad "镜像里找不到内核 config 文件（搜过 $BOOTDIR/config-* 与 /rootfs/boot/config-*）"
fi

echo
echo "=== [底座] 驱动本体是否真的落进 rootfs"
# 模块名以源码文件名为准：drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c → dwmac-rk.ko
# （不要写成 "dwmac-rockchip.ko"；依据 = 本板真实构建日志 LD [M] .../dwmac-rk.o）
for m in r8169  dwmac-rk stmmac; do
	KO=$(find /mnt/ir/lib/modules -name "${m}.ko*" 2>/dev/null | head -1)
	[ -n "$KO" ] && ok "${m}.ko -> ${KO#/mnt/ir}" || bad "rootfs 缺 ${m}.ko（对应的网口不会起来）"
done
DEP=$(find /mnt/ir/lib/modules -name modules.dep 2>/dev/null | head -1)
[ -n "$DEP" ] && { grep -q 'r8169.ko' "$DEP" && ok "modules.dep 收录 r8169（udev 能自动加载 2.5G 驱动）" \
	|| bad "modules.dep 未收录 r8169"; } || bad "找不到 modules.dep"

echo
echo "=== [底座] iNextOS 首启网络链（上游 istorenext 扩展装的两件套）"
for f in usr/lib/istorenext/fix-ifaces-name usr/lib/istorenext/istorenext-init-network; do
	[ -e "/mnt/ir/$f" ] && ok "在: $f" || bad "缺: $f（iNextOS 首启网络链不完整）"
done
L=$(wants_link fix-ifaces-name.service); [ -n "$L" ] \
	&& ok "fix-ifaces-name.service 已 enable（${L#/mnt/ir}）" \
	|| bad "fix-ifaces-name.service 未 enable（口名不会按 eth_order 重排）"
L=$(wants_link istorenext-init-network.service); [ -n "$L" ] \
	&& ok "istorenext-init-network.service 已 enable（${L#/mnt/ir}）" \
	|| bad "istorenext-init-network.service 未 enable（首启 192.168.100.1 不会生成）"
grep -q 'iNextOS' /mnt/ir/etc/hostname 2>/dev/null || info "/etc/hostname: $(cat /mnt/ir/etc/hostname 2>/dev/null)"

# ───────────────────────── 适配层判据（仅 adapted）─────────────────────────
if [ "$PROFILE" = "adapted" ]; then
	echo
	echo "=== [适配层] 网口身份钉定（三条 udev 规则 + eth_order + 默认口）"
	RULES=/mnt/ir/etc/udev/rules.d/70-persistent-net.rules
	if [ -f "$RULES" ]; then
		for l in 'fe2a0000.ethernet", NAME:="eth0' '0000:01:00.0", NAME:="eth1' '0001:11:00.0", NAME:="eth2'; do
			grep -q "$l" "$RULES" && ok "udev 规则: $l" || bad "udev 规则缺: $l"
		done
		grep -qE 'NAME:="(wan1|lan1|lan2)"' "$RULES" \
			&& bad "上游 wan1/lan1/lan2 命名残留（iNextOS 拿不到 eth* 口名）" \
			|| ok "反断言：无 wan1/lan1/lan2 残留命名"
	else
		bad "缺 $RULES"
	fi
	if [ -f /mnt/ir/etc/eth_order ]; then
		cont=$(head -1 /mnt/ir/etc/eth_order | tr -d '\r\n')
		[ "$cont" = "fe2a0000.ethernet,0000:01:00.0,0001:11:00.0" ] \
			&& ok "/etc/eth_order = $cont" \
			|| bad "/etc/eth_order 内容不对：'$cont'（fix-ifaces-name 会按它重排口名）"
	else
		bad "缺 /etc/eth_order"
	fi
	if [ -f /mnt/ir/root/.default-network ]; then
		grep -q '^DEFAULT_INTERFACE=eth2$' /mnt/ir/root/.default-network \
			&& ok "默认口 = eth2（istorenext-init-network 会把它配成 192.168.100.1）" \
			|| bad "/root/.default-network 内容不对：$(cat /mnt/ir/root/.default-network)"
	else
		bad "缺 /root/.default-network（首启 192.168.100.1 会落到编号最大的 eth 上，不确定）"
	fi
	NM=/mnt/ir/etc/systemd/system/NetworkManager.service.d/10-r5s-lan-order.conf
	if [ -f "$NM" ]; then
		grep -q 'After=istorenext-init-network.service networking.service' "$NM" \
			&& ok "NM 排序 drop-in 在位（避免首启与 ifupdown 抢口）" \
			|| bad "NM 排序 drop-in 内容不对"
	else
		bad "缺 NM 排序 drop-in（首启 NM 可能先接管网口）"
	fi

	echo
	echo "=== [适配层] roceos 网页后台"
	for f in opt/roceos/roceos opt/roceos/www/index.html opt/roceos-ai/server.py \
		etc/nginx/sites-available/roceos.conf etc/nginx/ssl/roceos.key; do
		[ -e "/mnt/ir/$f" ] && ok "在: $f" || bad "缺: $f（网页后台不完整）"
	done
	for s in roceos.service roceos-ai.service roceos-vision.service; do
		SL=$(wants_link "$s"); [ -n "$SL" ] \
			&& ok "已 enable: $s（${SL#/mnt/ir}）" || bad "未 enable: $s（后台不会自启）"
	done
	{ [ -L /mnt/ir/etc/nginx/sites-enabled/roceos.conf ] \
		|| [ -e /mnt/ir/etc/nginx/sites-enabled/roceos.conf ]; } \
		&& ok "nginx roceos 站点已启用" || bad "nginx roceos 站点未启用"
	[ -e /mnt/ir/etc/nginx/sites-enabled/default ] \
		&& bad "nginx default 站点还在（会抢 default_server）" \
		|| ok "反断言：nginx default 站点已移除"
	[ -f /mnt/ir/etc/apt/preferences.d/10-inextos-firmware-conflict ] \
		&& ok "apt pin 在位（更新流程无法卸载 armbian-firmware）" \
		|| bad "缺 apt pin 文件"

	echo
	echo "=== [适配层] EEE 关闭（五层持久化）"
	[ -x /mnt/ir/usr/local/sbin/lyw-rr-eee-off.sh ] && ok "EEE 脚本在位且可执行" || bad "缺 lyw-rr-eee-off.sh"
	sh -n /mnt/ir/usr/local/sbin/lyw-rr-eee-off.sh 2>/dev/null && ok "EEE 脚本语法通过" || bad "EEE 脚本语法错误"
	grep -q -- '--set-eee' /mnt/ir/usr/local/sbin/lyw-rr-eee-off.sh 2>/dev/null \
		&& ok "EEE 脚本含 --set-eee（真的在关 EEE）" || bad "EEE 脚本不含 --set-eee"
	for f in usr/local/sbin/lyw-rr-eee-off.sh etc/systemd/system/lyw-rr-eee-off.service \
		etc/NetworkManager/dispatcher.d/90-lyw-rr-eee-off etc/network/if-up.d/zz-lyw-rr-eee-off \
		etc/systemd/system/lyw-rr-eee-off-watch.timer; do
		[ -e "/mnt/ir/$f" ] && ok "在: $f" || bad "缺: $f"
	done
	SL=$(wants_link lyw-rr-eee-off.service); [ -n "$SL" ] \
		&& ok "EEE 服务已 enable（${SL#/mnt/ir}）" || bad "EEE 服务未 enable"
	SL=$(wants_link lyw-rr-eee-off-watch.timer); [ -n "$SL" ] \
		&& ok "EEE 兜底 timer 已 enable（${SL#/mnt/ir}）" || bad "EEE 兜底 timer 未 enable"
	[ -x /mnt/ir/usr/sbin/ethtool ] || [ -x /mnt/ir/usr/bin/ethtool ] \
		&& ok "ethtool 在镜像里" || bad "镜像缺 ethtool（整套 EEE 修复形同不存在）"

	echo
	echo "=== [适配层] 网口角色归一"
	[ -x /mnt/ir/usr/local/sbin/lyw-rr-net-roles.py ] && ok "角色脚本在位" || bad "缺 lyw-rr-net-roles.py"
	python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" \
		/mnt/ir/usr/local/sbin/lyw-rr-net-roles.py 2>/dev/null && ok "角色脚本语法通过" || bad "角色脚本语法错误"
	grep -q 'ROLE_MAP' /mnt/ir/etc/lyw-rr-net-roles.conf 2>/dev/null && ok "角色映射文件在位" || bad "缺角色映射文件"
	grep -q 'lan2=eth2' /mnt/ir/etc/lyw-rr-net-roles.conf 2>/dev/null && ok "映射含三口（lan2=eth2）" || bad "角色映射不全"
	SL=$(wants_link lyw-rr-net-roles.service); [ -n "$SL" ] \
		&& ok "角色服务已 enable（${SL#/mnt/ir}）" || bad "角色服务未 enable"
	grep -q '^Before=roceos.service' /mnt/ir/etc/systemd/system/lyw-rr-net-roles.service 2>/dev/null \
		&& ok "角色服务排在 roceos 之前" || bad "角色服务排序不对（改了库也要重启才生效）"

	echo
	echo "=== [适配层] 反断言：不该有的东西"
	FIQ=$(wants_link serial-getty@ttyFIQ0.service); [ -z "$FIQ" ] \
		&& ok "反断言：未启用 ttyFIQ0 getty" \
		|| bad "启用了 serial-getty@ttyFIQ0（${FIQ#/mnt/ir}）—— 本板 current 分支用 ttyS2，会拖慢启动"
	SG=$(wants_link serial-getty@ttyS2.service); [ -n "$SG" ] \
		&& ok "serial-getty@ttyS2 已启用（${SG#/mnt/ir}，串口控制台可用）" \
		|| bad "serial-getty@ttyS2 未启用（串口登录可能没有）"
fi

echo
echo "=== 收尾"
mountpoint -q /mnt/ib && sudo umount /mnt/ib 2>/dev/null || true
mountpoint -q /mnt/ir && sudo umount /mnt/ir 2>/dev/null || true
sudo losetup -d "$LOOP" 2>/dev/null || true

if [ "$FAIL" = "0" ]; then
	echo "== 全部自证通过（profile=$PROFILE）=="
else
	echo "!! 镜像自证失败（profile=$PROFILE）"
fi
exit $FAIL
