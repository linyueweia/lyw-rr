#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# NanoPi R5S 板级扩展：关闭所有网口的 EEE/LPI 省电 + 钉死网卡运行时电源管理
#
# 【本板属预防性，非本板实机取证 —— 如实标注】
#   本板（R5S）尚未上机，EEE 在本板上没有被实测复现过。本扩展的依据是同族板
#   三线实机定案（lyw-OS / lyw-kf / lyw-kk，2026-10-13~14）：
#     现象：网口"灯亮但拿不到 IP"、整口间歇 Link Down，用网高峰 34 次/3h；
#     根因：EEE/LPI 省电态进出 7800 万次（对端 phy_eee_wakeup_error_n=8126）
#           → 唤醒时序在 RK3568 dwmac + PHY 组合上翻车 → 整口重新协商；
#     处置：`ethtool --set-eee <if> eee off` 后掉线归零，且重启后必须仍是 off。
#   R5S 的两个 2.5G 口是 RTL8125B，正是最常被报"EEE 抖动/掉线"的一类 PHY，
#   所以按同案同修预防性上齐；上板后按下面的判据实测确认（未确认前不算"已验证"）：
#     判据：`ethtool --show-eee eth1` 的 `EEE status: disabled`；
#           持续跑流 ≥30min，两端 `ethtool -S` 的 rx_crc_errors 仍为 0、Link 不闪断。
#
# 本扩展做五层持久化（缺一层都可能复发）：
#   1) /usr/local/sbin/lyw-rr-eee-off.sh —— 遍历所有真实网卡 --set-eee eee off
#      + 把 /sys/class/net/<if>/device/power/control 钉为 on；带重试；不支持 EEE 的口跳过。
#   2) lyw-rr-eee-off.service —— 开机在网卡就绪后执行一次。
#   3) NetworkManager dispatcher —— 每次接口 up 再关一次（EEE 会随重新协商被打开）。
#   4) ifupdown-ng 的 if-up.d 钩子 —— 本线用 roceos + ifupdown-ng/networking.service，
#      不走 NetworkManager 时上面那条钩子不会触发（三线实机同款坑）。
#   5) 30 秒周期兜底 timer。
# ══════════════════════════════════════════════════════════════════════════

