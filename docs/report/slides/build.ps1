# 编译 SEU Beamer 片子（IC 设计项目专用副本）
#
# 为什么要在本地镜像里编译：本仓库放在 \\home-nas 网络盘上，xdvipdfmx 无法通过
# UNC 路径读取 figures/*.png 与 source/*.png（报 "Image inclusion failed"），
# 所以先镜像到 %TEMP% 再编译，最后把 PDF 拷回来。源文件仍然只有 NAS 上这一份。
#
# 用法（在 docs/report/slides 下执行）：
#   powershell -ExecutionPolicy Bypass -File .\build.ps1                    # 编模板，验证环境
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Name ic_slides    # 编自己的片子
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Name ic_slides -Open
#
# PDF 默认写到仓库根的 deliverables/（该目录不进版本库）；-Out 可改。

param(
    [string]$Name = "SEU_BeamerTemplate",
    [string]$Out  = "",
    [switch]$Open,
    [string]$TexBin = "E:\texlive\2025\bin\windows"
)

$ErrorActionPreference = "Stop"
$src = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# 每份片子独占一个镜像目录，避免与其它项目的编译互相覆盖
$leaf = Split-Path $src -Leaf
$dst  = Join-Path $env:TEMP ("seu-build-" + $leaf)

# 默认输出到仓库根的 deliverables/；找不到就用本目录
if (-not $Out) {
    $probe = $src
    while ($probe) {
        $cand = Join-Path $probe "deliverables"
        if (Test-Path (Join-Path $cand ".gitkeep")) { $Out = $cand; break }
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
    if (-not $Out) { $Out = $src }
}

if (-not (Test-Path (Join-Path $src "$Name.tex"))) {
    throw "找不到 $Name.tex（当前目录 $src）。可用 -Name 指定文件名。"
}

Write-Host "[1/4] 镜像到本地构建目录: $dst"
robocopy $src $dst /MIR /XD .git /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy 失败 ($LASTEXITCODE)" }
Get-ChildItem -Path (Join-Path $dst '*') -Include *.aux,*.nav,*.snm,*.toc -File -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

Push-Location $dst
try {
    Write-Host "[2/4] xelatex 两遍: $Name.tex"
    foreach ($i in 1..2) {
        & (Join-Path $TexBin "xelatex.exe") -interaction=nonstopmode "$Name.tex" | Out-Null
        if (-not (Test-Path "$Name.pdf")) { throw "第 $i 遍未生成 PDF，请查看 $dst\$Name.log" }
    }

    Write-Host "[3/4] 检查日志"
    $err = Select-String -Path "$Name.log" -Pattern '^!' -ErrorAction SilentlyContinue
    if ($err) { Write-Warning ("日志中仍有错误: " + ($err | Select-Object -First 3 | ForEach-Object { $_.Line })) }
    $miss = (Select-String -Path "$Name.log" -Pattern 'Missing character' -ErrorAction SilentlyContinue).Count
    if ($miss -gt 0) { Write-Warning "有 $miss 处缺失字形（常见于生僻字/符号字体缺失），检查字体覆盖" }

    Write-Host "[4/4] 回拷 PDF -> $Out"
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $target = Join-Path $Out "$Name.pdf"
    Copy-Item "$dst\$Name.pdf" $target -Force
    $pages = Select-String -Path "$Name.log" -Pattern 'Output written.*\((\d+) pages' |
             Select-Object -Last 1
    Write-Host "完成: $target   $($pages.Line)"
    if ($Open) { Start-Process $target }
}
finally {
    Pop-Location
}
