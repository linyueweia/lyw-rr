#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# NanoPi R5S 板级扩展：板载 5V 风扇温控（pwm-fan + 用户态曲线）
#
# 背景（2026-10-17 本板首台实机取证）：
#   mainline/Armbian 的 rk3568-nanopi-r5s.dtb 里没有 fan 节点，pwm0 是 disabled
#   → 内核根本控不到风扇。overlay（config/overlays/rockchip-rk3568-nanopi-r5s-fan.dtso）
#   负责把 pwm0 打开并挂上 pwm-fan 驱动；本扩展负责「怎么转」：
#
#   需求（用户定案）：18°C 开始转，温度越高越快。
#   实现：读 thermal_zone0（cpu-thermal），按 18C→45C 线性映射成 32 档占空比，
#         写 /sys/class/thermal/cooling_deviceN/cur_state（pwm-fan 的档位接口）。
#         5 秒采样一次，值不变就不写（避免无谓唤醒）。
#
# 为什么不用内核 thermal cooling-maps：
#   内核的 step_wise/power_allocator 只能按 trip 点分几档，做不出「18C 起连续变快」；
#   pwm-fan 的 cur_state 在用户态可写，是最小改动路径。若用户态守护进程挂掉，
#   pwm-fan 保持最后一次 duty（不会变成全速或停转），systemd 会拉起。
# ══════════════════════════════════════════════════════════════════════════

function post_post_debootstrap_tweaks__lyw_rr_fan() {
	display_alert "Installing R5S fan curve (18C start -> 45C full)" "$EXTENSION" "info"

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/systemd/system"

cat <<'FANSH' > "${SDCARD}/usr/local/sbin/r5s-fan-control.sh"
#!/bin/bash
# NanoPi R5S fan curve: <=18C off, linear ramp to 100% at 45C.
# Interface: /sys/class/thermal/cooling_deviceN/cur_state (type=pwm-fan).
TZONE=/sys/class/thermal/thermal_zone0/temp
START_C=18
FULL_C=45
INTERVAL=5

find_cd() {
	for d in /sys/class/thermal/cooling_device*; do
		[ -r "$d/type" ] || continue
		[ "$(cat "$d/type" 2>/dev/null)" = "pwm-fan" ] && { echo "$d"; return 0; }
	done
	return 1
}

last=-1
while :; do
	if ! CD=$(find_cd); then sleep 10; continue; fi
	MAXS=$(cat "$CD/max_state" 2>/dev/null || echo 31)
	T=$(cat "$TZONE" 2>/dev/null || echo 0)
	TEMPC=$(( T / 1000 ))
	DUTY=0
	if [ "$TEMPC" -le "$START_C" ]; then
		STATE=0
	else
		DUTY=$(( (TEMPC - START_C) * 255 / (FULL_C - START_C) ))
		[ "$DUTY" -gt 255 ] && DUTY=255
		STATE=$(( (DUTY * MAXS + 127) / 255 ))
		[ "$STATE" -lt 1 ] && STATE=1
		[ "$STATE" -gt "$MAXS" ] && STATE=$MAXS
	fi
	if [ "$STATE" != "$last" ]; then
		if echo "$STATE" > "$CD/cur_state" 2>/dev/null; then
			logger -t r5s-fan "cpu=${TEMPC}C duty=${DUTY}/255 state=${STATE}/${MAXS}"
			last=$STATE
		fi
	fi
	sleep "$INTERVAL"
done
FANSH
	chmod +x "${SDCARD}/usr/local/sbin/r5s-fan-control.sh"

cat <<'FANUNIT' > "${SDCARD}/etc/systemd/system/r5s-fan.service"
[Unit]
Description=NanoPi R5S PWM fan curve (start 18C, full 45C)
After=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/r5s-fan-control.sh
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
FANUNIT

	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/r5s-fan.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/r5s-fan.service"

	# ── 自检（缺一即失败；静默丢失=装机后风扇不调速）──────────────────
	local fail=0
	[ -x "${SDCARD}/usr/local/sbin/r5s-fan-control.sh" ] || {
		display_alert "风扇控制脚本缺失或不可执行" "$EXTENSION" "err"; fail=1; }
	bash -n "${SDCARD}/usr/local/sbin/r5s-fan-control.sh" 2>/dev/null || {
		display_alert "风扇控制脚本语法错误" "$EXTENSION" "err"; fail=1; }
	grep -q '^START_C=18$' "${SDCARD}/usr/local/sbin/r5s-fan-control.sh" || {
		display_alert "风扇起始温度不是 18C" "$EXTENSION" "err"; fail=1; }
	grep -q '^FULL_C=45$' "${SDCARD}/usr/local/sbin/r5s-fan-control.sh" || {
		display_alert "风扇满速温度不是 45C" "$EXTENSION" "err"; fail=1; }
	grep -q 'type)... = "pwm-fan"' "${SDCARD}/usr/local/sbin/r5s-fan-control.sh" || {
		display_alert "风扇脚本没有按 type=pwm-fan 找 cooling_device（换内核会写错设备）" "$EXTENSION" "err"; fail=1; }
	[ -f "${SDCARD}/etc/systemd/system/r5s-fan.service" ] || {
		display_alert "风扇 unit 缺失" "$EXTENSION" "err"; fail=1; }
	if [ "${LYW_RR_SKIP_SYMLINK_ASSERT:-0}" != "1" ]; then
		[[ -L "${SDCARD}/etc/systemd/system/multi-user.target.wants/r5s-fan.service" ]] || {
			display_alert "风扇服务使能链接没建出来（开机不会自启）" "$EXTENSION" "err"; fail=1; }
	fi

	[[ $fail == 0 ]] || exit_with_error "NanoPi R5S fan control self-check failed"
	display_alert "Fan control verified in image (18C -> 45C, 32 steps)" "$EXTENSION" "info"
	return 0
}
