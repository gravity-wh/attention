# 汇报片子（SEU Beamer 模板）

东南大学 Beamer 主题的本地副本，用于本项目的组会/中期/结题汇报。
上游：<https://github.com/TouchFishPioneer/SEU-Beamer-Slide>（原始说明见 `README-upstream.md`）。

放在 `docs/report/` 下，符合仓库 README 的约定：**`docs/` 只放叙述与图，导出物进 `deliverables/`**。
具体到片子：`.tex` 与配图是源，进版本库；PDF 是产物，落到 `deliverables/`，不进版本库。

## 怎么编

```powershell
cd docs/report/slides

# 1) 先验证环境：编上游模板（8 页示例，内容是模板自带的）
powershell -ExecutionPolicy Bypass -File .\build.ps1

# 2) 编自己的片子
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Name ic_slides

# 3) 编完直接打开
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Name ic_slides -Open
```

PDF 默认写到仓库根的 `deliverables/`；`-Out <目录>` 可改。
编译日志在 `%TEMP%\seu-build-slides\ic_slides.log`（镜像目录），不在 NAS 上留中间文件。

> **为什么必须用 `build.ps1` 而不是直接 `xelatex`**：本仓库在 `\\home-nas` 网络盘上，
> `xdvipdfmx` 读不了 UNC 路径的 PNG，会报 `Image inclusion failed`，编出来是白框。
> 脚本先 `robocopy /MIR` 到 `%TEMP%` 再编，最后只回拷 PDF。

## 改这份片子（或照它起一份新的）

```powershell
cd docs/report/slides
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Name ic_slides -Open
```

`ic_slides.tex` 已经是本项目「16×16 注意力模块」结题汇报的**完整稿（23 页，4:3）**，
不再是骨架。要起一份新的才照抄 `SEU_BeamerTemplate.tex`，别直接改它——那份是上游原样，
留着当环境的冒烟测试用例。

改这几处就够了：

| 位置 | 改什么 |
|---|---|
| `\title{}` `\subtitle{}` | 题目 |
| `\author{}` `\institute{}` | 姓名、学号、专业 |
| `\date{}` | 汇报日期 |
| `\begin{document}` 后第一个 frame | 封面；后面 `\section{}` 决定右上角导航条 |

版式：

- `ic_slides.tex` 用 **4:3**（`aspectratio=43`），版心只有 **10.6 cm** 宽，宽表很容易顶出去。
- 中文正文与标题由 `xeCJK` + `seu.sty` 统一的字体配置接管，**不要在正文里再调 `\setCJKfont`**。

### 改这份片子会踩的三个坑（都已处理，改的时候别拆掉）

1. **宽表必须包 `\fitbox`**。`ic_slides.tex` 开头自定义了这个宏：超过 `\linewidth` 才等比缩放，
   没超过就原样输出。

   ```latex
   \makeatletter
   \newsavebox{\fitbox@b}
   \newcommand{\fitbox}[1]{%
     \sbox{\fitbox@b}{#1}%
     \ifdim\wd\fitbox@b>\linewidth
       \resizebox{\linewidth}{!}{\usebox{\fitbox@b}}%
     \else \usebox{\fitbox@b}\fi}
   \makeatother
   ```

   **不要改用 `adjustbox`**：本机 TeX 缺 `xkeyval`/`adjcalc`，装了也编不过，
   而 `tlmgr` 又不能跑（见文末环境一节）。

2. **表格单元格只放一行**。`beamer` 的 `\baselineskip` 小于中文行高，`p{}` 定宽列里
   中文一折行，第二行就会压到下一行条目上。要折行的说明写成段落，或用
   `\parbox{0.95\textwidth}{\scriptsize\raggedright ...}`。

3. **①②③④ 要显式归给 CJK 字体**。这几个圈号属 Enclosed Alphanumerics，
   默认会被分给 Helvetica 而报 `Missing character`：

   ```latex
   \xeCJKDeclareCharClass{CJK}{"2460 -> "2473}
   ```

### 自检

编完先看日志，这两项都应为 0：

```bash
grep -c "Overfull \\hbox" "$TEMP/seu-build-slides/ic_slides.log"   # 横向溢出
grep -c "Missing character" "$TEMP/seu-build-slides/ic_slides.log" # 缺字
```

但**日志为 0 不等于版面没问题**（表格压在相邻栏上时不报 overfull）。最后一遍要渲染成图逐页看：

