#!/usr/bin/env bash
#
# NanoPi R5S (RK3568) —— 内核配置断言（三个网口 + NVMe + LED 的命门）
#
# 为什么这几个符号要显式钉（依据 = 上游官方 config 原文 + 主线 Kconfig，不是猜）：
#   上游基线 config/sources/families/include/rockchip64_common.inc 把 BRANCH=current
#   映射到 KERNEL_MAJOR_MINOR=6.18 / LINUXCONFIG=linux-rockchip64-current；
#   官方 config/kernel/linux-rockchip64-current.config（2026-10-16 抄录，3457 行）里实测：
#       CONFIG_STMMAC_ETH=m        ← 平台千兆 MAC（R5S 的 eth0 靠它 + dwmac-rockchip）
#       CONFIG_R8169=m             ← 两个 2.5G 口（RTL8125B）走主线的 r8169，无需外挂驱动
#       CONFIG_BLK_DEV_NVME=y      ← M.2 NVMe（pcie2x1, domain 2）
#       CONFIG_SATA_AHCI_PLATFORM=y / CONFIG_AHCI_DWC=y
#       CONFIG_PCIE_DW_PLAT_HOST=y ← PCIe 宿主控制器
#       CONFIG_LEDS_GPIO=y         ← 板上 LAN1/LAN2/WAN/SYS 四个 LED
#   这些是【上游默认值】，本扩展不改值、只断言它们仍然是这个值：上游一旦
#   select/default 变化把它们改掉，构建立刻失败，而不是上板才发现两个 2.5G 口没了。
#   模块化（=m）对网络驱动是刻意的：内建驱动在"在线更新换了内核"时无法补救，
#   =m 才有 DKMS/postinst 自愈这条路（lyw-kf 已实机跑通这套判据）。
#
# 用法：build.yml 的 ENABLE_EXTENSIONS 里启用 lyw-rr-kernel-config
#
function custom_kernel_config__lyw_rr_board_symbols() {
	kernel_config_modifying_hashes+=("lyw-rr-kernel-config")

	opts_m+=("STMMAC_ETH" "R8169")
	opts_y+=("PCI_MSI" "BLK_DEV_NVME" "PCIE_DW_PLAT_HOST" "LEDS_GPIO" "SATA_AHCI_PLATFORM" "AHCI_DWC")

	if [[ -f .config ]]; then
		# Kconfig 入口自检：符号名写错会把自己判死，故逐个点名（缺一即构建立刻失败）
		grep -qE '^config STMMAC_ETH$' drivers/net/ethernet/stmicro/stmmac/Kconfig \
			|| exit_with_error "STMMAC_ETH Kconfig entry missing (平台千兆 MAC 无驱动)"
		grep -qE '^config R8169$' drivers/net/ethernet/realtek/Kconfig \
			|| exit_with_error "R8169 Kconfig entry missing (两个 2.5G 口无驱动)"
		grep -qE '^config PCI_MSI$' drivers/pci/Kconfig \
			|| exit_with_error "PCI_MSI Kconfig entry missing"
		grep -qE '^config BLK_DEV_NVME$' drivers/nvme/host/Kconfig \
			|| exit_with_error "BLK_DEV_NVME Kconfig entry missing (M.2 NVMe 不可用)"
		grep -qE '^config LEDS_GPIO$' drivers/leds/Kconfig \
			|| exit_with_error "LEDS_GPIO Kconfig entry missing (板上四个 LED 不亮)"
		display_alert "${EXTENSION}" "R5S board symbols will be pinned: STMMAC_ETH/R8169=m, PCI_MSI/NVME/PCIE_DW_HOST/LEDS_GPIO/SATA=y" "info"
	fi
	return 0
}
