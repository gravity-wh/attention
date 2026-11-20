import re, sys
from pathlib import Path

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

source, destination = map(Path, sys.argv[1:])
result, added = add_vias(source.read_text(encoding="utf-8"))
if not added:
    raise SystemExit("No default vias added")
destination.write_text(result, encoding="utf-8")
print(f"Added {added} explicit default vias from VIARULE definitions")