```python
# 需要 pymupdf + Pillow；装包要挂代理 HTTPS_PROXY=http://127.0.0.1:7897
import fitz
doc = fitz.open("deliverables/ic_slides.pdf")
for i, page in enumerate(doc, 1):
    page.get_pixmap(dpi=140).save(f"p{i:02d}.png")
```

## 目录

```
slides/
├── seu.sty                 主题样式（配色、页眉页脚、封面色块）
├── source/                 封面色块背景与校徽（seu_background / seu_logo / seu_title）
├── fonts/                  Helvetica 四个字重 + 两个变体，由 seu.sty 按路径加载
├── figures/                示例配图 figure1-11.png（模板自带，可整批替换）
├── ic_slides.tex           本项目结题汇报的完整稿（23 页，4:3）—— 主产出
├── SEU_BeamerTemplate.tex  上游模板本身，8 页示例 —— 当环境冒烟测试用
├── fwscale_slides.tex      另一份用同一模板做的片子，只作排版参考（见下）
├── build.ps1               唯一推荐的构建入口
├── Makefile / make.bat / make.sh   上游脚本，留作参考（make.bat 直接调 xelatex，UNC 下会失败）
└── README-upstream.md      上游原说明
```

`fwscale_slides.tex` 是「快权重双轴缩放」实验的汇报（另一个 ML 项目），
**留在这里是因为它演示了这套模板里比较难写的几样东西**，抄版式比抄模板快：

- 三栏 TikZ 矩阵示意图（`tikz` + `\foreach` 填格）
- 宽表（`booktabs` + `\small`，第三列不折行）
- 图文混排：图上文下、左右双栏（`columns` + `column{.56\textwidth}`）
- 结论页的「能说 / 不能说」对照块

它引用的 `figures/fig_e1..3.png` 也是这份片子专属的，IC 片子用不上就可以一并删掉。

## 怎么讲：15 分钟节奏

23 页 / 900 秒，平均每页 40 秒。按节分配：

| 节 | 页 | 页数 | 预算 | 要点 |
|---|---|---:|---:|---|
| 封面 + 目录 | 1–2 | 2 | 30 s | 报题目、报名字，扫一眼目录就走 |
| 题目与约束 | 3–4 | 2 | 120 s | 三条约束互相拉扯；评分 40 分在「综合效率」 |
| 设计与实现 | 5–14 | 10 | 420 s | 前半（5–9）讲**为什么这么定**，后半（10–14）讲**怎么落地** |
| 验证 | 15–16 | 2 | 90 s | 一份 tb 三个 DUT；双判据的必要性 |
| 结果与效率 | 17–20 | 4 | 150 s | 数字 → 相对改善 → 归因干净 → 面积解剖 |
| 结论 | 21–22 | 2 | 70 s | 四条取舍 + 两个边界 |
| 致谢 | 23 | 1 | 10 s | — |

若被压到 10 分钟，按此顺序砍：**⑫ varB 的 80 拍**（并入 ⑪ 一句话带过）、
**⑳ 面积解剖**（只留「62% 是触发器」一个数）、**④ 为什么停在 4 lane**（结论挪到 ⑤ 的图注）。

三处**不能砍**：⑩ 三套实现一份契约（对应「≥2 方案」这条硬指标）、
⑮ 六类激励 616 例（对应「自检测试平台」30 分）、⑲ 两个项目边界（评委必问的口径题）。

## 环境（Windows 侧）

- TeX：`E:\texlive\2025`，`xelatex` 已验证可用。**这个安装原本是半损坏的**，
  `tlpkg/texlive.tlpdb` 曾被写成全零、`xetex`/`xeCJK` 缺失，已从 USTC CTAN 镜像手工补包修好。
  **不要跑 `tlmgr update`** —— 它会碰到那份坏库；要装包就用
  `https://mirrors.ustc.edu.cn/CTAN/systems/texlive/tlnet/archive/<pkg>.tar.xz`
  解压到 `E:\texlive\2025` 再 `mktexlsr`。
- 中文字体：`C:\Windows\Fonts` 下的 `simsun.ttc` / `simhei.ttf` / `msyh.ttc`。
- 演示机若没装这些字体，PDF 里已嵌入，不受影响；只有重新编译才依赖本机字体。

## 与仓库其它部分的衔接

片子里的数字（面积、功耗、拍数）应当能顺着 TAG 追回 `hw/runs/`，与
`docs/engineering/` 下的分析同源。**片子只放结论和口径**，推导留在 `docs/theory/`。
