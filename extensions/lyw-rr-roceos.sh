#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# NanoPi R5S 板级扩展：装入 roceos 网页后台（iNextOS 的"后台"就是它）
#
# 为什么要外挂注入（不是我们另起炉灶）：
#   官方 iNextOS 镜像自带 /opt/roceos（Go 服务）+ /opt/roceos-ai + 3 个 systemd
#   服务 + nginx 站点与证书 —— 但上游构建框架 jjm2473/armbian-easepi【不带】这
#   些文件，官方是靠自己的发布流水线注入的。本仓照 lyw-kk 的既有做法，走框架的
#   正规通道 userpatches/overlay 在构建阶段装进镜像（载荷取自 lyw-OS release
#   roceos-payload-v1，sha256 钉死，内容一变立即失败）。
#   不装 = 板子能启动、网络能通，但网页后台是空页面。
#
# 用 post_post_debootstrap_tweaks 这个早期钩子的原因（lyw-kk 实测）：
#   官方 istorenext 扩展就是在这一阶段用 chroot_sdcard systemctl enable 启用它
#   自己的服务；在 customize-image.sh 阶段建 multi-user.target.wants 链接会被后续
#   流程清掉（构建自证失败），改用官方同款阶段链接可留存。
#
# 与 lyw-kk 的差别：本板 BRANCH=current（6.18 主线），SERIALCON=ttyS2，
#   【没有 ttyFIQ0 getty 问题】(那是 vendor/legacy 分支才有的)，故不做 ttyFIQ0
#   屏蔽 —— 屏蔽错会丢串口登录；改为在 tools/verify-image.sh 里断言不得存在。
# ══════════════════════════════════════════════════════════════════════════

# 载荷 sha256（= lyw-OS release roceos-payload-v1；内容一变就报错）
ROCEOS_PAYLOAD_SHA256="6b819584a1b1701163f8983bd59a31821643f64dd65c76ba8f500ef54c5e8bb5"