function post_post_debootstrap_tweaks__lyw_rr_net_eee() {
	display_alert "Installing NIC EEE/LPI fix (NanoPi R5S)" "$EXTENSION" "info"

	local fail=0

	if [[ ! -x "${SDCARD}/usr/sbin/ethtool" && ! -x "${SDCARD}/usr/bin/ethtool" ]]; then
		chroot_sdcard_apt_get_install ethtool >/dev/null 2>&1 || true
	fi
	if [[ -x "${SDCARD}/usr/sbin/ethtool" || -x "${SDCARD}/usr/bin/ethtool" ]]; then
		display_alert "ethtool present in image" "$EXTENSION" "info"
	else
		display_alert "ethtool 既不在镜像也无法安装 —— EEE 关闭服务将无效" "$EXTENSION" "err"
		fail=1
	fi

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/systemd/system"
	mkdir -p "${SDCARD}/etc/NetworkManager/dispatcher.d" "${SDCARD}/etc/network/if-up.d"

	# ── 1) 关闭脚本 ──
	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/lyw-rr-eee-off.sh"
		#!/bin/sh
		# NanoPi R5S / iNextOS：关闭所有真实网卡的 EEE/LPI 省电，并把运行时电源管理钉为 on。
		# 幂等：可反复执行（开机一次 + 每次接口 up 一次 + 每 30 秒兜底 + 人工随时跑）。
		ETHTOOL="$(command -v ethtool 2>/dev/null || echo /usr/sbin/ethtool)"
		[ -x "$ETHTOOL" ] || { echo "lyw-rr-eee-off: ethtool missing"; exit 1; }

		attempt=0
		while [ "$attempt" -lt 15 ]; do
			attempt=$((attempt + 1))
			pending=0
			for d in /sys/class/net/*; do
				[ -e "$d" ] || continue
				nic=${d##*/}
				case "$nic" in
					lo|docker*|veth*|br-*|virbr*|wg*|tailscale*|tun*|p2p*) continue ;;
				esac
				"$ETHTOOL" --set-eee "$nic" tx-lpi off 2>/dev/null || true
				"$ETHTOOL" --set-eee "$nic" rx-lpi off 2>/dev/null || true
				if ! "$ETHTOOL" --set-eee "$nic" eee off 2>/dev/null; then
					# set 失败：该口若根本不支持 EEE（--show-eee 也失败）就不算欠账
					if "$ETHTOOL" --show-eee "$nic" >/dev/null 2>&1; then
						pending=1
					fi
				fi
				pm="$d/device/power/control"
				if [ -w "$pm" ]; then
					echo on > "$pm" 2>/dev/null || true
				fi
			done
			[ "$pending" -eq 0 ] && break
			sleep 2
		done
		echo "lyw-rr-eee-off: done (attempt=$attempt)"
		exit 0
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/lyw-rr-eee-off.sh"

	# ── 2) 开机执行一次 ──
	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/lyw-rr-eee-off.service"
		[Unit]
		Description=iNextOS(NanoPi R5S): disable NIC EEE/LPI (link-stability fix)
		After=network-online.target
		Wants=network-online.target
		ConditionPathExists=/usr/local/sbin/lyw-rr-eee-off.sh

		[Service]
		Type=oneshot
		ExecStart=/bin/sh /usr/local/sbin/lyw-rr-eee-off.sh
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	# ── 3) NetworkManager dispatcher（每次接口 up 再关）──
	cat <<- 'EOF' > "${SDCARD}/etc/NetworkManager/dispatcher.d/90-lyw-rr-eee-off"
		#!/bin/sh
		# NM 在每个接口状态变化时调用：$1=接口 $2=动作。脚本幂等，重复调用无副作用。
		ACTION="$2"
		case "$ACTION" in
			up|dhcp4-change|dhcp6-change|connectivity-change) ;;
			*) exit 0 ;;
		esac
		[ -x /usr/local/sbin/lyw-rr-eee-off.sh ] || exit 0
		# dispatcher 是同步阻塞路径：放后台跑，避免拖慢 NM 状态机
		( /bin/sh /usr/local/sbin/lyw-rr-eee-off.sh >>/var/log/lyw-rr-eee-off.log 2>&1 & ) >/dev/null 2>&1
		exit 0
	EOF
	chmod 0755 "${SDCARD}/etc/NetworkManager/dispatcher.d/90-lyw-rr-eee-off"

	# ── 4) ifupdown(-ng) 的 if-up.d 钩子（本线实际用 networking.service）──
	cat <<- 'EOF' > "${SDCARD}/etc/network/if-up.d/zz-lyw-rr-eee-off"
		#!/bin/sh
		# ifupdown-ng / ifupdown：接口每次 up 之后再关一次 EEE（PHY 会在 link-up 时重新使能）
		[ "${IFACE}" = "lo" ] && exit 0
		/usr/local/sbin/lyw-rr-eee-off.sh >/dev/null 2>&1 &
		exit 0
	EOF
	chmod 0755 "${SDCARD}/etc/network/if-up.d/zz-lyw-rr-eee-off"

	# ── 5) 周期兜底 ──
	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/lyw-rr-eee-off-watch.service"
		[Unit]
		Description=NanoPi R5S periodic NIC EEE/LPI off re-apply (link stability)
		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/lyw-rr-eee-off.sh
	EOF
	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/lyw-rr-eee-off-watch.timer"
		[Unit]
		Description=NanoPi R5S periodic NIC EEE re-apply timer
		[Timer]
		OnBootSec=45s
		OnUnitActiveSec=30s
		AccuracySec=5s
		Unit=lyw-rr-eee-off-watch.service
		[Install]
		WantedBy=timers.target
	EOF

	# ── 6) 使能（必须在本阶段落地：enable 链接属于 rootfs，要和 unit 同一阶段写）──
	# 坑（2026-10-16 run #6 实证）：pre_umount_final_image 钩子只改得动 ${MOUNT}——
	# 框架在 create_image_from_sdcard_rootfs 开头就把 rootfs rsync 进镜像，之后再改
	# ${SDCARD} 全部进不了镜像（官方扩展在该钩子里也一律写 ${MOUNT}）。本扩展原先只在
	# final-pass 里用 ${SDCARD} 建这两条链接 → 镜像里根本没有、开机不自启；而自证读的是
	# ${SDCARD} 所以误报“已验证”。这里用 chroot_sdcard enable（lyw-kk 真机验证过）+ 直接建链接。
	chroot_sdcard systemctl --no-reload enable lyw-rr-eee-off.service >/dev/null 2>&1 || true
	chroot_sdcard systemctl --no-reload enable lyw-rr-eee-off-watch.timer >/dev/null 2>&1 || true
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants" \
		"${SDCARD}/etc/systemd/system/timers.target.wants"
	ln -sf /etc/systemd/system/lyw-rr-eee-off.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service"
	ln -sf /etc/systemd/system/lyw-rr-eee-off-watch.timer \
		"${SDCARD}/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer"
	[[ -L "${SDCARD}/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service" ]] || {
		display_alert "EEE 服务 enable 链接未建" "$EXTENSION" "err"; fail=1; }
	[[ -L "${SDCARD}/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer" ]] || {
		display_alert "EEE 兜底 timer enable 链接未建" "$EXTENSION" "err"; fail=1; }

	if [[ $fail -ne 0 ]]; then
		exit_with_error "NanoPi R5S EEE fix incomplete (ethtool unavailable)"
	fi
	display_alert "NIC EEE off installed (script + service + NM dispatcher + ifupdown hook + 30s timer)" "$EXTENSION" "info"
	return 0
}

