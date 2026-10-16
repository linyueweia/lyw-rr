#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# NanoPi R5S 板级扩展：网口角色归一（roceos 后台的角色表按本板身份纠正）
#
# 背景（lyw-kk 实机定案，本板同源机制）：
#   roceos 的"设置向导"按【枚举顺序】自动分配 wan/lan 角色，在 lyw-kk 上两次装机
#   都分反了。角色真源不是 /etc/roceos/factory-env.json（改了没用），而是 sqlite 库
#   /opt/roceos/data/roceos.db 的三张表：
#     network_interfaces(id,name,type,device,method,...)
#     interface_bindings(binding_name,interface_type,type,physical_nics,physical_nic_macs,...)
#     lan_configs(binding_id,nic_ids,ip_address,netmask,...)
#
# 本板的身份（= csc 里 udev + /etc/eth_order 钉死的同一套，见 config/boards/nanopi-r5s.csc）：
#     eth0 = fe2a0000.ethernet（板载千兆，上游角色口径 = WAN）
#     eth1 = 0000:01:00.0     （PCIe domain 0 的 2.5G，上游 = LAN1）
#     eth2 = 0001:11:00.0     （PCIe domain 1 的 2.5G，上游 = LAN2，网页后台 192.168.100.1）
#   映射表放在 /etc/lyw-rr-net-roles.conf —— 想换角色只改这一个文件（改完重启生效），
#   不要在脚本里改（脚本每次开机按该文件重算，幂等）。
#
# 不做什么：不碰 factory-env.json、不写死任何 MAC、不重启 roceos、不做周期轮询。
# 只在库里已有对应 binding 记录时生效（全新镜像首次开机 roceos 还没建库 → 跳过）。
# ══════════════════════════════════════════════════════════════════════════

