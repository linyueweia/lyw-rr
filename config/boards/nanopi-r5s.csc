# Rockchip RK3568 quad core 4GB RAM eMMC NVMe 2x USB3 1x GbE 2x 2.5GbE
#
# ──────────────────────────────────────────────────────────────────────────────
# 本文件 = 上游 jjm2473/armbian-easepi (branch easepi-v26.02) 的
#   config/boards/nanopi-r5s.csc 的【iNextOS 适配版】。
# 上游原文（2026-10-16 抄录，HEAD e5ff78d6）除下面这一处【网口命名与角色】
# 之外逐字保留；改动处全部用 ##iNextOS 标注，便于以后与上游 diff 合并。
#
# 为什么必须改（证据，不是推测）：
#   上游本文件的原文用 udev 把三个口命名成 wan1/lan1/lan2，并写
#       /root/.default-network = DEFAULT_INTERFACE=lan2
#   而 iNextOS 的用户态网络链（上游 extensions/istorenext.sh 装的两件套）是：
#       packages/bsp/istorenext/fix-ifaces-name   —— 读 /etc/eth_order（或 DT
#           eth_order），逗号分隔的设备名按序重命名为 eth0..ethN；
#       packages/bsp/istorenext/istorenext-init-network —— 优先读
#           /root/.default-network 的 DEFAULT_INTERFACE，否则取 eth* 里编号
#           最大的那个，把它写成静态 192.168.100.1（网页后台入口）。
#   两者叠加的后果：口名是 wan1/lan1/lan2（不匹配 init-network 的 `grep ^eth`），
#   命名顺序完全依赖内核探测顺序 —— 三个口的三次装机可能互相错位，网页后台
#   地址落在哪个物理口上不确定。所以按【官方 iNextOS 自己的做法】把身份钉死。
#
# ★ 本节的写法 = 官方 iNextOS 板级配置的原文写法（权威依据，2026-10-16 抄录）：
#   jjm2473/armbian-easepi @ easepi-v26.02 的 config/boards/easepi-r1.csc：
#       function post_family_tweaks__easepi_r1_udev_network_interfaces() {
#           …cat <<- EOF > "${SDCARD}/etc/udev/rules.d/70-persistent-net.rules"
#               SUBSYSTEM=="net", ACTION=="add", KERNELS=="fe010000.ethernet", NAME:="eth0"
#               … NAME:="eth1" / NAME:="eth2" / NAME:="eth3"
#           echo "DEFAULT_INTERFACE=eth3" > "${SDCARD}/root/.default-network"
#           echo "fe010000.ethernet,fe2a0000.ethernet,0001:11:00.0,0000:01:00.0" > "${SDCARD}/etc/eth_order"
#   ⇒ 官方就是「udev 规则 + /root/.default-network（=编号最大的 ethN）+
#     /etc/eth_order（逗号分隔设备名，按 eth0..ethN 顺序）」三件套，且 eth_order
#     是【构建期静态写进镜像】的（官方 R1 镜像里实测：/etc/eth_order 在、
#     gen-eth-order 脚本【不存在】= 0 处命中）—— 本节照抄这套机制，不做自创。
#   官方 R1 镜像旁证（离线解镜像实测）：/root/.default-network 内容为
#     `DEFAULT_INTERFACE=eth3`（R1 是四口，取最大）；roceos 三服务 + nginx 站点在；
#     fix-ifaces-name.service 挂在 sysinit.target.wants、istorenext-init-network.service
#     挂在 multi-user.target.wants；镜像里【没有】任何 EEE 相关件。
#
# 三口身份的证据链（2026-10-16）：
#   1) 主线 DTS arch/arm64/boot/dts/rockchip/rk3568-nanopi-r5s.dts：
#        aliases { ethernet0 = &gmac0; } —— 板载千兆 = gmac0 = platform fe2a0000.ethernet
#        &pcie3x2 / &pcie3x1 / &pcie2x1 全 okay（num-lanes=1）
#        LED 节点名 lan1 / lan2 / wan —— 板上就是 1×GbE + 2×2.5GbE
#   2) 上游本文件原文的 udev 规则（= 维护者 utlark 实机口径）：
#        fe2a0000.ethernet → wan1（千兆口）
#        0000:01:00.0      → lan1（PCIe domain 0 = pcie3x2 上的 2.5G 网卡）
#        0001:11:00.0      → lan2（PCIe domain 1 = pcie3x1 上的 2.5G 网卡）
#      ⇒ M.2 NVMe 落在 domain 2（pcie2x1 = pcie@fe260000），与两个网卡互不冲突
#   3) iNextOS 的排序规则（H88K 镜像内 gen-eth-order 脚本注释原文）：
#        SoC platform MACs first, then PCIe/USB NICs sorted by device path
#      ⇒ eth0 = 平台千兆口，eth1/eth2 = 两个 PCIe 2.5G 口（域号小的在前）
#   结论（与上游角色口径一致）：eth0=千兆(WAN) / eth1=2.5G(LAN1) / eth2=2.5G(LAN2)，
#   网页后台 192.168.100.1 落在 eth2 —— 与上游 DEFAULT_INTERFACE=lan2 同口，
#   也与官方 R1「默认口 = 编号最大的 ethN」的约定一致。
# ──────────────────────────────────────────────────────────────────────────────
BOARD_NAME="NanoPi R5S"
BOARD_VENDOR="friendlyelec"
BOARDFAMILY="rockchip64"
BOARD_MAINTAINER="linyueweia"   ##iNextOS: 上游为 utlark（上游文件 fork，改动见文件头）
BOOT_SOC="rk3568"
KERNEL_TARGET="current,edge"
KERNEL_TEST_TARGET="current"
BOOT_FDT_FILE="rockchip/rk3568-nanopi-r5s.dtb"
SRC_EXTLINUX="no"
ASOUND_STATE="asound.state.station-m2" # TODO verify me
IMAGE_PARTITION_TABLE="gpt"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"