function post_post_debootstrap_tweaks__lyw_rr_roceos() {
	display_alert "Installing roceos web UI (NanoPi R5S)" "$EXTENSION" "info"

	local payload="${USERPATCHES_PATH}/overlay/roceos-payload.tar.gz"
	[[ -f "$payload" ]] || exit_with_error "roceos payload not found: ${payload}"
	echo "${ROCEOS_PAYLOAD_SHA256}  ${payload}" | sha256sum -c - || exit_with_error "roceos payload sha256 mismatch"

	local stage
	stage="$(mktemp -d)"
	tar xzf "$payload" -C "$stage"
	for f in opt/roceos/roceos opt/roceos/www/index.html opt/roceos-ai/server.py \
		etc/systemd/system/roceos.service etc/nginx/sites-available/roceos.conf \
		etc/nginx/ssl/roceos.key; do
		[[ -e "${stage}/${f}" ]] || exit_with_error "payload missing ${f}"
	done

	# ── 应用本体 ────────────────────────────────────────────────
	mkdir -p "${SDCARD}/opt" "${SDCARD}/storage"
	rm -rf "${SDCARD}/opt/roceos" "${SDCARD}/opt/roceos-ai"
	cp -a "${stage}/opt/roceos" "${stage}/opt/roceos-ai" "${SDCARD}/opt/"
	mkdir -p "${SDCARD}/opt/roceos/data" "${SDCARD}/opt/roceos/logs"
	chmod +x "${SDCARD}/opt/roceos/roceos" "${SDCARD}/opt/roceos/roceos-vision" 2>/dev/null || true
	for b in "${SDCARD}"/opt/roceos/bin/*; do [[ -e "$b" ]] && chmod +x "$b"; done
	chown -R root:root "${SDCARD}/opt/roceos" "${SDCARD}/opt/roceos-ai" "${SDCARD}/storage"

	# ── systemd 服务（官方 unit 无 [Install]，补上 + 直接建链接双保险）──
	for s in roceos.service roceos-ai.service roceos-vision.service; do
		cp -a "${stage}/etc/systemd/system/${s}" "${SDCARD}/etc/systemd/system/"
		if ! grep -q '^\[Install\]' "${SDCARD}/etc/systemd/system/${s}"; then
			printf '\n[Install]\nWantedBy=multi-user.target\n' >> "${SDCARD}/etc/systemd/system/${s}"
		fi
	done

	# ── nginx 站点与证书（default 站点必须移除：与 roceos.conf 抢 default_server）──
	mkdir -p "${SDCARD}/etc/nginx/ssl" "${SDCARD}/etc/nginx/sites-available" "${SDCARD}/etc/nginx/sites-enabled"
	cp -a "${stage}/etc/nginx/ssl/roceos.crt" "${stage}/etc/nginx/ssl/roceos.key" "${SDCARD}/etc/nginx/ssl/"
	cp -a "${stage}/etc/nginx/sites-available/roceos.conf" "${SDCARD}/etc/nginx/sites-available/"
	ln -sf /etc/nginx/sites-available/roceos.conf "${SDCARD}/etc/nginx/sites-enabled/roceos.conf"
	rm -f "${SDCARD}/etc/nginx/sites-enabled/default"

	# ── Flask 栈（roceos-ai 用）：apt 优先，失败回退载荷内文件 ────
	# 注意：chroot_sdcard 以 "$*" 拼串交给 bash -c，引号会被吃掉 —— 必须整条命令一个参数
	chroot_sdcard apt-get install -y -qq python3-flask python3-werkzeug python3-jinja2 \
		python3-itsdangerous python3-markupsafe python3-blinker || true
	local flask_test="python3 -c 'import flask, werkzeug, jinja2, itsdangerous, markupsafe, blinker'"
	local flask_out
	if ! flask_out=$(chroot_sdcard "$flask_test" 2>&1); then
		display_alert "Flask stack not importable (apt had no DNS): ${flask_out##*$'\n'}" "$EXTENSION" "warn"
		mkdir -p "${SDCARD}/usr/lib/python3/dist-packages"
		cp -a "${stage}/usr/lib/python3/dist-packages/." "${SDCARD}/usr/lib/python3/dist-packages/"
		flask_out=$(chroot_sdcard "$flask_test" 2>&1) || \
			exit_with_error "Flask stack still not importable after payload fallback: ${flask_out##*$'\n'}"
		display_alert "Flask stack OK after payload fallback" "$EXTENSION" "info"
	fi

	rm -rf "$stage"

	# ── 启用服务（不用 chroot systemctl enable：实测不生成 wants 链接）──
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	for s in roceos.service roceos-ai.service roceos-vision.service; do
		ln -sf "/etc/systemd/system/${s}" "${SDCARD}/etc/systemd/system/multi-user.target.wants/${s}"
	done

	# ── 防"更新流程删固件"：apt 禁止清单 + 同名空壳包 ──────────────
	# roceos 的"系统更新/安装依赖"会去装发行版固件包，而 armbian-firmware 的 control
	# 里 Provides 且 Conflicts 了其中一部分 —— apt 为满足冲突会把 armbian-firmware
	# 整个卸载，连带删掉它管理的 /lib/firmware 内容（含 RTL8125 网卡固件）。
	# 两道防护：① apt pin -1 禁装互斥包；② 其余装"同名空壳包"让依赖检查成立。
	mkdir -p "${SDCARD}/etc/apt/preferences.d" "${SDCARD}/tmp"
	cat >"${SDCARD}/etc/apt/preferences.d/10-inextos-firmware-conflict" <<-'EOF'
	# 与 armbian-firmware 互斥（armbian-firmware 已 Provides 其全部内容）。
	# 若被安装，apt 会为满足冲突而卸载 armbian-firmware，连带删除网卡固件。
	Package: linux-firmware firmware-brcm80211 firmware-ralink firmware-samsung firmware-realtek armbian-firmware-full
	Pin: version *
	Pin-Priority: -1
	EOF

	local name ver sdir
	for name in firmware-atheros firmware-ath9k-htc firmware-carl9170 firmware-iwlwifi \
		firmware-libertas firmware-mediatek firmware-misc-nonfree firmware-sof-signed \
		firmware-ti-connectivity; do
		case "$name" in
			firmware-ath9k-htc) ver="1.4.0-110-ge888634+dfsg1-0.1" ;;
			firmware-carl9170)  ver="1.9.9-450-gad1c721+dfsg-0.1" ;;
			firmware-sof-signed) ver="2025.01-1" ;;
			*)                   ver="20250410-2" ;;
		esac
		sdir="$(mktemp -d)/${name}"
		mkdir -p "${sdir}/DEBIAN"
		cat >"${sdir}/DEBIAN/control" <<-EOF
		Package: ${name}
		Version: ${ver}+inextos1
		Architecture: all
		Section: kernel
		Priority: optional
		Maintainer: iNextOS NanoPi R5S <root@localhost>
		Description: Compatibility stub for ${name}
		 Firmware content is provided by armbian-firmware. This stub only
		 satisfies dependency checks from the vendor update flow so that
		 installing it cannot remove armbian-firmware or its firmware files.
		EOF
		dpkg-deb -b "${sdir}" "${SDCARD}/tmp/stub-${name}.deb" >/dev/null
		chroot_sdcard dpkg -i "/tmp/stub-${name}.deb" >/dev/null 2>&1 || \
			display_alert "firmware stub ${name} install failed (non-fatal)" "$EXTENSION" "warn"
		rm -rf "$(dirname "$sdir")"
	done
	rm -f "${SDCARD}"/tmp/stub-*.deb

	# ── 阶段内自证 ────────────────────────────────────────────
	local fail=0
	for f in opt/roceos/roceos opt/roceos/www/index.html \
		opt/roceos-ai/server.py opt/roceos-ai/librkllmrt.so \
		etc/systemd/system/roceos.service \
		etc/nginx/sites-available/roceos.conf etc/nginx/ssl/roceos.crt etc/nginx/ssl/roceos.key; do
		[[ -e "${SDCARD}/${f}" ]] || { display_alert "missing ${f}" "$EXTENSION" "err"; fail=1; }
	done
	for f in roceos.service roceos-ai.service roceos-vision.service; do
		[[ -L "${SDCARD}/etc/systemd/system/multi-user.target.wants/${f}" ]] || \
			{ display_alert "missing wants link ${f}" "$EXTENSION" "err"; fail=1; }
	done
	[[ -L "${SDCARD}/etc/nginx/sites-enabled/roceos.conf" ]] || { display_alert "nginx site not enabled" "$EXTENSION" "err"; fail=1; }
	[[ -e "${SDCARD}/etc/nginx/sites-enabled/default" ]] && { display_alert "default site still present" "$EXTENSION" "err"; fail=1; }
	[[ -f "${SDCARD}/etc/apt/preferences.d/10-inextos-firmware-conflict" ]] || { display_alert "apt pin file missing" "$EXTENSION" "err"; fail=1; }
	[[ $fail == 0 ]] || exit_with_error "R5S roceos customization self-check failed"

	display_alert "roceos web UI installed and enabled (NanoPi R5S)" "$EXTENSION" "info"
	return 0
}
