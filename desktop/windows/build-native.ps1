$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual Studio C++ Build Tools required' }
$devcmd = Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
$out = Join-Path $here 'resources'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Push-Location $out
try {
  $script = Join-Path $out 'compile.cmd'
  @("@call `"$devcmd`" >nul", "@cl /nologo /std:c++17 /EHsc /O2 /MT `"$here/update-runner.cc`" /Fe:update-runner.exe") | Set-Content -LiteralPath $script -Encoding ascii
  & cmd.exe /d /c $script
  if ($LASTEXITCODE -ne 0) { throw 'Update runner compilation failed' }
} finally { Pop-Location }