# ── 网络栈：不装 NetworkManager（对齐官方 iNextOS 设备 / 与 lyw-OS 同一条）──
# 权威依据：官方 EasePi R1 镜像实测（lyw-OS 的 csc 里已记录）—— dpkg 里根本没有
# network-manager。官方 iNextOS 的网络由 ifupdown-ng(networking.service) +
# roceos(建 br-lan1 / 挂口 / 写 dnsmasq) + dnsmasq 管。
#
# 框架默认 BUILD_MINIMAL=no → NETWORKING_STACK=network-manager，会装并启用 NM。
# 本板实机取证（2026-10-17 R5S 首台）：
#   NM 启动时把 br-lan1 的 eth0/eth1 当独立设备接管，给 eth1 生成
#   'Wired connection 2' 跑 DHCP，45s 超时（桥端口不可能拿到地址）后
#   `released from controller device br-lan1` → 把 eth1 从网桥摘掉 → SSH 失联。
#   log: device (eth1): ip-config -> failed (reason 'ip-config-unavailable')
# 所以这里显式置 none（框架 main-config 的正式取值，走 "Not adding networking
# extensions" 分支）。时间同步不受影响：ntpsec-ntpdate 由 istorenext 扩展带入。
declare -g NETWORKING_STACK="none"

BOOTBRANCH_BOARD="tag:v2024.04"
BOOTPATCHDIR="v2024.04"
BOOTCONFIG="nanopi-r5s-rk3568_defconfig"

OVERLAY_PREFIX="rockchip-rk3568"
# nanopi-r5s-fan：打开 pwm0 + pwm-fan 节点，并往 cpu-thermal 追加 active trips
# （主线 DTB 没有风扇支持）。温控完全由内核 thermal 做，镜像里不含用户态风扇脚本。
DEFAULT_OVERLAYS="nanopi-r5s-leds nanopi-r5s-fan"

function post_family_config__uboot_config() {
	display_alert "$BOARD" "u-boot ${BOOTBRANCH_BOARD} overrides" "info"
	BOOTDELAY=2 # Wait for UART interrupt to enter UMS/RockUSB mode etc
	UBOOT_TARGET_MAP="ROCKCHIP_TPL=${RKBIN_DIR}/${DDR_BLOB} BL31=$RKBIN_DIR/$BL31_BLOB spl/u-boot-spl u-boot.bin flash.bin;;idbloader.img u-boot.itb"
}

