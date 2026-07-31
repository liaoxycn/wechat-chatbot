[CmdletBinding()]
param([string]$Python = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Python)) {
    $homeDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $Python = Join-Path $homeDirectory '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
}
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "未找到兼容的 Codex Python：$Python。请通过 -Python 指定 Python 3.12。"
}

$version = & $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
if ($LASTEXITCODE -ne 0 -or $version -notin @('3.10', '3.11', '3.12')) {
    throw "OCR 依赖仅支持 Python 3.10-3.12，当前解释器为：$Python"
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    & $Python -m venv (Join-Path $projectRoot '.venv')
    if ($LASTEXITCODE -ne 0) { throw '创建 OCR 虚拟环境失败。' }
}

& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r (Join-Path $PSScriptRoot 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'OCR 依赖安装失败。' }

$output = & $venvPython -c "import cv2, rapidocr_onnxruntime; print('ok')" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "OCR 运行库校验失败。$($output | Out-String)"
}

"OCR 环境已就绪：$venvPython"
