# lyw-rr —— iNextOS 板级适配（FriendlyElec NanoPi R5S / Rockchip RK3568）

本仓不是独立构建系统，而是**板级适配层**：CI 把本仓的
`config/boards/nanopi-r5s.csc` + `extensions/*.sh` 注入上游 iNextOS 构建框架
[`jjm2473/armbian-easepi`](https://github.com/jjm2473/armbian-easepi)（分支 `easepi-v26.02`），
再跑官方 `./compile.sh` 出镜像。与本账号既有三仓同构：`lyw-kk`(KICKPI K1)、`lyw-OS`/`lyw-kf`(LYT T68M)、`lyw-ki`(iStoreOS)。

## 目标板

| 项 | 值 |
|---|---|
| 板 | FriendlyElec NanoPi R5S（4GB LPDDR4X + 8GB eMMC，M.2 M-Key）|
| SoC / 内核 | RK3568 / **6.18 current**（`BRANCH=current`，rockchip64 家族 = 6.18）|
| 系统 | iNextOSA（`istorenext` 扩展：VENDOR=iNextOSA、HOST=iNextOS、12G rootfs、4G swap、roceos 网页后台）|
| 网口 | **1× 千兆（板载 GMAC0）+ 2× 2.5GbE（PCIe 上的 RTL8125B）** |
| 存储 | eMMC + microSD + M.2 NVMe（挂在 `pcie2x1`，domain 2）|
| 串口 | `ttyS2`（current 分支默认；**不是** vendor 分支的 ttyFIQ0）|

## 三个网口的身份（证据链，不是猜）

| 口名 | 设备路径 | 物理口 | 角色（对齐上游口径）|
|---|---|---|---|
| `eth0` | `fe2a0000.ethernet` | WAN 丝印（1G） | **WAN**（默认） |
| `eth1` | `0000:01:00.0` | PCIe domain 0（`pcie3x2`）上的 2.5G | LAN1 | **LAN 桥成员**（默认） |
| `eth2` | `0001:11:00.0` | PCIe domain 1（`pcie3x1`）上的 2.5G | LAN2 → **192.168.100.1**（网页后台） | **LAN 桥成员**（默认，192.168.100.1 在桥上） |

证据：
1. 主线 `rk3568-nanopi-r5s.dts`：`aliases { ethernet0 = &gmac0; }`、`&pcie3x2/&pcie3x1/&pcie2x1` 全 `okay`、
   LED 节点名就是 `lan1/lan2/wan`（2026-10-16 抄录 `torvalds/linux`）。
2. 上游 `nanopi-r5s.csc` 原文的 udev 规则（维护者实机口径）：`fe2a0000.ethernet→wan1`、
   `0000:01:00.0→lan1`、`0001:11:00.0→lan2`，并写 `/root/.default-network=DEFAULT_INTERFACE=lan2`。
3. iNextOS 排序规则（H88K 镜像内 `gen-eth-order` 脚本注释原文）：
   `SoC platform MACs first, then PCIe/USB NICs sorted by device path`。
4. iNextOS 的两件套代码原文（`packages/bsp/istorenext/fix-ifaces-name`、
   `istorenext-init-network`）：前者读 `/etc/eth_order`（逗号分隔设备名，按序重命名 eth0..ethN），
   后者读 `/root/.default-network`，否则取编号最大的 `eth*`。

## 我们加了什么、为什么（哪些是官方自带）

| 层 | 归属 | 说明 |
|---|---|---|
| board csc（u-boot v2024.04 / DDR 1560_v1.21 / DTB / overlay / UMS-RockUSB 配置）| **官方**，照用 | 本仓 csc = 上游同名文件 fork，仅替换网口命名一节 |
| `istorenext` 扩展（整套 iNextOS 包、12G rootfs、4G swap、网络链两件套）| **官方**，照用 | `ENABLE_EXTENSIONS` 里第一项 |
| 内核配置（`STMMAC_ETH=m`、`R8169=m`、`BLK_DEV_NVME=y`、`LEDS_GPIO=y`…）| **官方值**，本仓只断言 | `lyw-rr-kernel-config.sh` 不改值：上游一旦改掉这些，构建立刻失败而不是上板才发现 |
| roceos 网页后台（`/opt/roceos` + 3 个服务 + nginx 站点/证书）| 官方镜像**有**、框架**没有** → 本仓注入 | `lyw-rr-roceos.sh`；载荷取自 lyw-OS release，sha256 钉死 |
| 网口命名钉定（udev 三规则 + `/etc/eth_order` + `.default-network`）| **本仓适配**（替换上游 wan1/lan1/lan2）| 上游命名与 iNextOS 的 `eth*` 网络链不兼容：口名/后台地址会随内核探测顺序漂移 |
| EEE/LPI（千兆口）| **DT 侧关 1000T**（2026-10-30 定案，与 K1/T68M 同写法）| 板级 DTS（`patch/kernel/archive/rockchip64-6.18/dt/rk3568-nanopi-r5s.dts`）在 `&mdio0` 的 `ethernet-phy@1` 节点写 `eee-broken-1000t`：只关 1G 的 EEE、100M 不动，不需要任何用户态脚本。**历史**：2026-10-13 曾做五层用户态关闭 → 10-17 按 T68M 主路由日志推翻（当时判为"对端重启导致的掉线"）→ 10-28 又按实机 LPI 计数翻回（`Tx LPI` 活跃、`phy_eee_wakeup_error_n` 增长、carrier 仍在但整口收不到包、拔插网线即恢复 = PHY 末端唤醒竞争）⇒ 终案＝DT 属性，不是脚本。两个 2.5G（RTL8125）走 PCIe 网卡驱动、不过 phylib，DT 属性对它们无效，不在本条范围 |
| roceos 角色归一（`roceos.db` 三张表）| **本仓适配** | 默认 `ROLE_MAP="wan1=eth0 lan1=eth1,eth2"`（1G 当 WAN，两个 2.5G 同属 LAN 桥）；**只在首启套用一次**，之后网页后台改的角色不会被覆盖；脚本只修名字漂移 + 把孤儿口并入 LAN 桥 |
| 网络栈（`NETWORKING_STACK="none"`）| **官方值**（对齐官方 iNextOS / EasePi R1）| 官方 R1 实测 dpkg 里没有 network-manager；装了 NM 会把 LAN 桥端口当独立网卡跑 DHCP，45s 超时后把 ethN 摘出 br-lan1（本板 2026-10-17 实机：eth1 被摘 → SSH 失联）|
| 发布件口径（`BUILD_MINIMAL=yes` / `RELEASE=trixie` / `FULL_DESKTOP=no` / hold dtb）| **对齐官方**（2026-10-30 定案）| 官方发布件名 `iNextOSA_26.2.1_Nanopi-r5s_trixie_current_6.18.10_minimal.img`（`_minimal` 后缀 = 框架只在 `BUILD_MINIMAL=yes` 时加）。**本机那份官方镜像是未下载完的空壳**，所以包数口径取自同族官方件实测：官方 minimal 718 包 / 我们 `BUILD_MINIMAL=no` 实测 958 包，差的正是整份 `packages.additional`（含 `avahi-autoipd`/`unattended-upgrades`）。`RELEASE` 框架没有板级默认必须钉死；hold dtb 防 `armbian-upgrade` 换掉本板 DTB（官方 R1/R2 同款做法）|
| smartmontools | **对齐官方 R1**：包在、但不启用 | 官方 R1 的 unit 存在，但 `multi-user.target.wants` 里没有链接；我们的镜像被 Debian preset 自动 enable → 每次开机 `smartd` 退 17「No devices to monitor」长期 failed。csc 只删启用链接、不卸载包（卸载才是自造差异）|
| roceos-ai 语义 | **对齐官方 Easepi-r2**：无模型 exit 3、不重启、不 Wants 后端 | 载荷 `roceos-ai.service` 带 `RestartPreventExitStatus=3`、`server.py` 无模型时 `sys.exit(3)`；`Wants=roceos.service` 已移除（留着会让 OTA 停服换二进制期间提前拉起旧后端 → 升级假成功）。CI 三条断言 |
| 时钟（`fake-hwclock-load` mask）| **与官方有意差异**（有实机因果链）| 官方 R1 是 enabled；但 `fake-hwclock.data` 是构建日期，开机会盖掉 RTC → roceos 用本机时钟签 JWT，放置数周再开机就「登录一下即退出」（H88K 实机同源机制）。本仓 mask 该 unit + `.data` 写构建时刻 + 自带 timesyncd 就启用。**这是唯一一项与官方形态不同的地方**，可一条命令回滚（`systemctl unmask fake-hwclock-load`）|
| 风扇温控（pwm-fan overlay + 18C→45C 曲线）| **本仓适配**（主线 DTB 没有风扇支持）| `config/overlays/rockchip-rk3568-nanopi-r5s-fan.dtso` 打开 pwm0 + 挂 pwm-fan；`extensions/lyw-rr-fan.sh` 装 `r5s-fan.service`，5s 采样、32 档，≤18C 停、45C 满速。**注意：overlay 必须同时登记进框架 overlay 的 Makefile**（`tools/overlay-makefile-patch.py`）—— 框架是显式枚举 dtbo 的，只拷 .dtso 不会编译，风扇就没有 cooling device |

## 关机断电（与官方口径对照）

`poweroff` 后风扇仍转 / 网口灯常亮，在 iNextOS 线上是**官方原样**，且分两种 PMIC：

- **RK809/RK817**（K1 / T68M / 本板）：vendor 6.1 的 `drivers/mfd/rk808.c:1533` **仅当** DTS 写
  `rockchip,system-power-controller` 才会注册 `rk808_pm_power_off`（写 SLPPIN_DN_FUN +
  `pinctrl_select_state("pmic-power-off")`），这才是真正关 PMIC 主输出。**本板走主线 6.18**：
  `drivers/mfd/rk8xx-core.c:875` 两个名字都认，且 `rk3568-nanopi-r5s.dtsi:233` 自带
  `system-power-controller;` ⇒ 本板有 PMIC 断电路径，**不需要改**。
- **RK806**（H88K / Easepi R2）：`rk806-core.c:630` 只 lookup `pmic-power-off` 却从不 select，
  全树没有 rk806 的 `pm_power_off` 注册 ⇒ 只能走 PSCI/ATF，属性无效。

官方对照：`rk3568-easepi-r1.dts` / `rk3568-roc-k40pro.dtsi` **没有** system-power-controller
（官方 R1 只走 PSCI），`rk3588-easepi-r2.dts` 同样没有。**所以我们不改，保持与官方一致**。

若本板实测关机后仍不断电（判据：`journalctl -b -1 --no-pager | tail -5` 末行是
`reboot: Power down` 而风扇仍转），那就不是驱动问题，而是 ATF/硬件常供（5V 直通）——
先量 `vcc5v0_sys`/3.3V 是否还在，再谈方案；**不要**去给 DTS 加 pmic 关机属性（主线正常路径已经在了）。

## 两档构建 profile

| profile | 内容 | 用途 |
|---|---|---|
| `adapted`（默认）| 上游框架 + 覆盖 csc + 4 个本仓扩展 + roceos 载荷 | 交付给用户的镜像 |
| `official` | **一行都不改**：上游自带 `nanopi-r5s.csc` + 仅 `istorenext` | 权威对照基线（证明官方组合在本板能否构建、结构如何）|

触发：Actions → *Build iNextOS for NanoPi R5S* → Run workflow → 选 profile。

本地构建（参数必须与 CI 完全一致，否则产物不是同一件东西；`.csc` 注释里有同一份）：

```bash
./compile.sh build BOARD=nanopi-r5s BRANCH=current RELEASE=trixie \
  ENABLE_EXTENSIONS="istorenext,lyw-rr-roceos,lyw-rr-kernel-config,lyw-rr-net-roles,lyw-rr-fan,lyw-rr-clock" \
  BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no EXPERT=yes
```

`BUILD_MINIMAL=yes` 是官方口径：官方 R5S 参照件 `iNextOSA_26.2.1_Nanopi-r5s_trixie_current_6.18.10_minimal.img`
就带 `_minimal` 后缀（框架只在 yes 时加）、718 包；传 `no` 实测 958 包，多出的
`avahi-autoipd`（DHCP 失败塞 169.254）与 `unattended-upgrades`（后台升级重启网络）正是
「网口灯亮、下级设备拿不到 IP / 用几小时就掉」的常见来源。

## 包集合口径（与官方 minimal 逐包对齐，2026-10-31 定案）

**结论**：本仓镜像的 dpkg 包集合 = 框架官方 minimal 口径；本仓的扩展**不额外加任何包**。

判据单点：`tools/packages-parity-check.py`（`--selftest` 跑 3 正例 + 6 负例 + 1 聚合口径自测）。

- 旧判据把 `packages.additional` 整份当黑名单，只要成员出现在镜像里就判红 →
  **`BUILD_MINIMAL=yes` 明明生效，仍然打出 15 条红**（lyw-rr run #39 / lyw-hh run #26），
  整轮 2 小时白跑。错的不是包，是判据。
- `packages.additional` 的成员有四个「官方 minimal 镜像里同样存在」的合法来源：
  1. 框架自己的 rootfs 清单（**三层聚合**：`config/cli/<rel>/main/packages` +
     `config/optional/_any_board/_config/…` + `config/optional/architectures/<arch>/_config/…`）
     —— `sudo` `wget` `bash-completion` `htop` `wireless-regdb`，**以及只写在
     arm64 optional 层的 `gpiod`**（只看 `config/cli/…` 会把它误判成「多出来的包」）；
  2. `extensions/istorenext.sh` 的 `add_packages_to_image` —— `git` `unzip` `ntfs-3g`
     `nfs-common` `smartmontools`；
  3. 上面两者的 Depends/Recommends 传递依赖 —— `keyboard-configuration ← console-setup`、
     `libpam-systemd ← systemd-sysv ← init`、`iptables ← wireguard-tools`、
     `apt-utils ← debconf ← iproute2`；
  4. apt 的 `Auto-Installed` 记录（镜像里 `/var/lib/apt/extended_states` 在时）。
- 现判据 = **来源减法**：只有「出现 ∩ 不属于以上四类」的成员才判红 ——
  `BUILD_MINIMAL=no`（整份 additional 进镜像）或有人手工装 additional 包时立刻红。
  实测：用真实镜像同口径数据跑，上述 15 项全部有来源、判据绿；再造「整份装进来」负例，判据红。
- Flask 栈**保留**构建期 `apt-get install python3-flask …`（≈ 与官方同口径）：
  2026-10-31 取官方 **A2 2.9.1** 镜像（sha256 `a8cdf1d2…`，716 包）实测，
  官方里面确实装着 `python3-flask/-werkzeug/-jinja2/-itsdangerous/-markupsafe/-blinker`
  这 6 个包 ⇒ 我们原先的写法是对的，不要为了"少几个包"去删它；
  载荷里的 `dist-packages` 只作 apt 无 DNS 时的兜底。
- 与官方 csc 的对齐（2026-10-31）：`FULL_DESKTOP`/`BOOT_LOGO` 恢复官方同值
  （前者是框架废弃变量，`lib/` 全仓无读取者；后者只在 `BUILD_DESKTOP=yes` 时生效，
  见 `distro-agnostic.sh:591`），桌面仍由 CI 的 `BUILD_DESKTOP=no` 关掉 —— 产物不变，
  csc 不再自造差异。

## 判据

### 构建期（CI 自动，失败即不出镜像）

- **注入前**：csc 里三条 udev 规则 + `DEFAULT_INTERFACE=eth2` 必须在；上游 `wan1/lan1/lan2` 命名必须已不存在；
  四个扩展的钩子/载荷指纹必须在。
- **roceos 载荷**：sha256 = `6b819584…8bb5` 校验。
- **角色映射（构建前，秒级）**：`tools/role-map-check.py --src` 对扩展将要写进镜像的默认 `ROLE_MAP` 判口径
  （三口各一次 / 1G 当 WAN / 两个 2.5G 同桥），并拒绝「默认值被抄到别处第二份」；判据脚本自带 15 例负例自测
  （`tools/tests/role-map-check-test.sh`）。构建后再用同一份判据对镜像里那份 `ROLE_MAP` 判一遍。
- **构建后**：`tools/verify-image.sh <img> <profile>` 逐项断言（本仓"判据即代码"），要点：
  - 产物 `.sha` 必须在且与实算 sha256 一致（写卡前靠它跟 CI 日志对账）；
  - **官方发布件口径**：镜像文件名必须含 `_minimal`（=`BUILD_MINIMAL=yes` 真生效）、
    `packages.additional` 逐包核对（判据单点 `tools/packages-parity-check.py`，来源减法，
    见上面「包集合口径」一节 —— 不是「出现即红」）、`smartmontools` 包在但不启用（官方 R1 同款）；
    根文件系统按 `-o ro` 挂载，保证盘上镜像与上传的 `.xz` 同源；
  - bootfs `armbianEnv.txt` 指向 `rk3568-nanopi-r5s.dtb`，DTB 的 `model`/`compatible` 是 R5S，
    `ethernet@fe2a0000` + 三个 PCIe 控制器都 `okay`；
  - 内核 config：`STMMAC_ETH=m`、`R8169=m`、`BLK_DEV_NVME=y`、`LEDS_GPIO=y`、`PCIE_DW_PLAT_HOST=y`、`PCI_MSI=y`；
  - rootfs 真有 `r8169.ko` / `dwmac-rk.ko` / `stmmac.ko`，且 `modules.dep` 收录 `r8169`（自动加载）；
  - iNextOS 两件套在、`fix-ifaces-name.service` / `istorenext-init-network.service` 已 enable；
  -（adapted）三条 udev 规则、`/etc/eth_order` 精确内容、`/root/.default-network`、NM 排序 drop-in、
    roceos 全套 + 3 个 wants 链接 + nginx 站点、DTB 含 `eee-broken-1000t`（千兆口 1G EEE 关）
    + 反断言"无任何用户态 EEE 关闭件"、ethtool（官方基线自带）、角色归一三件套；
  - **反断言**：不得出现 `wan1/lan1/lan2` 命名、不得启用 `serial-getty@ttyFIQ0`、nginx `default` 站点必须已移除。

### 上板（必须实机，未做就是未验证）

```bash
# 1) 三口身份与角色
cat /etc/eth_order                       # 期望 fe2a0000.ethernet,0000:01:00.0,0001:11:00.0
ip -br addr                              # 期望 192.168.100.1 落在 br-lan1（成员 eth1+eth2）；eth0 空（等 WAN 插线）
for i in /sys/class/net/eth*; do echo "$i $(cat $i/address) speed=$(cat $i/speed 2>/dev/null)"; done

# 2) 三口逐一插线（每个口都插一次，确认 link + 速率）
ethtool eth0 | grep -E 'Speed|Link detected'   # 期望 1000Mb/s（千兆口）
ethtool eth1 | grep -E 'Speed|Link detected'   # 期望 2500Mb/s
ethtool eth2 | grep -E 'Speed|Link detected'   # 期望 2500Mb/s
ethtool -p eth2 5                              # 认物理口：闪灯

# 3) EEE：千兆口(eth0) 只关 1000T —— Advertised 里不得再有 1000baseT/Full，LPI 计数不得增长
for i in eth0 eth1 eth2; do echo "== $i"; ethtool --show-eee $i | grep -iE 'EEE status|Advertised'; done
ethtool -S eth0 | grep -i lpi   # 有流量跑 75 秒后仍不增长才算生效（status 显示 active 不是判据）

# 4) 驱动与自动加载
lsmod | grep -E 'r8169|dwmac|stmmac'
lspci -nn | grep -i ethernet                   # 期望两块 10ec:8125

# 5) 网页后台
curl -sI http://192.168.100.1/ | head -1       # 期望 200/301（nginx → roceos）
systemctl is-active roceos roceos-ai nginx     # 期望 active

# 6) 风扇温控（pwm-fan overlay + 用户态曲线）
ls /sys/class/thermal/cooling_device*/type | xargs grep -l pwm-fan   # 期望命中 type=pwm-fan
cat /sys/class/thermal/cooling_device*/cur_state                     # 随温度变化的档位
systemctl is-active r5s-fan                                          # 期望 active
cat /sys/kernel/debug/pwm                                            # 期望 pwm-0 (pwm-fan) requested/enabled

# 7) 网卡 MAC 稳定性（上游遗留项，见下）
ip link show eth0 | grep ether                 # 重启两次比对，若变化见"遗留"
```

## 遗留 / 未验证（如实记录，别当已解决）

1. **本板从未上机**：本仓所有结论来自「上游源码 + 官方配置 + 主线 DTS」的离线取证，**没有 R5S 实机**。
   上板前不得声称"已验证"；上面第 2 节的判据是唯一裁决。
2. **千兆口 eth0 的 MAC 每次开机可能变化**：u-boot v2024.04 的 `nanopi-r5s-rk3568_defconfig` 无
   EFUSE/MAC 相关符号，主线 DTS 也没有 `mac-address`/`nvmem` 来源 → 内核给随机 MAC
   （两个 2.5G 口是 RTL8125 芯片自带 MAC，稳定）。这是上游行为、非本仓引入。
   上板确认后可选修法（择一，未决）：`systemd .link` 的 `MACAddressPolicy=persistent`，或按 SoC
   serial 派生固定 MAC。**在实机确认前不改**（按技能铁律：不要凭空发明机制）。
3. **千兆口 1G EEE：DT 属性已改成终案，但本板未上板实测**：`eee-broken-1000t` 是 iNextOS 线
   ／K1／T68M 实机验证过的写法（phy-core.c 读属性 → 重协商剔除 1000T），本仓已把它落到
   `patch/kernel/archive/rockchip64-6.18/dt/rk3568-nanopi-r5s.dts`，并有两道判据（源码节点内、
   镜像 DTB 字节里必须各有这个属性）。但**本仓没有 R5S 实机** ⇒ 上板判据见上面第 3 条命令
   （`ethtool --show-eee eth0` 的 Advertised 里不得有 `1000baseT/Full`、`ethtool -S eth0 | grep lpi`
   在有流量时 75 秒不增长）。
   上板按判据第 3 节实测确认；若实测无问题也不会撤（成本为零，收益是防复发）。
4. **未做**：NVMe 上盘/吞吐实测、LED 四灯行为、USB3、风扇/温度、roceos 各功能页（SMB/Docker/相册 AI）、
   在线内核更新后的自愈路径压测（current 分支驱动均在树内，风险低于 K1 的外挂 PHY 驱动）。
5. **参照镜像缺席**：用户提供的 `iNextOSA_26.2.1_Nanopi-r5s_trixie_current_6.18.10_minimal.img`
   是百度网盘**未下载完**的文件（3.15 GiB 几乎全零，只有 1840 MiB 处一个 4 MiB 的 ELF 碎片，无 MBR 签名）。
   按技能铁律，第三方移植件也只能当数据点、不能当基线 —— 真正的基线是本仓 workflow 的
   `profile=official`（上游框架自己出的镜像）。

## 目录

```
config/boards/nanopi-r5s.csc     # 上游 csc 的 fork，仅替换网口命名一节（改动处标 ##iNextOS）
patch/kernel/archive/rockchip64-6.18/dt/rk3568-nanopi-r5s.dts
                                 # 板级 DTS fork（唯一改动 = 千兆 PHY 节点 eee-broken-1000t）
tools/dts-lint.py                # 板级 DTS 语法门（构建前秒级，覆盖 prop-order / CPP 移位运算符）
extensions/lyw-rr-roceos.sh      # 注入 roceos 网页后台（官方镜像有、框架没有）
extensions/lyw-rr-kernel-config.sh  # 断言三口/NVMe/LED 的内核符号（不改值）
（EEE 关闭扩展已移除：1G EEE 由板级 DTS 的 `eee-broken-1000t` 关掉，不再需要用户态件）
extensions/lyw-rr-net-roles.sh   # roceos 角色表归一（映射在 /etc/lyw-rr-net-roles.conf）
extensions/lyw-rr-fan.sh         # 板载风扇温控（pwm-fan，18C 起转 / 45C 满速）
extensions/lyw-rr-clock.sh       # mask fake-hwclock-load（后台登录即退的根因，与 lyw-hh 同一套）
config/overlays/rockchip-rk3568-nanopi-r5s-fan.dtso  # 打开 pwm0 + 挂 pwm-fan 节点
tools/verify-image.sh            # 镜像自证（判据即代码；adapted/official 两档）
tools/role-map-check.py          # ROLE_MAP 口径判据（构建早期对仓库默认值 + 构建后对镜像里那份，同一份代码）
tools/overlay-makefile-patch.py  # 把 config/overlays/*.dtso 登记进框架 overlay 的 Makefile（只拷 .dtso 不登记＝不编译）
tools/tests/                     # 判据脚本自测（布局探测 / role-map / 风扇自检 / overlay 登记），构建前必跑
.github/workflows/build.yml      # 上游指纹跟踪 + 双 profile 构建 + 自证 + 产物
docs/R5S-适配工作流与判据.md      # 现象→根因→修复→验收 表 + 上板流程
```

## 与上游的关系（维护约定）

- **基线**：`jjm2473/armbian-easepi @ easepi-v26.02`（`last-upstream-sha` 记录指纹，每日 03:00 检查）。
- csc 是上游同名文件的 fork：上游改了 u-boot/DTB/overlay 等段落时，需要把变更合并进来
  （仓库内改动一律带 `##iNextOS` 标注，便于 diff）。
- 内核补丁目录：**本仓不需要**（R5S 主线支持完整，无外挂驱动；与 K1 的 Maxio PHY 情形不同）。
