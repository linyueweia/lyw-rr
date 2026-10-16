#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# verify-image.sh 内部辅助函数的自测（秒级，不需要镜像、不需要 root）
#
# 为什么存在：这些函数只在"真镜像自证"里被调用，而真自证要等 100+ 分钟构建
# 之后才跑 —— 函数本身一错就等于白跑一整轮（2026-10-16 就是这么白跑了两轮）。
# 所以把它们抽出来，用样本数据先断言一遍；CI 把它放在 Build 之前。
#
# 覆盖：node_status()  —— 从 dtc 反编译出的 dts 文本里读某节点的 status
#   · 带 label 前缀的节点（gmac0: ethernet@fe2a0000 / pcie: pcie@fe260000）
#   · 子节点出现在 status 之后、多行属性值、地址前缀相近的节点
#   · status 缺失 → NO-STATUS（调用方据此判失败）、节点不存在 → MISSING
# ══════════════════════════════════════════════════════════════════════════
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${HERE}/../verify-image.sh"
[ -f "$VERIFY" ] || { echo "!! 找不到 ${VERIFY}"; exit 1; }

FAIL=0

# 从 verify-image.sh 里【原样】抽出 node_status()，保证测的就是脚本里那一份
# （行尾 CRLF/LF 都要能吃：开发机上是 CRLF，CI 检出的是 LF）
FUNC="$(awk '/^[[:space:]]*node_status\(\) \{/{f=1} f{print} f&&/^	\}\r?$/{exit}' "$VERIFY" | tr -d '\r')"
if [ -z "${FUNC}" ]; then
	echo "!! 抽不到 node_status()（函数被改名/移动了？）"
	exit 1
fi
case "${FUNC}" in
	*node_status*) ;;
	*) echo "!! 抽出的内容不含 node_status，自测脚本与 verify-image.sh 已不同步"; exit 1 ;;
esac
case "${FUNC}" in
	*python3*) ;;
	*) echo "!! 抽出的 node_status() 里没有 python3，内容异常"; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/sample.dts" <<'DTS'
/dts-v1/;

/ {
	#address-cells = <0x02>;
	#size-cells = <0x02>;
	model = "FriendlyElec NanoPi R5S";
	compatible = "friendlyarm,nanopi-r5s", "rockchip,rk3568";

	gpio-leds {
		compatible = "gpio-leds";
		pinctrl-names = "default";

		led-lan1 {
			gpios = <0x03 0x1a 0x00>;
			label = "LAN-1";
		};
	};

	gmac0: ethernet@fe2a0000 {
		compatible = "rockchip,rk3568-gmac", "snps,dwmac-4.20a";
		reg = <0x00 0xfe2a0000 0x00 0x10000>;
		pinctrl-0 = <0x1c 0x1d
			     0x1e 0x1f>;
		status = "okay";

		mdio {
			#address-cells = <0x01>;
			compatible = "snps,dwmac-mdio";

			ethernet-phy@1 {
				reg = <0x01>;
			};
		};
	};

	pcie: pcie@fe260000 {
		compatible = "rockchip,rk3568-pcie";
		status = "okay";
	};

	pcie@fe270000 {
		compatible = "rockchip,rk3568-pcie";
		status = "disabled";
	};

	ethernet@fe010000 {
		compatible = "rockchip,rk3568-gmac";
	};

	pcie@fe2b0000 {
		compatible = "rockchip,rk3568-pcie";
		status = "okay";
	};
};
DTS

{
	if ! python3 -c "import sys" >/dev/null 2>&1; then
		# 开发机（Windows/MSYS）的 python3 可能只是应用商店占位符，不可用；
		# CI 的 ubuntu 上 python3 是真的，不会走到这里
		echo 'python3() { python "$@"; }'
	fi
	echo "${FUNC}"
	echo 'st=$(node_status "$1" "$2"); printf "%s" "${st}"'
} > "${WORK}/fn.sh"

# 样本 dts 的路径要交给 python 读：开发机（原生 Windows python + MSYS 路径）需要
# 转成 Windows 路径，否则 python 报 FileNotFoundError（CI 的 Linux 上原样可用）
DTS_FILE="${WORK}/sample.dts"
if command -v cygpath >/dev/null 2>&1; then
	DTS_FILE="$(cygpath -w "${DTS_FILE}")"
fi

check() { # $1=节点名 $2=期望输出
	local got err
	got="$(bash "${WORK}/fn.sh" "${DTS_FILE}" "$1" 2>"${WORK}/err" | tr -d '\r')"
	err="$(tr -d '\r' < "${WORK}/err" | head -3)"
	if [ "${got}" = "$2" ]; then
		echo "  OK   node_status $1 -> $got"
	else
		echo "  !!   node_status $1 -> '${got}'（期望 '$2'）"
		[ -n "${err}" ] && echo "       stderr: ${err}"
		FAIL=1
	fi
}

echo "--- verify-image.sh 辅助函数自测 ---"
check 'pcie@fe260000'     'status = "okay";'      # 带 label 前缀
check 'ethernet@fe2a0000' 'status = "okay";'      # 子节点在 status 之后 + 多行属性值
check 'pcie@fe270000'     'status = "disabled";'  # 反例：disabled 必须被读出来
check 'ethernet@fe010000' 'NO-STATUS'             # 无 status 属性（默认启用）
check 'pcie@fe2b0000'     'status = "okay";'      # 地址前缀相近不得误匹配
check 'pcie@fe999999'     'MISSING'               # 节点不存在

if [ "${FAIL}" = "0" ]; then
	echo "verify-image 辅助函数自测通过"
else
	echo "!! verify-image 辅助函数自测失败"
fi
exit "${FAIL}"
