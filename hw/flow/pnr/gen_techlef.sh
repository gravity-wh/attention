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
#    6. 后处理（下面两条都是 Innovus 的硬性要求，缺一不可）
#
#  后处理一：剥掉 LEF58 扩展属性
#    lefout 输出 PROPERTY LEF58_SPACING "SPACING 0.08 LAYER AA ;" 之类，
#    且出现在 LAYER AA 定义之前。Innovus 15.2 解析时 AA 尚未定义，直接
#      IMPLF-111: Layer 'AA' is not defined
#    并放弃整个 LEF。剥掉后 33 个 LAYER + 11 个 VIARULE 完整保留。
#
#  后处理二：间距表单调化
#    lefout 产出的 SPACINGTABLE 有递减项（如 TM2: WIDTH 1.999 0.5 0.4），
#    NanoRoute 直接拒绝：
#      NRFL-374 Spacing table is not monotonically increasing
#    这里沿「平行走线长度」和「宽度」两个方向取运行最大值，得到单调不减
#    的表，满足 LEF 规范并尽量保留原间距意图（等价于略微保守）。
#
#  用法： bash flow/pnr/gen_techlef.sh [输出目录]
# =====================================================================
set -uo pipefail
export PYTHONIOENCODING=utf-8          # locale=C 下 Python3 中文 print 会炸

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

# ---- 3. 后处理：剥 LEF58 + 间距表单调化 -------------------------------
echo "[techlef] 3/3 后处理（LEF58 + 间距表单调化）"
python3 - "$OUTDIR/smic40_tech_raw.lef" "$OUTDIR/smic40_tech.lef" <<'PY'
import re, sys

def normalize_tables(text):
    lines = text.split("\n")
    res, idx, ntab = [], 0, 0
    while idx < len(lines):
        cur = lines[idx]
        if cur.strip() != "SPACINGTABLE":
            res.append(cur)
            idx += 1
            continue
        block, idx = [cur], idx + 1
        rows = []
        while idx < len(lines):
            s = lines[idx].strip()
            if s.startswith("PARALLELRUNLENGTH"):
                block.append(lines[idx])
                idx += 1
                continue
            if s.startswith("WIDTH"):
                vals = s.rstrip(";").split()
                rows.append([vals[1], [float(x) for x in vals[2:]]])
                block.append(lines[idx])
                idx += 1
                if s.endswith(";"):
                    break
                continue
            break
        if not rows:
            res.extend(block)
            continue
        ncol = max(len(r[1]) for r in rows)
        for r in rows:
            while len(r[1]) < ncol:
                r[1].append(r[1][-1])
        for r in rows:                      # 行内：沿平行走线长度单调
            for j in range(1, ncol):
                r[1][j] = max(r[1][j], r[1][j-1])
        for i in range(1, len(rows)):       # 行间：沿宽度单调
            for j in range(ncol):
                rows[i][1][j] = max(rows[i][1][j], rows[i-1][1][j])
        ind = re.match(r"\s*", block[-1]).group(0)
        res.extend([b for b in block if not b.strip().startswith("WIDTH")])
        for k, (w, v) in enumerate(rows):
            tail = " ;" if k == len(rows) - 1 else ""
            res.append("%sWIDTH %s %s%s" % (ind, w, " ".join("%g" % x for x in v), tail))
        ntab += 1
    return "\n".join(res), ntab


def add_vias(text):
    """按 VIARULE ... GENERATE DEFAULT 生成配套的显式 VIA 定义。
    NanoRoute 需要显式 VIA，只有 VIARULE 会报
      NRDB-158 Missing via from LAYER M1 to LAYER M2 in RULE LEF_DEFAULT
    层序必须是 下层 -> 切割层 -> 上层，LEF 对顺序有要求。"""
    pat = re.compile(r"^VIARULE (\w+) GENERATE DEFAULT\s*$(.*?)^END \1\s*$", re.S | re.M)
    vias = []
    for m in pat.finditer(text):
        name, body = m.group(1), m.group(2)
        cut = re.search(r"LAYER (\w+) ;\s*\n\s*RECT (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) ;", body)
        if not cut:
            continue
        cutname = cut.group(1)
        x1, y1, x2, y2 = (float(cut.group(k)) for k in (2, 3, 4, 5))
        order, enc = [], {}
        for lm in re.finditer(r"LAYER (\w+) ;\s*\n\s*ENCLOSURE (-?[\d.]+) (-?[\d.]+) ;", body):
            enc[lm.group(1)] = (float(lm.group(2)), float(lm.group(3)))
            order.append(lm.group(1))
        routes = [l for l in order if l != cutname]
        if len(routes) != 2:
            continue
        lo, hi = routes
        exh, eyh = enc[lo]
        exh2, eyh2 = enc[hi]
        vias.append(
            "VIA %s DEFAULT\n"
            "  LAYER %s ;\n    RECT %.3f %.3f %.3f %.3f ;\n"
            "  LAYER %s ;\n    RECT %.3f %.3f %.3f %.3f ;\n"
            "  LAYER %s ;\n    RECT %.3f %.3f %.3f %.3f ;\n"
            "END %s\n" % (name, lo, x1-exh, y1-eyh, x2+exh, y2+eyh,
                          cutname, x1, y1, x2, y2,
                          hi, x1-exh2, y1-eyh2, x2+exh2, y2+eyh2, name))
    if not vias:
        return text, 0
    first = text.find("VIARULE ")
    return text[:first] + "".join(vias) + text[first:], len(vias)

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
n0 = s.count("LEF58")
s = re.sub(r"PROPERTYDEFINITIONS.*?END PROPERTYDEFINITIONS\n", "", s, flags=re.S)
s = re.sub(r"\n[ \t]*PROPERTY LEF58_[A-Z_0-9]+ \"[^\"]*\"[ \t]*;", "", s)
s, ntab = normalize_tables(s)
# 剥掉钝化层 PA：它是 CUT 层但上面没有布线层，NanoRoute 直接拒绝
#   NRDB-329 Found a cut layer "PA" which does not have up layer
# 钝化层不参与布线，删掉不影响任何电气规则。
s, npa = re.subn(r"^LAYER PA\b.*?^END PA\s*$\n?", "", s, flags=re.S | re.M)
s, nvia = add_vias(s)
open(dst, "w").write(s)
layers = len(re.findall(r"^LAYER ", s, flags=re.M))
viarules = len(re.findall(r"^VIARULE ", s, flags=re.M))
print("    LEF58 %d -> %d | LAYER=%d VIARULE=%d | 间距表=%d | 删PA=%d | 生成VIA=%d"
      % (n0, s.count("LEF58"), layers, viarules, ntab, npa, nvia))
sys.exit(0 if layers else 1)
PY
[ $? -eq 0 ] || die "后处理自检失败（LAYER=0）"

echo "[techlef] ✓ 完成：$OUTDIR/smic40_tech.lef"
echo "[techlef]   Innovus 用法： set init_lef_file {\$TECH_LEF \$CELL_LEF}"
echo "[techlef]   tech LEF 必须排在单元 LEF 前面。"
