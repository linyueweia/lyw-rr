#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# overlay-makefile-patch.py 的正/负例自测（秒级，不需要内核树、不需要 root）
#
# 为什么存在（2026-10-19 lyw-rr run #21）：
#   fan.dtso 已经拷进框架的 overlay 目录，但因为框架的 overlay Makefile 是
#   【显式枚举】每个 dtbo 的，没登记就不编译 → 镜像里没有 fan.dtbo，
#   4.7 GiB 镜像编完、上传完，最后倒在自证一行上（风扇也没有 cooling device）。
#   这类「机制没生效但脚本没报错」的坑，只有把判据本身跑一遍负例才能提前发现。
#
# 覆盖：
#   ① leds 上游已登记 / fan 缺登记 → --check 必须红；写入后 fan 恰好 1 处、位于 dtb-y 之前
#   ② 幂等：再跑一次不产生第二份登记，rc=0，--check 也绿
#   ③ Makefile 缺 `dtb-y … $(dtbo-y)` 聚合行 → 必须红（登记了也不编译）
#   ④ 重复登记 → 必须红
#   ⑤ 有 dtso 但目录里没有 Makefile → 必须红
#   ⑥ 框架目录里根本没有本仓 dtso（注入没跑）→ 必须红
#
# 用法：bash tools/tests/overlay-makefile-patch-test.sh
# ══════════════════════════════════════════════════════════════════════════
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${HERE}/../overlay-makefile-patch.py"
SRC="${HERE}/../../config/overlays"
[ -f "$TOOL" ] || { echo "!! 找不到 $TOOL"; exit 1; }

# 原生 Python（Windows）不认 MSYS 的 /c/... 或 /tmp/...；有 cygpath 就转成 C:/ 形式
nat() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# CI 上是 python3；开发机（Windows/MSYS）上 python3 可能是应用商店别名占位（一跑就报
# "Python was not found"），所以按可用性挑一个
PY=""
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "!! 找不到可用的 python（python3/python 都跑不起来）"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  BAD  $*"; FAIL=1; }

# 期望 rc：run_expect <期望rc> <标签> <archive> [额外参数...]
run_expect() {
	local want=$1 label=$2 arc=$3; shift 3
	local rc=0
	"$PY" "$(nat "$TOOL")" "$(nat "$arc")" --overlay-src "$(nat "$SRC")" "$@" >"$WORK/out" 2>&1 || rc=$?
	if [ "$rc" = "$want" ]; then
		ok "${label}（rc=$rc，期望 $want）"
	else
		bad "${label}（rc=$rc，期望 $want）"
		sed 's/^/       /' "$WORK/out" | tail -15
	fi
}

# 与上游 rockchip64-6.18/overlay/Makefile 同构的最小样本（dtbo 显式枚举 + dtb-y 聚合）
make_makefile() { # $1=目标路径  $2=额外条目（可为空）  $3=1 则省略 dtb-y 聚合行
	mkdir -p "$(dirname "$1")"
	{
		echo '# SPDX-License-Identifier: GPL-2.0'
		echo 'dtbo-$(CONFIG_ARCH_ROCKCHIP) += \'
		echo '	rockchip-rk3568-nanopi-r5s-leds.dtbo \'
		[ -n "${2:-}" ] && printf '	%s\n' "$2"
		echo '	rockchip-rk3328-spi-spidev.dtbo'
		echo
		[ "${3:-0}" = "1" ] || echo 'dtb-y += $(dtbo-y) $(scr-y) $(dtbotxt-y)'
		echo
		echo 'clean-files    := *.dtbo *.scr'
	} >"$1"
}