function post_post_debootstrap_tweaks__lyw_rr_net_roles() {
	display_alert "Installing NIC role normalizer (NanoPi R5S)" "$EXTENSION" "info"

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/systemd/system"

	# ── 角色映射（唯一可改点）─────────────────────────────────────────────
	cat <<- 'EOF' > "${SDCARD}/etc/lyw-rr-net-roles.conf"
		# NanoPi R5S / iNextOS 网口角色映射（roceos binding 名 = 物理口）
		# 左=roceos 的 binding 名，右=物理口名（由 udev + /etc/eth_order 钉死）
		# 依据：上游 nanopi-r5s.csc 的角色口径 wan1=千兆 / lan1=2.5G#1 / lan2=2.5G#2
		ROLE_MAP="wan1=eth0 lan1=eth1 lan2=eth2"
	EOF

	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py"
		#!/usr/bin/env python3
		# NanoPi R5S：把 roceos 的角色表纠正为 /etc/lyw-rr-net-roles.conf 里的映射（幂等）。
		# 依据：三线实机定案 —— 角色真源是 roceos.db 三张表，不是 factory-env.json。
		import json, os, sqlite3, sys, time

		DB = "/opt/roceos/data/roceos.db"
		CONF = "/etc/lyw-rr-net-roles.conf"
		LOG = "/var/log/lyw-rr-net-roles.log"

		def log(msg):
		    with open(LOG, "a") as f:
		        f.write("[%s] %s\n" % (time.strftime("%F %T"), msg))

		def want_map():
		    raw = ""
		    try:
		        with open(CONF) as f:
		            for line in f:
		                line = line.strip()
		                if line.startswith("ROLE_MAP="):
		                    raw = line.split("=", 1)[1].strip().strip('"')
		    except OSError as e:
		        log("配置文件读取失败 %s: %s" % (CONF, e))
		        return {}
		    out = {}
		    for item in raw.split():
		        if "=" in item:
		            name, dev = item.split("=", 1)
		            out[name.strip()] = dev.strip()
		    return out

		WANT = want_map()
		if not WANT:
		    log("映射为空，跳过（检查 %s）" % CONF)
		    sys.exit(0)

		if not os.path.exists(DB):
		    log("roceos.db 不存在，跳过（首次开机 roceos 尚未建库）")
		    sys.exit(0)

		def mac_of(dev):
		    try:
		        with open("/sys/class/net/%s/address" % dev) as f:
		            return f.read().strip()
		    except OSError:
		        return ""

		con = sqlite3.connect(DB)
		cur = con.cursor()
		fixed = []

		# ① network_interfaces.device
		for name, dev in WANT.items():
		    if not os.path.exists("/sys/class/net/" + dev):
		        log("跳过 %s→%s：接口 %s 不存在" % (name, dev, dev))
		        continue
		    for row in cur.execute("select device from network_interfaces where id=?", (name,)):
		        if row[0] != dev:
		            cur.execute("update network_interfaces set device=?, updated_at=? where id=?",
		                        (dev, time.strftime("%Y-%m-%d %H:%M:%S"), name))
		            fixed.append("network_interfaces.%s.device: %s→%s" % (name, row[0], dev))

		# ② interface_bindings.physical_nics / physical_nic_macs（MAC 取实机现值，绝不写死）
		for name, dev in WANT.items():
		    if not os.path.exists("/sys/class/net/" + dev):
		        continue
		    mac = mac_of(dev)
		    for row in cur.execute(
		            "select physical_nics, physical_nic_macs from interface_bindings where binding_name=?",
		            (name,)):
		        want_nics = json.dumps([dev])
		        want_macs = json.dumps([mac]) if mac else row[1]
		        if row[0] != want_nics or (mac and row[1] != want_macs):
		            cur.execute("update interface_bindings set physical_nics=?, physical_nic_macs=?, updated_at=? "
		                        "where binding_name=?",
		                        (want_nics, want_macs, time.strftime("%Y-%m-%d %H:%M:%S"), name))
		            fixed.append("interface_bindings.%s: %s→%s" % (name, row[0], want_nics))

		# ③ lan_configs.nic_ids（经 binding_id 关联，仅同步网卡列表，不动 IP/掩码/DHCP）
		for name, dev in WANT.items():
		    if not name.startswith("lan") or not os.path.exists("/sys/class/net/" + dev):
		        continue
		    want = json.dumps([dev])
		    for bid, nics in cur.execute(
		            "select b.id, l.nic_ids from interface_bindings b join lan_configs l "
		            "on l.binding_id = b.id where b.binding_name=?", (name,)):
		        if nics != want:
		            cur.execute("update lan_configs set nic_ids=?, updated_at=? where binding_id=?",
		                        (want, time.strftime("%Y-%m-%d %H:%M:%S"), bid))
		            fixed.append("lan_configs(%s).nic_ids: %s→%s" % (name, nics, want))

		if fixed:
		    con.commit()
		    log("已纠正 %d 项：%s" % (len(fixed), "; ".join(fixed)))
		else:
		    log("角色已正确，无需改动")
		con.close()
		sys.exit(0)
	EOF
	chmod 0755 "${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py"

	cat <<- 'EOF' > "${SDCARD}/etc/systemd/system/lyw-rr-net-roles.service"
		[Unit]
		Description=iNextOS(NanoPi R5S): normalize roceos NIC roles (per /etc/lyw-rr-net-roles.conf)
		DefaultDependencies=no
		After=local-fs.target
		Before=roceos.service network-pre.target
		ConditionPathExists=/usr/local/sbin/lyw-rr-net-roles.py

		[Service]
		Type=oneshot
		ExecStart=/usr/local/sbin/lyw-rr-net-roles.py
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	EOF

	# ── 最终态断言 ────────────────────────────────────────────────────────
	local fail=0
	[[ -x "${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py" ]] || {
		display_alert "角色纠正脚本缺失或不可执行" "$EXTENSION" "err"; fail=1; }
	python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" \
		"${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py" 2>/dev/null || {
		display_alert "lyw-rr-net-roles.py 语法错误" "$EXTENSION" "err"; fail=1; }
	grep -q '/opt/roceos/data/roceos.db' "${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py" || {
		display_alert "纠正脚本没指向 roceos.db（改错地方 = 无效）" "$EXTENSION" "err"; fail=1; }
	grep -q 'ROLE_MAP' "${SDCARD}/etc/lyw-rr-net-roles.conf" || {
		display_alert "角色映射文件缺 ROLE_MAP" "$EXTENSION" "err"; fail=1; }
	grep -q 'lan2=eth2' "${SDCARD}/etc/lyw-rr-net-roles.conf" || {
		display_alert "角色映射缺 lan2=eth2（本板三口映射不全）" "$EXTENSION" "err"; fail=1; }
	[[ -f "${SDCARD}/etc/systemd/system/lyw-rr-net-roles.service" ]] || {
		display_alert "角色纠正 unit 缺失" "$EXTENSION" "err"; fail=1; }
	grep -q 'Before=roceos.service' "${SDCARD}/etc/systemd/system/lyw-rr-net-roles.service" || {
		display_alert "unit 未排在 roceos 之前（改了库也要等重启才生效）" "$EXTENSION" "err"; fail=1; }
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/lyw-rr-net-roles.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/lyw-rr-net-roles.service"

	[[ $fail == 0 ]] || exit_with_error "NanoPi R5S NIC role normalizer self-check failed"
	display_alert "NIC role normalizer verified in image" "$EXTENSION" "info"
	return 0
}
