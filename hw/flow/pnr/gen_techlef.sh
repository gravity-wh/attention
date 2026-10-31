#!/usr/bin/env bash
# =====================================================================
#  flow/pnr/gen_techlef.sh —— 从 SMIC40 的 ASCII techfile 生成 tech LEF
#
#  为什么需要这一步：
#    SMIC 40LL 交付包里的 lef/sc9mc_..._c40.lef 是 **macro-only**（只有单元
#    MACRO，没有任何 LAYER 段）。Innovus 布线必须有工艺层定义（层宽/间距/
#    方块电阻/面积电容），否则 read_physical 直接失败，更谈不上 route。
#    包里也没有现成的 tech LEF，唯一的工艺数据是
#    $PDK/smic40ll/techfile.tf（Virtuoso IC6 ASCII 格式）。
#
#  做法（Virtuoso -> OA tech.db -> lefout）：
#    1. ddCreateLib 建一个 OA 库
#    2. techOpenTechFile 打开它的 tech.db
#    3. tcLoadTechFile 把 ASCII techfile.tf 编译进去
#    4. techSaveTechFile 落盘
#    5. lefout -techOnly 导出 tech LEF
#    6. 剥掉 LEF58 扩展属性（见下）
#
#  为什么第 6 步必须做：
#    lefout 会输出 LEF58_* 扩展属性，其中
#      PROPERTY LEF58_SPACING "SPACING 0.08 LAYER AA ;" ;
#    出现在 LAYER AA 定义之前，Innovus 15.2 解析该属性时 AA 尚未定义，
#    直接报 "IMPLF-111: Layer 'AA' is not defined" 并放弃整个 LEF。
#    这些属性是先进间距规则，对本设计的布线不是必需的；剥掉后
#    33 个 LAYER + 11 个 VIARULE 完整保留，Innovus 可正常加载。
#
#  用法： bash flow/pnr/gen_techlef.sh [输出目录]
#        默认输出到 work_techlef/smic40_tech.lef
# =====================================================================
set -uo pipefail

OUTDIR=${1:-$PWD/work_techlef}
PDK_TF=${PDK_TF:-/opt/cadence/PDK/smic40/smic40ll/techfile.tf}
LIBNAME=smic40tech

die() { echo "✗ $*" >&2; exit 1; }

command -v virtuoso >/dev/null || die "找不到 virtuoso（需要 IC617 环境）"
command -v lefout   >/dev/null || die "找不到 lefout（Virtuoso LEF Out）"
[ -f "$PDK_TF" ] || die "找不到 techfile: $PDK_TF"

mkdir -p "$OUTDIR/oa"
cd "$OUTDIR" || die "进不去 $OUTDIR"

# 每次重建，避免残留旧 tech.db 让结果"看起来成功"
rm -rf "$OUTDIR/oa/$LIBNAME" "$OUTDIR/smic40_tech_raw.lef" "$OUTDIR/smic40_tech.lef"
printf 'DEFINE %s %s/oa/%s\n' "$LIBNAME" "$OUTDIR" "$LIBNAME" > cds.lib

# ---- 1. Virtuoso 批处理：ASCII techfile -> OA tech.db ------------------
cat > mk.il <<EOF
let((libId techId ok)
  libId = ddCreateLib("$LIBNAME" "$OUTDIR/oa/$LIBNAME")
  printf("STEP1_LIB=%L\n" libId)
  when(libId
    techId = techOpenTechFile("$LIBNAME" "tech.db" "w")
    printf("STEP2_TECH=%L\n" techId)
    when(techId
      ok = tcLoadTechFile(techId "$PDK_TF" "w")
      printf("STEP3_LOAD=%L\n" ok)
      when(ok
        printf("STEP4_SAVE=%L\n" techSaveTechFile(techId))
        techCloseTechFile(techId)
      )
    )
  )
)
exit()
EOF

echo "[techlef] 1/3 Virtuoso 导入 $PDK_TF"
timeout 600 virtuoso -nograph -restore mk.il > virtuoso.log 2>&1
rc=$?
grep -E "STEP[0-9]_" virtuoso.log | sed 's/^/    /'
[ "$rc" -eq 0 ] || die "virtuoso 退出码 $rc（见 $OUTDIR/virtuoso.log）"
[ -f "$OUTDIR/oa/$LIBNAME/tech.db" ] || die "没生成 tech.db，导入失败"

# ---- 2. lefout 导出 tech LEF -----------------------------------------
echo "[techlef] 2/3 lefout -techOnly"
timeout 600 lefout -lef "$OUTDIR/smic40_tech_raw.lef" -lib "$LIBNAME" -techOnly \
        -log "$OUTDIR/lefout.log" > lefout.out 2>&1
rc=$?
grep -iE "translation completed" "$OUTDIR/lefout.log" | sed 's/^/    /'
[ "$rc" -eq 0 ] || die "lefout 退出码 $rc（见 $OUTDIR/lefout.log）"
[ -s "$OUTDIR/smic40_tech_raw.lef" ] || die "tech LEF 是空的"

# ---- 3. 剥 LEF58 属性并自检 ------------------------------------------
echo "[techlef] 3/3 剥离 LEF58 扩展属性"
python3 - "$OUTDIR/smic40_tech_raw.lef" "$OUTDIR/smic40_tech.lef" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
n0 = s.count("LEF58")
s = re.sub(r"PROPERTYDEFINITIONS.*?END PROPERTYDEFINITIONS\n", "", s, flags=re.S)
s = re.sub(r"\n[ \t]*PROPERTY LEF58_[A-Z_0-9]+ \"[^\"]*\"[ \t]*;", "", s)
open(dst, "w").write(s)
layers = len(re.findall(r"^LAYER ", s, flags=re.M))
viarules = len(re.findall(r"^VIARULE ", s, flags=re.M))
print("    LEF58 %d -> %d, LAYER=%d, VIARULE=%d" % (n0, s.count("LEF58"), layers, viarules))
if layers == 0:
    sys.exit("✗ 一个 LAYER 都没有，生成失败")
PY
[ $? -eq 0 ] || die "剥离后自检失败"

echo "[techlef] ✓ 完成：$OUTDIR/smic40_tech.lef"
echo "[techlef]   Innovus 里这样用："
echo "[techlef]     set init_lef_file {\$TECH_LEF \$CELL_LEF}"
echo "[techlef]   注意 tech LEF 必须排在单元 LEF 前面。"
