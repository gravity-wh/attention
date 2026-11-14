#!/usr/bin/env bash
# =====================================================================
#  flow/env.sh —— 采集环境清单（机器 / 工具版本 / PDK 文件 / license）
#
#  用法（只由 make env 调用）：
#      make env                 # 默认写 runs/env/ENV.md
#      ENV_MD5=1 make env       # 额外算 md5（.lib 较大，默认只报大小）
#      OUT_DIR=/tmp/e make env  # 换输出目录
#
#  它回答的问题：报告里那张「实验环境」表，值到底是从哪台机器、哪个
#  版本上读来的。所有条目都是**现场探测**，不是文档抄来的。
#
#  输出设计：
#    · 表 1  机器（OS / 内核 / CPU / 内存 / 磁盘）
#    · 表 2  工具（版本 + 绝对路径 + 是否找到）
#    · 表 3  PDK（按 config/pdk.mk 传下来的路径逐个 stat）
#    · 表 4  license 与关键环境变量
#  找不到的项写 NOT FOUND / MISSING，不静默跳过 —— 缺什么必须一眼看见。
#
#  ⚠ 输出保持纯 ASCII：客户机 locale 可能是 C，中文在多机之间会乱码；
#    中文解释在 docs/engineering/11-环境与工具链清单.md，本脚本只管取值。
# =====================================================================
set -uo pipefail

OUT_DIR=${OUT_DIR:-runs/env}
OUT="$OUT_DIR/ENV.md"
mkdir -p "$OUT_DIR" 2>/dev/null || { echo "cannot create $OUT_DIR" >&2; exit 1; }

PDK=${PDK:-unknown}
CORNER=${CORNER:-unknown}
PVT=${PVT:-unknown}

have() { command -v "$1" >/dev/null 2>&1; }
missing=0

# GNU timeout 才带 --version；Windows 自带的 timeout.exe 会直接报参数错。
TO=""
if timeout --version >/dev/null 2>&1; then TO="timeout 20"; fi

# 取命令输出的前两行，压成一行；命令不存在时标 NOT FOUND。
probe() {
    local label=$1; shift
    if ! have "$1"; then
        printf '| %s | `%s` | NOT FOUND |\n' "$label" "$*"
        missing=$((missing + 1))
        return
    fi
    local out
    out=$($TO "$@" 2>&1 | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -2 \
          | sed 's/|/\\|/g' | paste -sd' ' -)
    printf '| %s | `%s` | %s |\n' "$label" "$*" "${out:-<no output>}"
}

# PDK 文件：存在就报大小（可选 md5），不存在标 MISSING 并计数。
chk() {
    local label=$1 path=${2:-}
    if [ -z "$path" ]; then
        printf '| %s | (undefined in config/pdk.mk) | - | - |\n' "$label"
        missing=$((missing + 1)); return
    fi
    if [ ! -f "$path" ]; then
        printf '| %s | `%s` | MISSING | - |\n' "$label" "$path"
        missing=$((missing + 1)); return
    fi
    local sz md5
    sz=$(stat -c %s "$path" 2>/dev/null || wc -c <"$path" | tr -d ' ')
    md5="-"
    if [ "${ENV_MD5:-0}" = "1" ] && have md5sum; then
        md5=$(md5sum "$path" | awk '{print $1}')
    fi
    printf '| %s | `%s` | %s B | %s |\n' "$label" "$path" "$sz" "$md5"
}

