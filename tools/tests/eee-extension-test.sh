#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# 前置自测：EEE 扩展的 enable 链接必须落在"会进镜像的那一阶段"。
#
# 背景（2026-10-16 run #6 事故）：框架在 create_image_from_sdcard_rootfs 开头就把
# rootfs rsync 进 ${MOUNT}（镜像 loop 挂载点）；此后 pre_umount_final_image 钩子里
# 对 ${SDCARD} 的任何改动都进不了镜像（官方扩展在该钩子里一律写 ${MOUNT}）。
# 本扩展原先只在 final-pass 用 ${SDCARD} 建两条 enable 链接 → 镜像里没有、
# 开机不自启；而扩展自证读的也是 ${SDCARD}，于是误报"已在镜像里"。
#
# 本测试在 Build 之前（秒级）跑：正例证明两条链接真的建得出来且落在正确位置，
# 负例证明坏布局会被拦住（不会带着缺陷白跑 117 分钟）。
# ══════════════════════════════════════════════════════════════════════════
set -u

EXT="${1:?用法: eee-extension-test.sh <extensions/lyw-rr-net-eee.sh>}"
[[ -f "$EXT" ]] || { echo "!! 找不到扩展: $EXT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 框架桩（错误函数必须真退出；否则失败后代码继续跑会打出假绿）──
display_alert() { echo "   [alert] $1"; }
exit_with_error() { echo "   [FATAL] $*" >&2; exit 1; }
chroot_sdcard() { echo "   [chroot] $*"; return 0; }

FAILED=0
run_case() { # $1=名称 $2=期望rc
	local name="$1" want="$2" rc=0
	( run_body ); rc=$?          # 子 shell：被调用函数里的 exit_with_error 只结束本用例
	if [[ "$rc" == "$want" ]]; then
		echo "PASS  $name (rc=$rc)"
	else
		echo "FAIL  $name (rc=$rc, want=$want)"; FAILED=1
	fi
}

# 本机能否建符号链接：Linux CI 里必须能；Windows/MSYS 无特权时正例只能跳过
# （跳过必须响亮，且 Linux 上失败一律硬失败 —— 不许静默降级成"绿"）
SYMLINK_OK=1
if ! ( cd "$TMP" && touch .probe && ln -s .probe .probelink ) >/dev/null 2>&1; then
	SYMLINK_OK=0
	if [[ "$(uname -s)" == "Linux" ]]; then
		echo "!! Linux 上建不了符号链接 —— 环境异常，硬失败"; exit 1
	fi
	echo "SKIP  两条正例（本机无建链权限，$(uname -s)）—— 正例由 Linux CI 的前置自测负责"
fi
# 本机调试用：EEE_TEST_FORCE_SYMLINK_OK=1 可强行让正例跑一遍（预期会失败），
# 用来暴露"只在 Linux 才走到的代码路径"里的语法/变量问题（set -u 下最爱炸）。
if [[ "${EEE_TEST_FORCE_SYMLINK_OK:-0}" == "1" ]]; then
	echo "NOTE  已强制正例路径（仅本机调试；预期正例会 FAIL）"
	SYMLINK_OK=1
fi

# 静态反回归 ①：final-pass 里不得出现 ${SDCARD}
awk '/^function pre_umount_final_image__lyw_rr_net_eee\(\)/,0' "$EXT" > "$TMP/finalpass.txt"
if grep -q '\${SDCARD}' "$TMP/finalpass.txt"; then
	echo "FAIL  final-pass 里仍出现 \${SDCARD}（该钩子只改得动 \${MOUNT}，改动进不了镜像）"
	FAILED=1
else
	echo "PASS  final-pass 只使用 \${MOUNT}"
fi

# 静态反回归 ②：post_debootstrap 阶段必须自己建那两条 enable 链接
awk '/^function post_post_debootstrap_tweaks__lyw_rr_net_eee\(\)/,/^}/' "$EXT" > "$TMP/post.txt"
for spec in \
	'multi-user.target.wants/lyw-rr-eee-off.service' \
	'timers.target.wants/lyw-rr-eee-off-watch.timer'; do
	if grep -q "ln -sf /etc/systemd/system/${spec##*/}" "$TMP/post.txt" \
		&& grep -q "\${SDCARD}/etc/systemd/system/${spec}" "$TMP/post.txt"; then
		echo "PASS  post 阶段建链接: ${spec}"
	else
		echo "FAIL  post 阶段没有把 ${spec} 建进 \${SDCARD}（镜像里就不会有，开机不自启）"
		FAILED=1
	fi
done

# 用例 1：post_debootstrap 阶段必须把两条 enable 链接建进 ${SDCARD}
run_body() {
	if [[ "$SYMLINK_OK" == 0 ]]; then return 0; fi
	export EXTENSION="lyw-rr-net-eee" SDCARD="$TMP/rootfs"
	rm -rf "$SDCARD"; mkdir -p "$SDCARD/usr/sbin" "$SDCARD/etc/systemd/system"
	touch "$SDCARD/usr/sbin/ethtool"; chmod +x "$SDCARD/usr/sbin/ethtool"
	# shellcheck disable=SC1090
	source "$EXT"
	post_post_debootstrap_tweaks__lyw_rr_net_eee || return $?
	[[ -x "$SDCARD/usr/local/sbin/lyw-rr-eee-off.sh" ]] || { echo "   缺 eee-off.sh"; return 90; }
	[[ -L "$SDCARD/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service" ]] || { echo "   缺服务 enable 链接"; return 91; }
	[[ -L "$SDCARD/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer" ]] || { echo "   缺 timer enable 链接"; return 92; }
}
if [[ "$SYMLINK_OK" == 1 ]]; then
	run_case "post 阶段：两条 enable 链接落进 rootfs（会随 rsync 进镜像）" 0
fi

# 用例 2：final-pass 以 ${MOUNT} 为准，并能补建镜像里缺失的链接
run_body() {
	if [[ "$SYMLINK_OK" == 0 ]]; then return 0; fi
	export EXTENSION="lyw-rr-net-eee" SDCARD="$TMP/rootfs" MOUNT="$TMP/image"
	rm -rf "$MOUNT"; mkdir -p "$MOUNT"; cp -a "$SDCARD/." "$MOUNT/"
	rm -f "$MOUNT/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service" \
	      "$MOUNT/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer"
	# shellcheck disable=SC1090
	source "$EXT"
	pre_umount_final_image__lyw_rr_net_eee || return $?
	[[ -L "$MOUNT/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service" ]] || return 93
	[[ -L "$MOUNT/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer" ]] || return 94
	# 链接必须指向镜像内的绝对路径（标准 enable 形态）
	printf '%s' "$(readlink "$MOUNT/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer")" \
		| grep -q '^/etc/systemd/system/lyw-rr-eee-off-watch.timer$' || return 95
}
if [[ "$SYMLINK_OK" == 1 ]]; then
	run_case "final-pass：以镜像根为准，补建缺失链接并以 -L 断真身" 0
fi

# 用例 3（负例）：${MOUNT} 不是镜像 → 必须响亮失败（不许输出一屏假断言）
run_body() {
	export EXTENSION="lyw-rr-net-eee" SDCARD="$TMP/rootfs3" MOUNT="$TMP/not-an-image"
	rm -rf "$MOUNT" "$SDCARD"; mkdir -p "$MOUNT" "$SDCARD"
	# shellcheck disable=SC1090
	source "$EXT"
	pre_umount_final_image__lyw_rr_net_eee
}
run_case "负例：\${MOUNT} 不像镜像 → exit_with_error" 1

# 用例 4（负例）：enable 链接建不出来（wants 目录位置被同名文件占住）→ 必须失败
run_body() {
	export EXTENSION="lyw-rr-net-eee" SDCARD="$TMP/rootfs4"
	rm -rf "$SDCARD"; mkdir -p "$SDCARD/usr/sbin" "$SDCARD/etc/systemd/system"
	touch "$SDCARD/usr/sbin/ethtool"; chmod +x "$SDCARD/usr/sbin/ethtool"
	touch "$SDCARD/etc/systemd/system/timers.target.wants"   # 占位文件
	# shellcheck disable=SC1090
	source "$EXT"
	post_post_debootstrap_tweaks__lyw_rr_net_eee
}
run_case "负例：timer 链接建不出来 → exit_with_error" 1

if [[ "$FAILED" == 0 ]]; then
	echo "== EEE 扩展前置自测通过（链接落在 rootfs 阶段 + final-pass 以镜像为准）=="
else
	echo "!! EEE 扩展前置自测失败"; exit 1
fi