echo "== ① 缺登记：--check 必须红，写入后必须恰好登记一次且排在 dtb-y 之前"
A="$WORK/ok/patch/kernel/archive"
make_makefile "$A/rockchip64-6.18/overlay/Makefile" "" 0
cp "$SRC"/*.dtso "$A/rockchip64-6.18/overlay/"
[ "$(ls "$A/rockchip64-6.18/overlay/" | grep -c '\.dtso$')" -ge 2 ] \
	|| { bad "样本里应有 ≥2 个 dtso（leds + fan），实际 $(ls "$A/rockchip64-6.18/overlay/")"; }
run_expect 1 "缺登记时 --check 报红" "$A" --check
grep -q '未登记 rockchip-rk3568-nanopi-r5s-fan.dtbo' "$WORK/out" \
	&& ok "报错点名 fan.dtbo" || bad "报错没点名 fan.dtbo"

run_expect 0 "写入模式登记成功" "$A"
MK="$A/rockchip64-6.18/overlay/Makefile"
CNT=$(grep -c '^dtbo-\$(CONFIG_ARCH_ROCKCHIP) += rockchip-rk3568-nanopi-r5s-fan.dtbo$' "$MK" || true)
[ "${CNT:-0}" = "1" ] && ok "fan.dtbo 恰好登记 1 处" || bad "fan.dtbo 登记次数=${CNT:-0}（应为 1）"
LEDS=$(grep -c 'rockchip-rk3568-nanopi-r5s-leds\.dtbo' "$MK" || true)
[ "${LEDS:-0}" = "1" ] && ok "上游已登记的 leds 没被改动" || bad "leds 登记次数=${LEDS:-0}（应为 1）"
awk '/nanopi-r5s-fan\.dtbo/{f=NR} /^dtb-y /{d=NR} END{exit !(f && d && f < d)}' "$MK" \
	&& ok "登记行在 dtb-y 聚合行之前（否则不会进 dtb-y）" || bad "登记行位置不对（必须在 dtb-y 之前）"
run_expect 0 "登记后 --check 转绿" "$A" --check

echo "== ② 幂等：再跑一次不产生第二份登记"
run_expect 0 "二次写入 rc=0" "$A"
CNT=$(grep -c 'nanopi-r5s-fan\.dtbo' "$MK" || true)
[ "${CNT:-0}" = "1" ] && ok "仍然只有 1 处（幂等）" || bad "二次写入后出现 ${CNT} 处"

echo "== ③ 缺 dtb-y 聚合行 → 必须红（登记了也不会编译）"
B="$WORK/nodtby/patch/kernel/archive"
make_makefile "$B/rockchip64-6.18/overlay/Makefile" "" 1
cp "$SRC"/*.dtso "$B/rockchip64-6.18/overlay/"
run_expect 1 "缺 dtb-y … \$(dtbo-y) 时判红" "$B"

echo "== ④ 重复登记 → 必须红"
C="$WORK/dup/patch/kernel/archive"
make_makefile "$C/rockchip64-6.18/overlay/Makefile" "rockchip-rk3568-nanopi-r5s-fan.dtbo" 0
cp "$SRC"/*.dtso "$C/rockchip64-6.18/overlay/"
# 再写一次同名条目，制造重复
printf 'dtbo-$(CONFIG_ARCH_ROCKCHIP) += rockchip-rk3568-nanopi-r5s-fan.dtbo\n' \
	>>"$C/rockchip64-6.18/overlay/Makefile"
run_expect 1 "重复登记时判红" "$C"

echo "== ⑤ 有本仓 dtso 但目录里没有 Makefile → 必须红"
D="$WORK/nomk/patch/kernel/archive"
mkdir -p "$D/rockchip64-6.18/overlay"
cp "$SRC"/*.dtso "$D/rockchip64-6.18/overlay/"
run_expect 1 "缺 Makefile 时判红" "$D"

echo "== ⑥ 框架目录里没有本仓 dtso（注入没跑）→ 必须红"
E="$WORK/nodtso/patch/kernel/archive"
make_makefile "$E/rockchip64-6.18/overlay/Makefile" "" 0
run_expect 1 "一个分支都没拷到 dtso 时判红" "$E"

echo
if [ "$FAIL" = "0" ]; then
	echo "== overlay Makefile 登记判据可用（正例绿 / 六类负例全部拦下）=="
	exit 0
fi
echo "!! 有失败项（见上）"
exit 1
