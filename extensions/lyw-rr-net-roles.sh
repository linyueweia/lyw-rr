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
		# NanoPi R5S / iNextOS 默认网口角色（2026-10-17 定案：WAN=1G，两个 2.5G 同属一个 LAN 桥）
		#   左=roceos 的 binding 名，右=物理口名（udev + /etc/eth_order 钉死）；逗号=同一桥的多个成员
		#   丝印：LAN2(2.5G,最左)=eth2 / LAN1(2.5G,中间)=eth1 / WAN(1G,最右)=eth0
		#   默认：eth0 单独当 WAN；eth1+eth2 一起进 lan1 桥（192.168.100.1 在桥上，插任一 2.5G 口都能进）
		#   只在首启套用一次；之后用户在网页后台怎么改都保留（脚本只修名字漂移、把孤儿口并入 LAN 桥）。
		ROLE_MAP="wan1=eth0 lan1=eth1,eth2"
	EOF

	cat <<- 'EOF' > "${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py"
		#!/usr/bin/env python3
		# NanoPi R5S：roceos 网口"身份/一致性"归一（幂等，2026-10-17 重写 v3）
		#
		# 设计原则（实机踩坑后定的）：
		#   · 唯一真源是 interface_bindings（绑定：binding_name → physical_nics/physical_nic_macs）；
		#     network_interfaces.device 与 lan_configs.nic_ids 必须【镜像】它，否则网页后台显示的
		#     网桥成员和内核里真实成员会不一致（本板就是这样：bindings 有 eth1+eth0，nic_ids 只有 eth1）。
		#   · 绝不"缩小"网桥/绝不按 ROLE_MAP 覆盖用户选择（除首启那一次）。
		#   · 认身份用 MAC，不用名字：udev 改名后名字会漂移，MAC 不会。
		#   · 没被任何 binding 收录的真实网口 = 孤儿口（首启时 PCIe 第二 domain 的 2.5G 还没枚举出来），
		#     自动并进 LAN 桥，避免"插了线什么都不是"。
		import json, os, sqlite3, sys, time

		DB = "/opt/roceos/data/roceos.db"
		CONF = "/etc/lyw-rr-net-roles.conf"
		LOG = "/var/log/lyw-rr-net-roles.log"
		MARK = "/var/lib/lyw-rr-net-roles.done"
		TS = time.strftime("%Y-%m-%d %H:%M:%S")


		def log(msg):
		    try:
		        with open(LOG, "a") as f:
		            f.write("[%s] %s\n" % (TS, msg))
		    except OSError:
		        pass


		def mac_map():
		    out = {}
		    try:
		        for n in os.listdir("/sys/class/net"):
		            if not n.startswith("eth"):
		                continue
		            try:
		                with open("/sys/class/net/%s/address" % n) as f:
		                    out[f.read().strip().lower()] = n
		            except OSError:
		                pass
		    except OSError:
		        pass
		    return out


		def live_ifaces():
		    try:
		        return sorted(n for n in os.listdir("/sys/class/net") if n.startswith("eth"))
		    except OSError:
		        return []


		def mac_of(dev):
		    try:
		        with open("/sys/class/net/%s/address" % dev) as f:
		            return f.read().strip().lower()
		    except OSError:
		        return ""


		def want_map():
		    raw = ""
		    try:
		        with open(CONF) as f:
		            for line in f:
		                if line.strip().startswith("ROLE_MAP="):
		                    raw = line.strip().split("=", 1)[1].strip().strip('"')
		    except OSError:
		        return {}
		    out = {}
		    for item in raw.split():
		        if "=" in item:
		            k, v = item.split("=", 1)
		            devs = [x for x in v.replace("+", ",").split(",") if x]
		            out[k.strip()] = devs
		    return out


		# 等所有网口枚举完（第二 PCIe domain 的 2.5G 可能比 roceos 建库晚很久）
		WANT = want_map()
		deadline = time.time() + 90
		need = max(sum(len(v) for v in WANT.values()), 3)
		while time.time() < deadline and len(live_ifaces()) < need:
		    time.sleep(3)

		if not os.path.exists(DB):
		    log("roceos.db 不存在，跳过（roceos 尚未建库）")
		    sys.exit(0)

		con = sqlite3.connect(DB)
		cur = con.cursor()
		MAC2NAME = mac_map()
		fixed = []


		def rows(sql, args=()):
		    try:
		        return list(cur.execute(sql, args))
		    except sqlite3.Error as e:
		        log("查询失败: %s" % e)
		        return []


		bindings = rows("select id, binding_name, interface_type, physical_nics, physical_nic_macs "
		                "from interface_bindings order by binding_name")

		# ── 首启（只做一次）：按 ROLE_MAP 把 roceos 向导分配的 role→口 纠正成本板口径 ──
		if not os.path.exists(MARK):
		    devs_of = {k: [d for d in v if os.path.exists("/sys/class/net/" + d)] for k, v in WANT.items()}
		    for name, devs in devs_of.items():
		        if not devs:
		            continue
		        want_nics = json.dumps(devs)
		        want_macs = json.dumps([mac_of(d) for d in devs])
		        for bid, bname, itype, nics, macs in bindings:
		            if bname != name:
		                continue
		            if nics != want_nics:
		                cur.execute("update interface_bindings set physical_nics=?, physical_nic_macs=?, updated_at=? "
		                            "where id=?", (want_nics, want_macs, TS, bid))
		                fixed.append("首启 %s: %s→%s" % (name, nics, want_nics))
		            if bname.startswith("lan"):
		                cur.execute("update lan_configs set nic_ids=?, updated_at=? where binding_id=?",
		                            (want_nics, TS, bid))
		                fixed.append("首启网桥 %s.nic_ids=%s" % (bname, want_nics))
		    # 其它 lan* binding 若与本仓桥成员重叠（例：roceos 另外建了 lan2），让出该口，避免两口争用
		    lan_devs = set(d for k, v in devs_of.items() if k.startswith("lan") for d in v)
		    for bid, bname, itype, nics, macs in bindings:
		        if not bname.startswith("lan") or bname in devs_of:
		            continue
		        try:
		            cur_list = json.loads(nics or "[]")
		        except ValueError:
		            cur_list = []
		        keep = [x for x in cur_list if x not in lan_devs]
		        if keep != cur_list:
		            cur.execute("update interface_bindings set physical_nics=?, physical_nic_macs=?, updated_at=? "
		                        "where id=?", (json.dumps(keep), json.dumps([mac_of(x) for x in keep]), TS, bid))
		            fixed.append("首启让出口 %s: %s→%s" % (bname, cur_list, keep))
		    try:
		        open(MARK, "w").write(TS + "\n")
		    except OSError as e:
		        log("marker 写入失败: %s" % e)

		# ── 每次：bindings 是唯一真源；按 MAC 修名，nic_ids/device 镜像它 ──
		bindings = rows("select id, binding_name, interface_type, physical_nics, physical_nic_macs "
		                "from interface_bindings order by binding_name")
		used = set()
		for bid, bname, itype, nics, macs in bindings:
		    try:
		        cur_nics = json.loads(nics or "[]")
		        cur_macs = [x.lower() for x in json.loads(macs or "[]")]
		    except ValueError:
		        cur_nics, cur_macs = [], []
		    new_nics, new_macs = [], []
		    for idx, n in enumerate(cur_nics):
		        mac = cur_macs[idx] if idx < len(cur_macs) else mac_of(n)
		        live = MAC2NAME.get(mac) if mac else None
		        if live:
		            new_nics.append(live)
		            new_macs.append(mac)
		        elif os.path.exists("/sys/class/net/" + n):
		            new_nics.append(n)
		            new_macs.append(mac_of(n))
		    if new_nics != cur_nics:
		        cur.execute("update interface_bindings set physical_nics=?, physical_nic_macs=?, updated_at=? "
		                    "where id=?", (json.dumps(new_nics), json.dumps(new_macs), TS, bid))
		        fixed.append("修名 %s: %s→%s" % (bname, cur_nics, new_nics))
		    used.update(new_nics)
		    if itype == "bridge" or bname.startswith("lan"):
		        for (cn,) in rows("select nic_ids from lan_configs where binding_id=?", (bid,)):
		            try:
		                old = json.loads(cn or "[]")
		            except ValueError:
		                old = []
		            if old != new_nics:
		                cur.execute("update lan_configs set nic_ids=?, updated_at=? where binding_id=?",
		                            (json.dumps(new_nics), TS, bid))
		                fixed.append("网桥成员镜像 %s: %s→%s" % (bname, old, new_nics))
		    else:
		        for (dev,) in rows("select device from network_interfaces where id=?", (bname,)):
		            if dev != (new_nics[0] if new_nics else dev):
		                cur.execute("update network_interfaces set device=?, updated_at=? where id=?",
		                            (new_nics[0], TS, bname))
		                fixed.append("WAN 设备镜像 %s: %s→%s" % (bname, dev, new_nics[0]))

		# 孤儿口（没被任何 binding 收录）→ 并进 LAN 桥
		orphans = [n for n in live_ifaces() if n not in used]
		if orphans:
		    for bid, bname, itype, nics, macs in bindings:
		        if not (itype == "bridge" or bname.startswith("lan")):
		            continue
		        try:
		            cur_nics = json.loads(nics or "[]")
		            cur_macs = json.loads(macs or "[]")
		        except ValueError:
		            cur_nics, cur_macs = [], []
		        new_nics = sorted(set(cur_nics) | set(orphans))
		        new_macs = cur_macs + [mac_of(n) for n in orphans if n not in cur_nics]
		        cur.execute("update interface_bindings set physical_nics=?, physical_nic_macs=?, updated_at=? "
		                    "where id=?", (json.dumps(new_nics), json.dumps(new_macs), TS, bid))
		        cur.execute("update lan_configs set nic_ids=?, updated_at=? where binding_id=?",
		                    (json.dumps(new_nics), TS, bid))
		        fixed.append("孤儿口并入 %s: %s→%s" % (bname, cur_nics, new_nics))
		        break

		if fixed:
		    con.commit()
		    log("已纠正 %d 项：%s" % (len(fixed), "; ".join(fixed)))
		else:
		    log("绑定/网桥成员一致，无需改动")
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
	# 角色映射自检：只断言【结构】（ROLE_MAP 可解析、wan*/lan* 角色在、端口不重复），
	# 不抄默认值字面量 —— 具体口径（哪个口当 WAN、两个 2.5G 是否同桥）由 tools/role-map-check.py
	# 在「构建早期」和「镜像自证」两处判。把值再抄一份到这里，改默认值时必然漏改一处
	# （2026-10-17 run #14：自证脚本里还留着旧口径的字面量 → 4.7GB 镜像全部绿、只那一行红，117 分钟白跑）。
	_ROLE_CONF="${SDCARD}/etc/lyw-rr-net-roles.conf"
	_ROLE_RAW=$(sed -n 's/^[[:space:]]*ROLE_MAP="\(.*\)"[[:space:]]*$/\1/p' "$_ROLE_CONF" 2>/dev/null | tail -1)
	if [ -z "$_ROLE_RAW" ]; then
		display_alert "角色映射缺 ROLE_MAP（期望形如 ROLE_MAP=\"wan1=eth0 lan1=eth1,eth2\"）" "$EXTENSION" "err"
		fail=1
	else
		_ROLE_NAMES=""; _ROLE_PORTS=""
		for _item in $_ROLE_RAW; do
			case "$_item" in *=*) ;; *) continue ;; esac
			_ROLE_NAMES="$_ROLE_NAMES ${_item%%=*}"
			for _p in $(printf '%s' "${_item#*=}" | tr '+' ' ' | tr ',' ' '); do
				_ROLE_PORTS="$_ROLE_PORTS $_p"
			done
		done
		_port_n=$(printf '%s\n' $_ROLE_PORTS | sed '/^$/d' | wc -l)
		_uniq_n=$(printf '%s\n' $_ROLE_PORTS | sed '/^$/d' | sort -u | wc -l)
		_ok=1
		printf '%s\n' $_ROLE_NAMES | grep -q '^wan' || _ok=0        # 必须有 WAN 角色
		printf '%s\n' $_ROLE_NAMES | grep -q '^lan' || _ok=0        # 必须有 LAN（桥）角色
		[ "$_port_n" -ge 2 ] || _ok=0                               # 至少两口
		[ "$_port_n" = "$_uniq_n" ] || _ok=0                        # 同一口不得被两个角色占用
		for _p in $_ROLE_PORTS; do case "$_p" in eth[0-9]*) ;; *) _ok=0 ;; esac; done
		[ "$_ok" = 1 ] || {
			display_alert "角色映射不可用（端口数=$_port_n 去重后=$_uniq_n，角色=[$_ROLE_NAMES ]）：缺 wan*/lan* 角色或端口重复" "$EXTENSION" "err"
			fail=1; }
	fi
	grep -q 'orphans' "${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py" || {
		display_alert "角色脚本缺孤儿口并入 LAN 桥逻辑" "$EXTENSION" "err"; fail=1; }
	grep -q 'MARK' "${SDCARD}/usr/local/sbin/lyw-rr-net-roles.py" || {
		display_alert "角色脚本缺首启 marker（会每次开机覆盖用户设置）" "$EXTENSION" "err"; fail=1; }
	[[ -f "${SDCARD}/etc/systemd/system/lyw-rr-net-roles.service" ]] || {
		display_alert "角色纠正 unit 缺失" "$EXTENSION" "err"; fail=1; }
	grep -q 'Before=roceos.service' "${SDCARD}/etc/systemd/system/lyw-rr-net-roles.service" || {
		display_alert "unit 未排在 roceos 之前（改了库也要等重启才生效）" "$EXTENSION" "err"; fail=1; }
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf /etc/systemd/system/lyw-rr-net-roles.service \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants/lyw-rr-net-roles.service"
	# 使能链接必须真的存在：判「链接」只能用 -L（目标是绝对路径，-e 会按 runner 自己的根解析成悬空 → 假红/假绿）
	# 本地 MSYS 无建链特权（ln -s 直接失败），可用 LYW_RR_SKIP_SYMLINK_ASSERT=1 跳过这一条，CI 上必须生效。
	if [ "${LYW_RR_SKIP_SYMLINK_ASSERT:-0}" != "1" ]; then
		[[ -L "${SDCARD}/etc/systemd/system/multi-user.target.wants/lyw-rr-net-roles.service" ]] || {
			display_alert "角色服务使能链接没建出来（首启不会跑 → 角色永远是 roceos 向导分配的那个）" \
				"$EXTENSION" "err"; fail=1; }
	fi

	[[ $fail == 0 ]] || exit_with_error "NanoPi R5S NIC role normalizer self-check failed"
	display_alert "NIC role normalizer verified in image" "$EXTENSION" "info"
	return 0
}
