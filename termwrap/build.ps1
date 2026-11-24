#Requires -Version 5.1
<#
Compila TermWrap.dll y Zydis.dll desde el codigo original de llccd/TermWrap (licencia MIT) con
los parches de la carpeta patches, y opcionalmente las copia a la carpeta del programa.

  .\build.ps1                 Compila en .\build y prueba el parche con el termsrv.dll del equipo
  .\build.ps1 -CopyToApp      Ademas copia las dos DLL a la carpeta del programa (..\)

Requisitos: git y Visual Studio Build Tools 2022 con C++ (MSBuild y el conjunto v143).
Despues de copiar las DLL hay que ejecutar Instalar.bat para registrar sus nuevas huellas.
#>
[CmdletBinding()]
param([switch]$CopyToApp)

$ErrorActionPreference = 'Stop'
$Upstream = 'https://github.com/llccd/TermWrap.git'
$Commit   = '34029fcd46de1db06b7f0815b99a765e4c7ca471'   # v0.7
$Here     = $PSScriptRoot
$Src      = Join-Path $Here 'build\src'
$Out      = Join-Path $Here 'build\out'

function Invoke-Native([string]$What, [scriptblock]$Cmd) {
    & $Cmd
    if ($LASTEXITCODE) { throw "$What ha fallado (codigo $LASTEXITCODE)" }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'No se encuentra Visual Studio Build Tools (vswhere.exe)' }
$msbuild = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'MSBuild\Current\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'No se encuentra MSBuild con las herramientas de C++' }

# Codigo original en el commit fijado, con su submodulo Zydis, y nuestros parches encima
if (Test-Path $Src) { Remove-Item $Src -Recurse -Force }
# Sin conversion de finales de linea: los parches se generaron contra el contenido exacto del repositorio
Invoke-Native 'git clone' { git -c core.autocrlf=false clone -q $Upstream $Src }
Invoke-Native 'git checkout' { git -C $Src checkout -q $Commit }
Invoke-Native 'git submodule' { git -C $Src -c core.autocrlf=false submodule update -q --init --recursive }
# De uno en uno: git apply con varios parches los compara todos con el codigo original
$patches = @(Get-ChildItem (Join-Path $Here 'patches') -Filter *.patch | Sort-Object Name)
foreach ($p in $patches) { Invoke-Native "git apply $($p.Name)" { git -C $Src apply --whitespace=nowarn $p.FullName } }
Write-Host "Aplicados $($patches.Count) parche(s) sobre $($Commit.Substring(0, 8))"

New-Item -ItemType Directory -Force $Out | Out-Null
$common = '/nologo', '/v:m', '/p:Platform=x64'
# MT: runtime de C estatico. Con MD, Zydis.dll dependia de VCRUNTIME140.dll, que un Windows recien
# instalado no trae, y TermService no arrancaba ("No se puede encontrar el modulo especificado").
Invoke-Native 'Zydis' { & $msbuild "$Src\zydis\msvc\zydis\Zydis.vcxproj" @common '/p:Configuration=Release MT DLL' "/p:SolutionDir=$Src\zydis\msvc\\" }
foreach ($p in 'TermWrap', 'TermWrapTest') {
    Invoke-Native $p { & $msbuild "$Src\$p\$p.vcxproj" @common '/p:Configuration=Release' "/p:SolutionDir=$Src\\" "/p:OutDir=$Out\\" "/p:IntDir=$Src\obj\$p\\" }
}
Copy-Item "$Src\zydis\msvc\bin\ReleaseX64\Zydis.dll" $Out -Force

# Prueba en seco con el termsrv.dll del equipo (se carga sin ejecutarlo y se parchea en memoria)
# Continue: en Windows PowerShell 5.1, con Stop, lo que el programa escribe en stderr corta el script
$report = & { $ErrorActionPreference = 'Continue'; & "$Out\TermWrapTest.exe" 2>$null } | Where-Object { $_ -match '^(TOTAL|REPORT)' }
$report | ForEach-Object { Write-Host $_ }
if (-not ($report -match '^REPORT 100 ')) { throw 'El parche principal (DefPolicyPatch) no se aplica a este termsrv.dll' }

foreach ($f in 'TermWrap.dll', 'Zydis.dll') { '{0}  {1}' -f (Get-FileHash "$Out\$f" -Algorithm SHA256).Hash, $f }
if ($CopyToApp) {
    $app = Split-Path $Here -Parent
    foreach ($f in 'TermWrap.dll', 'Zydis.dll') { Copy-Item "$Out\$f" (Join-Path $app $f) -Force }
    Write-Host "DLL copiadas a $app. Ejecuta Instalar.bat para aplicarlas." -ForegroundColor Green
}