# ══════════════════════════════════════════════════════════════════════════
# 最终态断言：关不掉 EEE 就等于链路间歇掉线会复发 —— 直接 fail，不静默
# ⚠ 本钩子里的“镜像”是 ${MOUNT}（rootfs 已 rsync 进镜像），不是 ${SDCARD}：
#   读/写 ${SDCARD} 会得出与真实产物无关的结论（run #6 就是这么误报的）。
# ══════════════════════════════════════════════════════════════════════════
function pre_umount_final_image__lyw_rr_net_eee() {
	display_alert "Final-pass: verify NIC EEE fix (NanoPi R5S)" "$EXTENSION" "info"

	local IMG_ROOT="${MOUNT}"
	if [[ ! -d "${IMG_ROOT}/etc/systemd/system" || ! -d "${IMG_ROOT}/usr" ]]; then
		exit_with_error "final-pass 的镜像根不像镜像（MOUNT=${IMG_ROOT}）—— 拒绝输出假结论"
	fi

	local fail=0
	[[ -x "${IMG_ROOT}/usr/local/sbin/lyw-rr-eee-off.sh" ]] || {
		display_alert "EEE 关闭脚本未就位" "$EXTENSION" "err"; fail=1; }
	sh -n "${IMG_ROOT}/usr/local/sbin/lyw-rr-eee-off.sh" 2>/dev/null || {
		display_alert "lyw-rr-eee-off.sh 语法错误" "$EXTENSION" "err"; fail=1; }
	grep -q -- '--set-eee' "${IMG_ROOT}/usr/local/sbin/lyw-rr-eee-off.sh" || {
		display_alert "EEE 脚本缺 --set-eee" "$EXTENSION" "err"; fail=1; }
	grep -q 'eee off' "${IMG_ROOT}/usr/local/sbin/lyw-rr-eee-off.sh" || {
		display_alert "EEE 脚本缺 'eee off'" "$EXTENSION" "err"; fail=1; }
	grep -q 'power/control' "${IMG_ROOT}/usr/local/sbin/lyw-rr-eee-off.sh" || {
		display_alert "EEE 脚本缺 power/control 钉死" "$EXTENSION" "err"; fail=1; }

	[[ -f "${IMG_ROOT}/etc/systemd/system/lyw-rr-eee-off.service" ]] || {
		display_alert "EEE 服务单元缺失" "$EXTENSION" "err"; fail=1; }
	[[ -x "${IMG_ROOT}/etc/NetworkManager/dispatcher.d/90-lyw-rr-eee-off" ]] || {
		display_alert "NM dispatcher 缺失（接口 up 后不会重新关 EEE）" "$EXTENSION" "err"; fail=1; }
	[[ -x "${IMG_ROOT}/etc/network/if-up.d/zz-lyw-rr-eee-off" ]] || {
		display_alert "ifupdown 钩子缺失（roceos 重配网络后 EEE 会复发）" "$EXTENSION" "err"; fail=1; }
	[[ -f "${IMG_ROOT}/etc/systemd/system/lyw-rr-eee-off-watch.timer" ]] || {
		display_alert "EEE 周期兜底 timer 缺失" "$EXTENSION" "err"; fail=1; }

	# 使能链接：正常已在 post_debootstrap 阶段建好；这里补建并用 -L 断真身
	mkdir -p "${IMG_ROOT}/etc/systemd/system/multi-user.target.wants" \
		"${IMG_ROOT}/etc/systemd/system/timers.target.wants"
	[[ -L "${IMG_ROOT}/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service" ]] || \
		ln -sf /etc/systemd/system/lyw-rr-eee-off.service \
			"${IMG_ROOT}/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service"
	[[ -L "${IMG_ROOT}/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer" ]] || \
		ln -sf /etc/systemd/system/lyw-rr-eee-off-watch.timer \
			"${IMG_ROOT}/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer"
	[[ -L "${IMG_ROOT}/etc/systemd/system/multi-user.target.wants/lyw-rr-eee-off.service" ]] || {
		display_alert "EEE 服务 enable 链接不在镜像里（开机不会自启）" "$EXTENSION" "err"; fail=1; }
	[[ -L "${IMG_ROOT}/etc/systemd/system/timers.target.wants/lyw-rr-eee-off-watch.timer" ]] || {
		display_alert "EEE 兜底 timer enable 链接不在镜像里" "$EXTENSION" "err"; fail=1; }

	local et
	et="$(ls "${IMG_ROOT}"/usr/sbin/ethtool "${IMG_ROOT}"/usr/bin/ethtool 2>/dev/null | head -1 || true)"
	[[ -n "$et" ]] || { display_alert "镜像缺 ethtool" "$EXTENSION" "err"; fail=1; }

	[[ $fail == 0 ]] || exit_with_error "NanoPi R5S EEE fix self-check failed"
	display_alert "NIC EEE fix verified in image" "$EXTENSION" "info"
	return 0
}