##iNextOS ── 网口身份钉定（替换上游的 wan1/lan1/lan2 命名；其余原样）──────────
# 三条硬证据见文件头注释。这里落四样东西 + 逐项自证：
#   ① /etc/udev/rules.d/70-persistent-net.rules —— 按设备路径钉死 eth0/eth1/eth2；
#   ② /etc/eth_order        —— iNextOS fix-ifaces-name 读它把口重排成 eth0..ethN
#                               （逗号分隔；平台名走 /sys/devices/platform/，
#                                PCI 名走 /sys/bus/pci/devices/ —— 两种都吃）；
#   ③ /root/.default-network —— iNextOS istorenext-init-network 读它，
#                               把 eth2 配成 192.168.100.1（网页后台入口）。
# 注意：镜像里【不装 NetworkManager】（见上面 NETWORKING_STACK="none"），所以不再
#       需要旧版那个「NM 排在 LAN 之后启动」的 drop-in —— 没有 NM 就没有抢口的实体。
#       首台实机（2026-10-17）已证：光靠排序挡不住「向导完成后 roceos 接管」的阶段。
# 自证：任何一件没落进镜像就 exit 1 —— 静默丢失=装机后口名/地址错位，代价是上板一轮。
function post_family_tweaks__nanopir5s_udev_network_interfaces() {
	display_alert "$BOARD" "Pinning NanoPi R5S network interfaces (iNextOS: eth0=GbE/eth1=2.5G/eth2=2.5G)" "info"

	mkdir -p "${SDCARD}/etc/udev/rules.d/"
	cat <<- EOF > "${SDCARD}/etc/udev/rules.d/70-persistent-net.rules"
		# NanoPi R5S / iNextOS：按 PCI/platform 设备路径钉死口名（顺序= iNextOS 排序规则）
		SUBSYSTEM=="net", ACTION=="add", KERNELS=="fe2a0000.ethernet", NAME:="eth0"
		SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:01:00.0", NAME:="eth1"
		SUBSYSTEM=="net", ACTION=="add", KERNELS=="0001:11:00.0", NAME:="eth2"
	EOF

	echo "fe2a0000.ethernet,0000:01:00.0,0001:11:00.0" > "${SDCARD}/etc/eth_order"
	echo "DEFAULT_INTERFACE=eth2" > "${SDCARD}/root/.default-network"

	# ── 逐项自证（缺一即失败）──────────────────────────────────────────────
	for f in etc/udev/rules.d/70-persistent-net.rules etc/eth_order root/.default-network; do
		[[ -e "${SDCARD}/${f}" ]] || exit_with_error "R5S network init file missing: ${f}"
	done
	grep -q 'KERNELS=="fe2a0000.ethernet", NAME:="eth0"' \
		"${SDCARD}/etc/udev/rules.d/70-persistent-net.rules" \
		|| exit_with_error "R5S: udev rule for eth0/fe2a0000.ethernet missing"
	grep -q 'KERNELS=="0000:01:00.0", NAME:="eth1"' \
		"${SDCARD}/etc/udev/rules.d/70-persistent-net.rules" \
		|| exit_with_error "R5S: udev rule for eth1/0000:01:00.0 missing"
	grep -q 'KERNELS=="0001:11:00.0", NAME:="eth2"' \
		"${SDCARD}/etc/udev/rules.d/70-persistent-net.rules" \
		|| exit_with_error "R5S: udev rule for eth2/0001:11:00.0 missing"
	grep -q '^fe2a0000\.ethernet,0000:01:00\.0,0001:11:00\.0$' "${SDCARD}/etc/eth_order" \
		|| exit_with_error "R5S: /etc/eth_order content wrong"
	grep -q '^DEFAULT_INTERFACE=eth2$' "${SDCARD}/root/.default-network" \
		|| exit_with_error "R5S: /root/.default-network wrong"
	# 反断言：本板不装 NetworkManager，镜像里不该再有 NM 相关 drop-in 残留
	if [ -e "${SDCARD}/etc/systemd/system/NetworkManager.service.d/10-r5s-lan-order.conf" ]; then
		exit_with_error "R5S: 仍残留 NM 排序 drop-in（本板已不装 NetworkManager）"
	fi
	# 反断言：上游的 wan1/lan1/lan2 命名必须已被本仓替换（否则又回到不确定命名）
	if grep -qE 'NAME:="(wan1|lan1|lan2)"' "${SDCARD}/etc/udev/rules.d/70-persistent-net.rules"; then
		exit_with_error "R5S: 上游 wan1/lan1/lan2 命名残留（iNextOS 会拿不到 eth* 口名）"
	fi
	display_alert "$BOARD" "R5S network pinned: eth0=fe2a0000(GbE), eth1=0000:01:00.0(2.5G), eth2=0001:11:00.0(2.5G, 192.168.100.1)" "info"
	return 0
}

