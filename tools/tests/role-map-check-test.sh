#!/usr/bin/env bash
# role-map-check.py 的负例自测（秒级，构建前必跑）
#
# 为什么要有：这组用例全部来自真实事故形态 —— 断言与“默认值”脱节时，
# 一次 117 分钟的全量构建只换来一行 ✗（2026-10-17 lyw-rr run #14）。
# 判据脚本本身写错等于把“必红”搬进 CI，所以它自己也要有负例。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHK="$HERE/../role-map-check.py"

# 解释器：CI(Linux) 有 python3；Windows 开发机上 python3 往往只是应用商店占位符（一跑就报
# "Python was not found"），所以先做可用性探测再决定用哪个 —— 否则本地自测会假红。
PY=""
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "!! 找不到可用的 python（需要 python3 或 python）"; exit 1; }
# 原生 python 读不了 MSYS 路径（/c/... → C:\c\...）：传参前转 Windows 路径（Linux 上无 cygpath，原样）
W() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
CHKW=$(W "$CHK")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; failed=0

run_case() {  # $1=期望rc  $2=标签  $3=用例名  $4=夹具文件  $5=模式(conf|src)
	if "$PY" "$CHKW" "--$5" "$(W "$4")" > "$TMP/out" 2>&1; then rc=0; else rc=1; fi
	if [ "$rc" = "$1" ]; then
		echo "  OK   [$2] $3（rc=$rc）"; pass=$((pass + 1))
	else
		echo "  !!   [$2] $3 期望 rc=$1 实际 rc=$rc"; sed 's/^/       /' "$TMP/out"; failed=$((failed + 1))
	fi
}

# conf 夹具：整份文件内容（可多行）
conf_case() {  # $1=期望rc  $2=用例名  $3=内容
	printf '%s\n' "$3" > "$TMP/c.conf"
	run_case "$1" conf "$2" "$TMP/c.conf" conf
}

# src 夹具：逐行 printf 生成 —— 不能把多行塞进一个单引号字符串，
# 里面的 ' 会提前结束该字符串，导致夹具静默缺行（本地踩到过：假绿）。
src_begin() { rm -f "$TMP/ext.sh"; }
src_line() { printf '%s\n' "$1" >> "$TMP/ext.sh"; }
src_case() { run_case "$1" "src " "$2" "$TMP/ext.sh" src; }

echo "== role-map-check.py 自测（conf + src 两个入口，同一份判据）=="

# ── 应绿：本板口径 ───────────────────────────────────────────────
conf_case 0 "默认口径 wan1=eth0 lan1=eth1,eth2" 'ROLE_MAP="wan1=eth0 lan1=eth1,eth2"'
conf_case 0 "角色改名（wan/lan2）不影响口径判定" 'ROLE_MAP="wan=eth0 lan2=eth1,eth2"'
conf_case 0 "用 + 写同桥（与镜像脚本解析器同语义）" 'ROLE_MAP="wan1=eth0 lan1=eth1+eth2"'
conf_case 0 "真文件形态（注释 + 前后空行）" '# 注释
#   这一行不是行首 ROLE_MAP=，不算默认值
ROLE_MAP="wan1=eth0 lan1=eth1,eth2"
# 尾部注释'

# ── 应红：真实事故形态 ──────────────────────────────────────────
conf_case 1 "旧写法：三口各一个角色（两个 2.5G 被拆成两个桥）" 'ROLE_MAP="wan1=eth0 lan1=eth1 lan2=eth2"'
conf_case 1 "漏口：只映射两口（第三个口插线不通）" 'ROLE_MAP="wan1=eth0 lan1=eth1"'
conf_case 1 "重复口：eth1 同时在两个桥里" 'ROLE_MAP="wan1=eth0 lan1=eth1 lan2=eth1,eth2"'
conf_case 1 "WAN 吞并 2.5G（1G 与 2.5G 同桥）" 'ROLE_MAP="wan1=eth0,eth1 lan2=eth2"'
conf_case 1 "2.5G 落到 WAN 侧" 'ROLE_MAP="wan1=eth1 lan1=eth0,eth2"'
conf_case 1 "空 ROLE_MAP" 'ROLE_MAP=""'
conf_case 1 "没有 ROLE_MAP 行" '# nothing here'

# ── src：扩展源码里的默认值 ─────────────────────────────────────
src_begin
src_line 'cat <<- EOF > "${SDCARD}/etc/lyw-rr-net-roles.conf"'
src_line '	ROLE_MAP="wan1=eth0 lan1=eth1,eth2"'
src_line 'EOF'
src_case 0 "扩展只写一次默认值（heredoc）"

src_begin
src_line 'cat <<- EOF > "${SDCARD}/etc/lyw-rr-net-roles.conf"'
src_line '	ROLE_MAP="wan1=eth0 lan1=eth1,eth2"'
src_line 'EOF'
src_line "grep -q 'ROLE_MAP=\"wan1=eth0 lan1=eth1,eth2\"' \"\${SDCARD}/etc/lyw-rr-net-roles.conf\" || fail=1"
src_case 1 "默认值在自检里被复制了第二份（= run #14 的根因，必须红）"

src_begin
src_line 'cat <<- EOF > "${SDCARD}/etc/lyw-rr-net-roles.conf"'
src_line '	ROLE_MAP="wan1=eth2 lan1=eth0,eth1"'
src_line 'EOF'
src_case 1 "默认值本身不合口径（1G 被当 LAN、2.5G 被当 WAN）"

src_begin
src_line 'echo hello'
src_case 1 "扩展里根本没有 ROLE_MAP"

echo
if [ "$failed" = 0 ]; then
	echo "== role-map-check 自测全部通过（$pass 例）=="
	exit 0
fi
echo "!! role-map-check 自测失败：$failed 例不通过（通过 $pass 例）"
exit 1