{
echo "# 环境清单（现场采集）"
echo
echo "> 由 \`make env\` 生成，采集时间 $(date -Iseconds 2>/dev/null || date)"
echo "> 机器 \`$(hostname 2>/dev/null || echo unknown)\`　主机 $(uname -s -r 2>/dev/null || echo unknown)"
echo "> 选择：PDK=$PDK  CORNER=$CORNER  PVT=$PVT"
echo "> ⚠ 本文件进 \`runs/\`，不进版本库；报告里引用的是它的结论，不是这个路径。"
echo

echo "## 1. 机器"
echo
echo "| 项 | 值 |"
echo "|---|---|"
if [ -r /etc/centos-release ]; then
    echo "| 发行版 | $(tr -d '\n' < /etc/centos-release) |"
elif [ -r /etc/os-release ]; then
    echo "| 发行版 | $(. /etc/os-release; echo "$PRETTY_NAME") |"
else
    echo "| 发行版 | unknown（非 Linux 或无 /etc/os-release） |"
fi
echo "| 内核 | $(uname -srm 2>/dev/null || echo unknown) |"
if [ -r /proc/cpuinfo ]; then
    echo "| CPU | $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //') × $(nproc 2>/dev/null || echo ?) |"
else
    echo "| CPU | unknown |"
fi
if [ -r /proc/meminfo ]; then
    echo "| 内存 | $(awk '/MemTotal:/{printf "%.1f GB", $2/1048576}' /proc/meminfo) |"
    echo "| swap | $(awk '/SwapTotal:/{printf "%.1f GB", $2/1048576}' /proc/meminfo) |"
else
    echo "| 内存 | unknown |"
fi
echo "| 当前目录可用磁盘 | $(df -h . 2>/dev/null | awk 'NR==2{print $4}') |"
echo

echo "## 2. 工具（版本 + 路径）"
echo
echo "| 用途 | 探测命令 | 输出 |"
echo "|---|---|---|"
probe "仿真器 VCS"        vcs -ID
probe "波形 Verdi"        verdi -version
probe "综合 Genus"        genus -version
probe "布局布线 Innovus"  innovus -version
probe "tech LEF Virtuoso" virtuoso -version
probe "tech LEF lefout"   lefout -version
probe "DRC/LVS Calibre"   calibre -v
probe "C 模型 gcc"        gcc --version
probe "脚本 python3"      python3 -V
probe "构建 make"         make -v
probe "lint verilator"    verilator --version
probe "版本管理 git"      git --version
echo

echo "## 3. PDK 文件（按 \`config/pdk.mk\` 的当前选择）"
echo
echo "| 用途 | 路径 | 大小 | md5 |"
echo "|---|---|---|---|"
chk "时序库 tt"       "${SYN_LIB:-}"
chk "单元 LEF"        "${SYN_LEF:-}"
chk "寄生提取 qrc"    "${ENV_QRC:-}"
chk "门级仿真模型"    "${ENV_VERILOG:-}"
chk "techfile（tech LEF 源）" "${ENV_TECHFILE:-}"
echo
echo "> 库、角、驱动单元、负载、活动率等约束参数的取值见 \`make pdkcheck\`；"
echo "> 三个角各需一份 \`.lib\` + 一份 qrc，此处只核对**当前角**，三角齐全性由 \`make pdkcheck\` 与 \`make synall\` 保证。"
echo

echo "## 4. license 与环境变量"
echo
echo "| 变量 | 值 |"
echo "|---|---|"
for v in VCS_HOME VERDI_HOME SCL_HOME LM_LICENSE_FILE SNPSLMD_LICENSE_FILE \
         GENUS_HOME INNOVUS_HOME CDS_LIC_FILE; do
    eval "val=\${$v:-}"
    echo "| $v | ${val:-(unset)} |"
done
echo
if have lmstat; then
    echo "<details><summary>lmstat（Synopsys，前 12 行）</summary>"
    echo
    echo '```'
    $TO lmstat -a -c "${SNPSLMD_LICENSE_FILE:-27000@localhost.localdomain}" 2>&1 \
        | tr -d '\r' | head -12
    echo '```'
    echo
    echo "</details>"
else
    echo "> lmstat 不存在，跳过 license 状态查询。"
fi
echo
} > "$OUT"

echo "_缺失/未定义项合计：$missing _" >> "$OUT"

echo "-> $OUT"
echo "   PDK=$PDK CORNER=$CORNER PVT=$PVT  缺失/未定义：$missing"
[ "$missing" -eq 0 ] || echo "   ⚠ 有缺失项，先看上面第 2/3 节；报告里不要写未核实的环境值。"
exit 0
