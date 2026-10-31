#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# NanoPi R5S 板级扩展：时钟（防止 roceos 后台「登录一下就退出」）
#
# 机制与 H88K（实机 192.168.10.90）同源，但**本板没有 R5S 实机**，所以这里只按机制
# 处理、不引用任何 R5S 实测数据：
#   1. 镜像里的 /etc/fake-hwclock.data 是构建日期；
#   2. fake-hwclock-load.service 开机用它覆盖系统时间（连 RTC 的真值也盖掉）；
#   3. roceos 用本机时钟签 JWT（有效期 24h）；设备放置数周后开机，系统时间比真实时间
#      早数周 → token 一签发就等于过期；
#   4. 前端拿浏览器真实时间比 exp → 立刻 logout（现象＝"进后台一下就退出"）。
#
# 修法（与 lyw-hh 完全同一套，两仓口径不分裂）：
#   · mask 掉 fake-hwclock-load.service（systemd mask 语义 → 保住 RTC 作时间源）；
#   · /etc/fake-hwclock.data 写构建时刻（万一被别的路径加载也不是几个月前的日期）；
#   · 镜像自带 systemd-timesyncd 就启用（没有就跳过，不联网硬装）。
# 与官方发布件的差异：官方 R1 的 fake-hwclock-load 是 **enabled**，本仓 mask 掉 ——
#   这是有意差异（官方没有做"放置很久再开机"的场景验证），不是构建偏差。
# ══════════════════════════════════════════════════════════════════════════

function post_family_tweaks__lyw_rr_clock_no_fake_hwclock() {
	display_alert "Masking fake-hwclock-load (keeps RTC as time source)" "$EXTENSION" "info"

	install -d -m 0755 "${SDCARD}/etc/systemd/system"

	# systemd mask：/dev/null 软链，任何 enable/start 都不会真的跑
	if [[ -e "${SDCARD}/lib/systemd/system/fake-hwclock-load.service" ]]; then
		ln -sf /dev/null "${SDCARD}/etc/systemd/system/fake-hwclock-load.service"
	fi

	# 时间基准用构建时刻（UTC），格式与 fake-hwclock 一致：YYYY-MM-DD HH:MM:SS
	local stamp
	stamp="$(date -u '+%Y-%m-%d %H:%M:%S')"
	printf '%s\n' "$stamp" > "${SDCARD}/etc/fake-hwclock.data"

	# NTP：镜像自带就开，没装就跳过（不联网硬装，避免构建依赖外网 apt）
	if [[ -f "${SDCARD}/lib/systemd/system/systemd-timesyncd.service" ]]; then
		install -d -m 0755 "${SDCARD}/etc/systemd/system/sysinit.target.wants" \
			"${SDCARD}/etc/systemd/system/multi-user.target.wants"
		ln -sf /lib/systemd/system/systemd-timesyncd.service \
			"${SDCARD}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
	fi

	return 0
}

function post_customize_image__lyw_rr_clock_selfcheck() {
	display_alert "Self-check R5S clock wiring" "$EXTENSION" "info"

	local fail=0
	if [[ -e "${SDCARD}/lib/systemd/system/fake-hwclock-load.service" ]]; then
		[[ "$(readlink "${SDCARD}/etc/systemd/system/fake-hwclock-load.service" 2>/dev/null)" == "/dev/null" ]] \
			|| { display_alert "fake-hwclock-load not masked" "$EXTENSION" "err"; fail=1; }
	fi
	local data="${SDCARD}/etc/fake-hwclock.data"
	[[ -s "$data" ]] || { display_alert "fake-hwclock.data missing" "$EXTENSION" "err"; fail=1; }
	if [[ -s "$data" ]]; then
		grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$data" \
			|| { display_alert "fake-hwclock.data format unexpected: $(cat "$data")" "$EXTENSION" "err"; fail=1; }
		# 必须是"近两天内"的构建时刻（判据动态算，不写死某个日期字面量 —— 写死会随时间变成永远为真）
		local floor
		floor="$(date -u -d '-2 days' '+%Y-%m-%d %H:%M:%S')"
		[[ "$(cat "$data")" > "$floor" ]] \
			|| { display_alert "fake-hwclock.data 不是构建时刻（$(cat "$data") < $floor）" "$EXTENSION" "err"; fail=1; }
	fi

	[[ $fail == 0 ]] || exit_with_error "R5S clock self-check failed"
	return 0
}
