#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 风扇扩展「自检」的负例自测（秒级，挂在构建前；不跑构建也能知道判据是否真在干活）
#
# 起因（2026-10-19 lyw-rr run #19，两小时构建白跑）：
#   扩展里那条自检写的是 grep -q 'type)... = "pwm-fan"' —— 把实现代码当正则匹配，
#   BRE 里 `...` 是任意三个字符、`)` 是字面量 → 永远不命中，而实现本身完全正确。
#   也就是说：判据从来没被真正执行过（本地预检只跑过 verify-image 里的同类断言）。
#
# 本自测直接跑扩展里那段**真实**自检代码（stub 掉框架函数），并证明它既能过也能拦：
#   ① 原样扩展        → rc=0（脚本正确时必须绿）
#   ② 把实现改坏      → rc!=0（实现错了必须红；这一步同时证明判据不是靠注释里的
#      "(type=pwm-fan)" 命中的 —— 注释我们故意保留不动）
#
# 用法：bash tools/tests/fan-hook-test.sh [扩展路径]
# ─────────────────────────────────────────────────────────────────────────────
set -u

EXT=${1:-"$(cd "$(dirname "$0")/../.." && pwd)/extensions/lyw-rr-fan.sh"}
[ -f "$EXT" ] || { echo "!! 找不到扩展: $EXT"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

run_case() { # $1=扩展文件  $2=期望 rc
	local ext=$1 want=$2 sd="$work/sdcard" rc=0
	rm -rf "$sd"; mkdir -p "$sd"
	(
		EXTENSION=lyw-rr-fan
		SDCARD="$sd"
		display_alert() { :; }
		exit_with_error() { echo "    (exit_with_error) $*" >&2; exit 1; }
		# shellcheck disable=SC1090
		source "$ext"
		post_post_debootstrap_tweaks__lyw_rr_fan
	) >"$work/log" 2>&1 || rc=$?
	if [ "$rc" = "$want" ]; then
		echo "  OK   rc=$rc（期望 $want）"
		return 0
	fi
	echo "  BAD  rc=$rc（期望 $want）"
	sed 's/^/       /' "$work/log" | tail -20
	return 1
}

echo "== 正例：扩展原样（风扇脚本正确）→ 自检必须绿"
run_case "$EXT" 0 || exit 1

echo "== 负例：把脚本实现改坏（type 比较改成别的类型）→ 自检必须红"
# 只改实现那一行，注释里仍然留着 "(type=pwm-fan)"：靠 grep 注释的假绿写法在这里会露馅
sed 's/= "pwm-fan" \]/= "not-pwm-fan" ]/' "$EXT" > "$work/bad.sh"
if cmp -s "$EXT" "$work/bad.sh"; then
	echo "  BAD  没能造出负例（sed 没命中实现行，扩展写法变了？）"
	exit 1
fi
run_case "$work/bad.sh" 1 || exit 1

echo "== 风扇自检可用（正例绿 / 负例红）=="
