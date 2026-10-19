# NanoPi R5S · iNextOS 适配工作流与判据

本文件回答三个问题：**为什么这么改**、**怎么构建**、**怎么判它到底成没成**。
每一条改动都配一个可复现的失败后果和一个验收命令（技能铁律：不许只有散文的修复）。

---

## 0. 一句话

R5S 在主线 Armbian 里本来就是受支持的板子（上游框架自带 `config/boards/nanopi-r5s.csc`），
所以本仓**不改内核、不加驱动补丁**；工作全在「板级配置 + iNextOS 用户态对齐 + 缺陷预防」这三层。
真正的风险不在驱动，而在**网口身份/角色**：上游 Armbian 用 `wan1/lan1/lan2` 命名，
iNextOS 的用户态只认 `eth*` + `/etc/eth_order`，两者默认组合会让口名与网页后台地址漂移。

---

## 1. 现象 → 根因 → 修复 → 验收

| # | 现象（若不修会怎样）| 根因 | 修复 | 验收（谁判）|
|---|---|---|---|---|
| 1 | 三个网口每次装机名字可能互相错位；`192.168.100.1` 落在哪个物理口不确定；网页后台可能"插了网线也进不去" | 上游 csc 用 udev 把口命名成 `wan1/lan1/lan2`，而 iNextOS 的 `fix-ifaces-name` 只按 `/etc/eth_order` 重命名 `eth*`；`istorenext-init-network` 取 `grep ^eth` 的最后一个口配 IP —— 两种命名体系不交叠，命名回落到内核探测顺序 | csc 里把 udev 命名替换为按设备路径钉死 `eth0/eth1/eth2`，并写 `/etc/eth_order` + `/root/.default-network`（`DEFAULT_INTERFACE=eth2`）| 构建期 `verify-image.sh`（三条规则 + eth_order 内容 + 默认口）+ 上板 `cat /etc/eth_order` / `ip -br addr` |
| 2 | 首启 NetworkManager 先接管网口，与 ifupdown 抢口 → 该有的地址配不上；**向导完成后再重启，NM 会把 LAN 桥端口摘出去**（本板 2026-10-17 实机：eth1 被摘 → SSH 失联） | 官方 iNextOS 根本不装 NM（EasePi R1 实测 dpkg 里没有 network-manager），框架默认 `NETWORKING_STACK=network-manager` 却会装并启用；NM 给桥端口生成 Wired connection 跑 DHCP，45s 超时（桥端口不可能拿到地址）后 `released from controller device br-lan1` | 初版只加排序 drop-in（`After=istorenext-init-network.service networking.service`）—— 首台实机证明挡不住「向导完成、roceos 运行时建桥」这个阶段；改为 `declare -g NETWORKING_STACK="none"`，镜像里不装 NM | 构建期：csc 断言 + `verify-image.sh` 反断言镜像无 NM；上板：`bridge link show` 里 LAN 口稳定保持 forwarding，重启后 `systemctl status NetworkManager` 不存在 |
| 3 | 板子能启动、网络通，但 `http://192.168.100.1/` 是空页面 | 官方 iNextOS 镜像自带 `/opt/roceos`，**上游构建框架不带**，官方靠自己的发布流水线注入 | `lyw-rr-roceos.sh`：从 lyw-OS release 取载荷（sha256 钉死）装进镜像 + 建 3 个 wants 链接 + nginx 站点/证书 + 移除 default 站点 | 构建期断言 8 个文件 + 3 链接 + nginx 站点；上板 `curl -I http://192.168.100.1/` |
| 4 | roceos 的"设置向导"把 WAN/LAN 角色按枚举顺序分反 | 角色真源是 `/opt/roceos/data/roceos.db` 三张表（`network_interfaces` / `interface_bindings` / `lan_configs`），不是 `factory-env.json`；向导按枚举顺序分配 | `lyw-rr-net-roles.sh`：开机在 roceos 之前按 `/etc/lyw-rr-net-roles.conf` 幂等纠正三张表（MAC 取实机现值，不写死）| 构建期：脚本/排序断言 + **ROLE_MAP 语义判据**（`tools/role-map-check.py`，构建前对仓库默认值、构建后对镜像里那份，同一份代码；断言「三口各一次 + 1G 当 WAN + 两个 2.5G 同桥」而非某个字面量）；上板 `sqlite3 /opt/roceos/data/roceos.db` 比对口名 |
| 5 | 2.5G 口"灯亮但拿不到 IP"、整口间歇 Link Down（用网高峰 34 次/3h） | 2026-10-13 曾判为 EEE/LPI 唤醒时序；**2026-10-17 在 T68M 主路由按日志复核推翻**：EEE 本来就是关闭态而掉线仍发生，141 次掉线每次都伴随对端 1–5 s 内重新 DHCP（对端在重启） | **不再关 EEE**：按 iNextOS 官方默认为开启，镜像里不得有 EEE 关闭件（CI 反向断言）；网卡配置只走 DT/官方基线 | 构建期反向断言（无 eee-off 件）；上板看 `ethtool --show-eee` 为官方默认即可 |
| 6 | 更新流程装固件包时把 `armbian-firmware` 连带卸载 → 网卡固件被删、装不回来 | roceos 的"安装依赖"会装发行版固件包，而 `armbian-firmware` 的 control 里 `Provides`+`Conflicts` 了其中一部分 | apt `Pin-Priority: -1` 禁止清单 + 9 个同名空壳包（不留文件）| 构建期断言 pin 文件 |
| 7 | 上游某天把网口/NVMe/LED 的内核符号改成内建或关掉，只有上板才发现 | 这些符号在上游 config 里是**默认值**而非显式声明 | `lyw-rr-kernel-config.sh` **不改值**，只逐符号断言 + Kconfig 入口自检 | 构建期（构建失败早于镜像产出）+ `verify-image.sh` 断言镜像内 config |
| 8 | 风扇不转 / 不调速（温度再高也不变） | 主线 `rk3568-nanopi-r5s.dtb` 没有 fan 节点，pwm0（fdd70000）是 `disabled`，16 个 pwm 控制器全关 → pwm-fan 无从绑定 | `config/overlays/rockchip-rk3568-nanopi-r5s-fan.dtso`：`&pwm0 { status = "okay" }` + `fan: pwm-fan`（`pwms = <&pwm0 0 50000 0>`、`fan-supply = <&vcc5v0_sys>`、32 档 cooling-levels）；`extensions/lyw-rr-fan.sh` 装 `r5s-fan.service`，按 18C→55C 线性写 `cooling_device/cur_state` | 构建期断言 overlay 进 boot + armbianEnv overlays + 脚本/unit/enable；上板 `cat /sys/class/thermal/cooling_device*/type` 有 `pwm-fan`、`/sys/kernel/debug/pwm` 里 pwm-0 为 pwm-fan requested/enabled |