# We've an overlay (DEFAULT_OVERLAYS="nanopi-r5s-leds") to drive the LEDs. Disable armbian-led-state service.
function pre_customize_image__nanopi-r5s_leds_kernel_only() {
	display_alert "$BOARD" "Disabling armbian-led-state service since we have DEFAULT_OVERLAYS='${DEFAULT_OVERLAYS}'" "info"
	chroot_sdcard systemctl --no-reload disable armbian-led-state
}

# For UMS/RockUSB to work in u-boot, &usb_host0_xhci { dr_mode = "otg" } is required. See 0002-usb-otg-mode.patch
# Attention: the Power USB-C port is NOT the OTG port; instead, the USB-A closest to the edge is the OTG port.
function post_config_uboot_target__extra_configs_for_nanopi-r5s() {
	display_alert "u-boot for ${BOARD}" "u-boot: enable preboot & flash all LEDs and do PCI/NVMe enumeration in preboot" "info"
	run_host_command_logged scripts/config --enable CONFIG_USE_PREBOOT
	run_host_command_logged scripts/config --set-str CONFIG_PREBOOT "'led led-power on; led led-lan1 on; led led-lan2 on; led led-wan on; pci enum; nvme scan; led led-lan1 off; led led-lan2 off; led led-wan off'" # double quotes required due to run_host_command_logged's quirks

	display_alert "u-boot for ${BOARD}" "u-boot: enable EFI debugging command" "info"
	run_host_command_logged scripts/config --enable CMD_EFIDEBUG
	run_host_command_logged scripts/config --enable CMD_NVEDIT_EFI

	display_alert "u-boot for ${BOARD}" "u-boot: enable more compression support" "info"
	run_host_command_logged scripts/config --enable CONFIG_LZO
	run_host_command_logged scripts/config --enable CONFIG_BZIP2
	run_host_command_logged scripts/config --enable CONFIG_ZSTD

	display_alert "u-boot for ${BOARD}" "u-boot: enable gpio LED support" "info"
	run_host_command_logged scripts/config --enable CONFIG_LED
	run_host_command_logged scripts/config --enable CONFIG_LED_GPIO

	display_alert "u-boot for ${BOARD}" "u-boot: enable networking cmds" "info"
	run_host_command_logged scripts/config --enable CONFIG_CMD_NFS
	run_host_command_logged scripts/config --enable CONFIG_CMD_WGET
	run_host_command_logged scripts/config --enable CONFIG_CMD_DNS
	run_host_command_logged scripts/config --enable CONFIG_PROT_TCP
	run_host_command_logged scripts/config --enable CONFIG_PROT_TCP_SACK

	# UMS, RockUSB, gadget stuff
	declare -a enable_configs=("CONFIG_CMD_USB_MASS_STORAGE" "CONFIG_USB_GADGET" "USB_GADGET_DOWNLOAD" "CONFIG_USB_FUNCTION_ROCKUSB" "CONFIG_USB_FUNCTION_ACM" "CONFIG_CMD_ROCKUSB" "CONFIG_CMD_USB_MASS_STORAGE")
	for config in "${enable_configs[@]}"; do
		display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable ${config}" "info"
		run_host_command_logged scripts/config --enable "${config}"
	done
	# Auto-enabled by the above, force off...
	run_host_command_logged scripts/config --disable USB_FUNCTION_FASTBOOT

}
