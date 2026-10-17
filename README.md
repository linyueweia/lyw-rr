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
| `eth0` | `fe2a0000.ethernet` | 板载千兆 GMAC0 | WAN |
| `eth1` | `0000:01:00.0` | PCIe domain 0（`pcie3x2`）上的 2.5G | LAN1 |
| `eth2` | `0001:11:00.0` | PCIe domain 1（`pcie3x1`）上的 2.5G | LAN2 → **192.168.100.1**（网页后台）|

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
| 网口命名钉定（udev 三规则 + `/etc/eth_order` + `.default-network` + NM 排序 drop-in）| **本仓适配**（替换上游 wan1/lan1/lan2）| 上游命名与 iNextOS 的 `eth*` 网络链不兼容：口名/后台地址会随内核探测顺序漂移 |
| EEE/LPI | **不关闭**（官方默认开启）| 2026-10-13 曾按"同族三线"判为 EEE 唤醒时序问题并做了五层关闭；2026-10-17 在 T68M 主路由按日志复核推翻（EEE 本是关闭态而掉线仍发生，141 次掉线均伴随对端重启）→ 本仓改为与官方一致：镜像里不得有 EEE 关闭件，CI 反向断言 |
| roceos 角色归一（`roceos.db` 三张表）| **本仓适配** | 配置在 `/etc/lyw-rr-net-roles.conf`，想换角色只改这一个文件 |

## 两档构建 profile

| profile | 内容 | 用途 |
|---|---|---|
| `adapted`（默认）| 上游框架 + 覆盖 csc + 4 个本仓扩展 + roceos 载荷 | 交付给用户的镜像 |
| `official` | **一行都不改**：上游自带 `nanopi-r5s.csc` + 仅 `istorenext` | 权威对照基线（证明官方组合在本板能否构建、结构如何）|

触发：Actions → *Build iNextOS for NanoPi R5S* → Run workflow → 选 profile。

## 判据

### 构建期（CI 自动，失败即不出镜像）

- **注入前**：csc 里三条 udev 规则 + `DEFAULT_INTERFACE=eth2` 必须在；上游 `wan1/lan1/lan2` 命名必须已不存在；
  四个扩展的钩子/载荷指纹必须在。
- **roceos 载荷**：sha256 = `6b819584…8bb5` 校验。
- **构建后**：`tools/verify-image.sh <img> <profile>` 逐项断言（本仓"判据即代码"），要点：
  - bootfs `armbianEnv.txt` 指向 `rk3568-nanopi-r5s.dtb`，DTB 的 `model`/`compatible` 是 R5S，
    `ethernet@fe2a0000` + 三个 PCIe 控制器都 `okay`；
  - 内核 config：`STMMAC_ETH=m`、`R8169=m`、`BLK_DEV_NVME=y`、`LEDS_GPIO=y`、`PCIE_DW_PLAT_HOST=y`、`PCI_MSI=y`；
  - rootfs 真有 `r8169.ko` / `dwmac-rockchip.ko` / `stmmac.ko`，且 `modules.dep` 收录 `r8169`（自动加载）；
  - iNextOS 两件套在、`fix-ifaces-name.service` / `istorenext-init-network.service` 已 enable；
  -（adapted）三条 udev 规则、`/etc/eth_order` 精确内容、`/root/.default-network`、NM 排序 drop-in、
    roceos 全套 + 3 个 wants 链接 + nginx 站点、反断言"无任何 EEE 关闭件"、ethtool（官方基线自带）、角色归一三件套；
  - **反断言**：不得出现 `wan1/lan1/lan2` 命名、不得启用 `serial-getty@ttyFIQ0`、nginx `default` 站点必须已移除。

### 上板（必须实机，未做就是未验证）

```bash
# 1) 三口身份与角色
cat /etc/eth_order                       # 期望 fe2a0000.ethernet,0000:01:00.0,0001:11:00.0
ip -br addr                              # 期望 192.168.100.1 落在 eth2；eth0 空（等 WAN 插线）
for i in /sys/class/net/eth*; do echo "$i $(cat $i/address) speed=$(cat $i/speed 2>/dev/null)"; done

# 2) 三口逐一插线（每个口都插一次，确认 link + 速率）
ethtool eth0 | grep -E 'Speed|Link detected'   # 期望 1000Mb/s（千兆口）
ethtool eth1 | grep -E 'Speed|Link detected'   # 期望 2500Mb/s
ethtool eth2 | grep -E 'Speed|Link detected'   # 期望 2500Mb/s
ethtool -p eth2 5                              # 认物理口：闪灯

# 3) EEE 保持官方默认（本仓不再关闭；这里只看状态，不改）
for i in eth0 eth1 eth2; do echo "== $i"; ethtool --show-eee $i | grep -i 'EEE status'; done

# 4) 驱动与自动加载
lsmod | grep -E 'r8169|dwmac|stmmac'
lspci -nn | grep -i ethernet                   # 期望两块 10ec:8125

# 5) 网页后台
curl -sI http://192.168.100.1/ | head -1       # 期望 200/301（nginx → roceos）
systemctl is-active roceos roceos-ai nginx     # 期望 active

# 6) 网卡 MAC 稳定性（上游遗留项，见下）
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
3. **EEE 不再关闭**：本板从未实测复现过 EEE 相关掉线；2026-10-17 复核后按官方默认保持开启，镜像里不装任何 EEE 关闭件（CI 反向断言）。
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
extensions/lyw-rr-roceos.sh      # 注入 roceos 网页后台（官方镜像有、框架没有）
extensions/lyw-rr-kernel-config.sh  # 断言三口/NVMe/LED 的内核符号（不改值）
（EEE 关闭扩展已移除：EEE 按官方默认保持开启）
extensions/lyw-rr-net-roles.sh   # roceos 角色表归一（映射在 /etc/lyw-rr-net-roles.conf）
tools/verify-image.sh            # 镜像自证（判据即代码；adapted/official 两档）
.github/workflows/build.yml      # 上游指纹跟踪 + 双 profile 构建 + 自证 + 产物
docs/R5S-适配工作流与判据.md      # 现象→根因→修复→验收 表 + 上板流程
```

## 与上游的关系（维护约定）

- **基线**：`jjm2473/armbian-easepi @ easepi-v26.02`（`last-upstream-sha` 记录指纹，每日 03:00 检查）。
- csc 是上游同名文件的 fork：上游改了 u-boot/DTB/overlay 等段落时，需要把变更合并进来
  （仓库内改动一律带 `##iNextOS` 标注，便于 diff）。
- 内核补丁目录：**本仓不需要**（R5S 主线支持完整，无外挂驱动；与 K1 的 Maxio PHY 情形不同）。