---

## 2. 构建

```bash
# CI：Actions → "Build iNextOS for NanoPi R5S" → Run workflow → profile
#   adapted  = 本仓适配层（交付镜像）
#   official = 纯官方基线（上游 csc + istorenext，一行不改；权威对照物）
```

本地复现（需 Linux + Docker；CI 用 ubuntu-24.04）：

```bash
git clone https://github.com/jjm2473/armbian-easepi build    # 分支 easepi-v26.02
git clone https://github.com/linyueweia/lyw-rr rr
cp rr/config/boards/nanopi-r5s.csc           build/config/boards/
mkdir -p build/userpatches/extensions build/userpatches/overlay
cp rr/extensions/*.sh                        build/userpatches/extensions/
chmod +x build/userpatches/extensions/*.sh
curl -fL -o build/userpatches/overlay/roceos-payload.tar.gz \
  https://github.com/linyueweia/lyw-OS/releases/download/roceos-payload-v1/roceos-payload.tar.gz
echo "6b819584a1b1701163f8983bd59a31821643f64dd65c76ba8f500ef54c5e8bb5  build/userpatches/overlay/roceos-payload.tar.gz" | sha256sum -c -

cd build && ./compile.sh build \
  BOARD=nanopi-r5s BRANCH=current RELEASE=trixie \
  ENABLE_EXTENSIONS="istorenext,lyw-rr-roceos,lyw-rr-kernel-config,lyw-rr-net-roles" \
  BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=no \
  COMPRESS_OUTPUTIMAGE="sha,img,xz" SHARE_LOG=yes EXPERT=yes
```

## 3. 烧写

```bash
# 目标介质：microSD（或 eMMC；R5S 的 eMMC 容量小，建议先用 SD 验证）
xz -dc output/images/*.img.xz | sudo dd of=/dev/sdX bs=4M oflag=direct status=progress
sudo sync
# 读回校验（技能铁律：以读回为准，不看 dd 退出码）
sudo dd if=/dev/sdX bs=4M count=$(( $(stat -c%s output/images/*.img) / 4194304 + 1 )) 2>/dev/null \
  | head -c $(stat -c%s output/images/*.img) | sha256sum   # 与 .sha 文件比对
```

串口：**ttyS2 @ 1500000**（USB-TTL 接板上的 debug UART），上电前先开监听。

## 4. 上板验收（判据即命令）

见 `README.md` 的「上板」一节（六组命令）。三句话版：

1. `cat /etc/eth_order` + `ip -br addr` → 三口身份与后台地址（eth2 = 192.168.100.1）对；
2. 三个口各插一次线 → `ethtool ethN` 的 `Speed` 分别 1000 / 2500 / 2500，`Link detected: yes`；
3. `curl -I http://192.168.100.1/` 有响应 + `systemctl is-active roceos roceos-ai nginx` 全 active。

## 5. 一板一轮的纪律（技能铁律，别一次改多处）

- 上板一轮**只验证一类改动**：先验「启动 + 三口身份/地址」，再验「EEE 为官方默认（不做关闭）」，最后验「角色/后台功能」。
  混在一轮里出问题时无法归因。
- 任何 DTB/板级配置改动都必须带**同版本的回归断言**（本仓断言写在 `tools/verify-image.sh`，改动同 PR 提交）。
- 未上板的结论一律标注"未验证"，并在上板后把实测输出补进本文件的判据表。
