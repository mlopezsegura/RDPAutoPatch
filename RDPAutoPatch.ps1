#Requires -Version 5.1
<#
RDPAutoPatch.ps1 - Mantiene el Escritorio remoto parcheado automaticamente (varias sesiones,
tambien del mismo usuario).

Modos, por orden de preferencia:
  1. TermWrap  : parche dinamico en memoria (no depende de la version de termsrv.dll)
  2. Original  : termsrv.dll de Windows sin parche (una sola sesion, pero el RDP sigue funcionando)

Despues de cada cambio comprueba que el servicio arranca, sigue estable, escucha en el puerto
y tiene cargada la DLL esperada. Si no, marca ese modo como fallido para esa version de
termsrv.dll y pasa al siguiente. Si Windows Update cambia termsrv.dll, vuelve a intentarlo.

Programa autocontenido: la carpeta de distribucion lleva este script, TermWrap.dll, Zydis.dll y
los .bat. -Install lo copia todo a C:\Program Files\RDPAutoPatch (ruta protegida: el servicio
corre como SYSTEM y no debe cargar DLL desde carpetas en las que escriban usuarios normales).
-Install tambien retira el RDP Wrapper clasico (C:\Program Files\RDP Wrapper), cuyo autoupdate
cambiaba el servicio por su cuenta.

Uso (PowerShell como administrador):
  .\RDPAutoPatch.ps1 -Install       Instala/actualiza, olvida fallos anteriores, crea la tarea y comprueba
  .\RDPAutoPatch.ps1 -Check         Comprueba y corrige (es lo que ejecuta la tarea programada)
  .\RDPAutoPatch.ps1 -Check -Force  Igual, aunque haya sesiones remotas abiertas (las corta)
  .\RDPAutoPatch.ps1                Muestra el estado sin cambiar nada
  .\RDPAutoPatch.ps1 -Uninstall     Quita la tarea, deja termsrv.dll original y borra la instalacion
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$AppDir     = 'C:\Program Files\RDPAutoPatch'
$LogFile    = Join-Path $AppDir 'autopatch.log'
$StateFile  = Join-Path $AppDir 'state.json'
$ParamKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters'
$TsKey      = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$PolKey     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$TaskName   = 'RDPAutoPatch'
$AppFiles   = 'RDPAutoPatch.ps1', 'TermWrap.dll', 'Zydis.dll'
$OldWrapDir = 'C:\Program Files\RDP Wrapper'
$OldUninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RDPWrap with Autoupdate 1.4',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RDPWrap with Autoupdate 1.4'
$script:ExitCode = 0

$Modes = [ordered]@{
    TermWrap = @{ Dll = "$AppDir\TermWrap.dll"; Deps = @("$AppDir\Zydis.dll"); Module = 'TermWrap.dll' }
    Original = @{ Dll = '%SystemRoot%\System32\termsrv.dll'; Deps = @(); Module = 'termsrv.dll' }
}
$PinnedFiles = @("$AppDir\TermWrap.dll", "$AppDir\Zydis.dll")

# ---------------------------------------------------------------- utilidades

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    try {
        if (-not (Test-Path $AppDir)) { return }
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.1" -Force }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TermsrvVersion {
    $v = (Get-Item "$env:SystemRoot\System32\termsrv.dll").VersionInfo
    '{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart
}

function Get-ServiceDll { (Get-ItemProperty $ParamKey).ServiceDll }

function Set-ServiceDll([string]$Dll) {
    New-ItemProperty -Path $ParamKey -Name ServiceDll -Value $Dll -PropertyType ExpandString -Force | Out-Null
}

function Get-ModeFromDll([string]$Dll) {
    $exp = [Environment]::ExpandEnvironmentVariables($Dll)
    foreach ($k in $Modes.Keys) {
        if ([Environment]::ExpandEnvironmentVariables($Modes[$k].Dll) -ieq $exp) { return $k }
    }
    'Desconocido'
}

function Get-Sha256([string]$Path) {
    if (Test-Path $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash } else { '' }
}

function Read-State {
    $s = @{ TermsrvVersion = ''; Mode = ''; LastResult = ''; LastCheck = ''; Bad = @{}; Pins = @{} }
    if (Test-Path $StateFile) {
        try {
            $j = Get-Content $StateFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($p.Name -in 'Bad', 'Pins') {
                    $h = @{}
                    if ($p.Value) { foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value } }
                    $s[$p.Name] = $h
                } else { $s[$p.Name] = $p.Value }
            }
        } catch { Write-Log "state.json ilegible, se empieza de cero: $_" WARN }
    }
    $s
}

function Save-State($State) {
    $State.LastCheck = (Get-Date).ToString('s')
    ($State | ConvertTo-Json -Depth 4) | Set-Content -Path $StateFile -Encoding UTF8
}

function Backup-Params {
    $f = Join-Path $AppDir 'TermService_Parameters_original.reg'
    if (-not (Test-Path $f)) {
        & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\TermService\Parameters' $f /y | Out-Null
        Write-Log "Copia del registro guardada en $f"
    }
}

function Get-TsProcessId { [int](Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId }

function Get-RdpPort {
    try { [int](Get-ItemProperty "$TsKey\WinStations\RDP-Tcp").PortNumber } catch { 3389 }
}

function Get-RemoteSessionCount { @(qwinsta 2>$null | Select-String 'rdp-tcp#').Count }

# Varias sesiones del mismo usuario: fSingleSessionPerUser debe ser 0
function Set-MultiSessionPerUser {
    $v = (Get-ItemProperty $TsKey).fSingleSessionPerUser
    if ($v -ne 0) {
        New-ItemProperty -Path $TsKey -Name fSingleSessionPerUser -Value 0 -PropertyType DWord -Force | Out-Null
        Write-Log "fSingleSessionPerUser estaba en '$v'; puesto a 0 (varias sesiones por usuario)" WARN
    }
    if ((Get-ItemProperty $PolKey -ErrorAction SilentlyContinue).fSingleSessionPerUser -eq 1) {
        Write-Log 'Una directiva de grupo fuerza una sola sesion por usuario (fSingleSessionPerUser=1); no se toca' WARN
    }
}

# ---------------------------------------------------------------- servicio

function Restart-TermService {
    $svcPid = Get-TsProcessId
    Write-Log 'Reiniciando TermService...'
    foreach ($n in 'UmRdpService', 'TermService') {
        $s = Get-Service $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Stopped') {
            try { $s.Stop() } catch { }
            try { $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) } catch { }
        }
    }
    if ((Get-Service TermService).Status -ne 'Stopped' -and $svcPid -gt 0) {
        $shared = @(Get-CimInstance Win32_Service -Filter "ProcessId=$svcPid").Count
        if ($shared -gt 1) { throw 'TermService no se detiene y comparte proceso con otros servicios' }
        Write-Log "TermService no se detiene; se cierra su proceso ($svcPid)" WARN
        Stop-Process -Id $svcPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Start-Service TermService
    Start-Service UmRdpService -ErrorAction SilentlyContinue
}

# Devuelve la lista de problemas (vacia = sano)
function Get-HealthProblems([string]$Mode, [datetime]$Since, [int]$SettleSeconds) {
    $problems = New-Object System.Collections.Generic.List[string]
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Service TermService).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if ((Get-Service TermService).Status -ne 'Running') { $problems.Add('TermService no esta en ejecucion'); return , $problems }

    $pid1 = Get-TsProcessId
    Start-Sleep -Seconds $SettleSeconds
    $pid2 = Get-TsProcessId
    if ((Get-Service TermService).Status -ne 'Running') { $problems.Add('TermService se ha parado') }
    if ($pid1 -ne $pid2) { $problems.Add('TermService se ha reiniciado solo') }

    $port = Get-RdpPort
    $listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Where-Object OwningProcess -eq $pid2
    if (-not $listen) { $problems.Add("el servicio no escucha en el puerto $port") }

    $display = (Get-Service TermService).DisplayName
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $Since } -ErrorAction SilentlyContinue |
        Where-Object { $_.Properties[0].Value -eq $display })
    if ($crashes.Count) { $problems.Add("$($crashes.Count) cierre(s) inesperado(s) del servicio") }

    try {
        $mods = (Get-Process -Id $pid2 -Module -ErrorAction Stop).ModuleName
        if ($mods -notcontains $Modes[$Mode].Module) { $problems.Add("$($Modes[$Mode].Module) no esta cargado en el servicio") }
        if ($Mode -eq 'TermWrap' -and $mods -notcontains 'Zydis.dll') { $problems.Add('Zydis.dll no esta cargado en el servicio') }
    } catch {
        Write-Log 'No se pueden listar los modulos del servicio; se omite esa comprobacion' WARN
    }
    , $problems
}

# Devuelve $null si el modo se puede usar, o el motivo por el que no
function Get-ModeProblem([string]$Mode, [string]$Ver, $State) {
    $m = $Modes[$Mode]
    $dll = [Environment]::ExpandEnvironmentVariables($m.Dll)
    if (-not (Test-Path $dll)) { return "no existe $dll" }
    if ($Mode -eq 'Original') { return $null }   # ultimo recurso, siempre disponible
    foreach ($d in $m.Deps) { if (-not (Test-Path $d)) { return "falta $d" } }
    if ($State.Bad.ContainsKey("$Mode@$Ver")) { return "ya fallo con termsrv.dll $Ver (ejecuta Instalar.bat para reintentar)" }
    foreach ($f in $PinnedFiles) {
        $name = Split-Path $f -Leaf
        if (-not $State.Pins.ContainsKey($name)) { return "$name sin huella registrada (ejecuta Instalar.bat)" }
        if ((Get-Sha256 $f) -ne $State.Pins[$name]) { return "$name ha cambiado desde la instalacion; si es legitimo, ejecuta Instalar.bat" }
    }
    $null
}

# ---------------------------------------------------------------- acciones

function Invoke-Check {
    $state = Read-State
    $ver = Get-TermsrvVersion
    if ($state.TermsrvVersion -ne $ver) {
        if ($state.TermsrvVersion) { Write-Log "termsrv.dll ha cambiado: $($state.TermsrvVersion) -> $ver" WARN }
        $state.TermsrvVersion = $ver
        $state.Bad = @{}
    }
    $current = Get-ModeFromDll (Get-ServiceDll)
    Write-Log "termsrv.dll $ver | modo actual: $current"
    Set-MultiSessionPerUser

    if ((Get-ItemProperty $TsKey).fDenyTSConnections -ne 0) {
        Write-Log 'El Escritorio remoto esta desactivado en Windows (fDenyTSConnections=1); no se toca' WARN
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($m in $Modes.Keys) {
        $why = Get-ModeProblem $m $ver $state
        if ($why) { Write-Log "Modo $m descartado: $why" } else { $candidates.Add($m) }
    }

    if ($candidates.Count -and $current -eq $candidates[0]) {
        $since = try { (Get-Process -Id (Get-TsProcessId) -ErrorAction Stop).StartTime } catch { (Get-Date).AddMinutes(-10) }
        $p = Get-HealthProblems $current $since 3
        if ($p.Count -eq 0) {
            Write-Log "Todo correcto: modo $current activo y estable" OK
            $state.Mode = $current; $state.LastResult = 'OK'; Save-State $state
            return
        }
        Write-Log ("Modo $current con problemas: " + ($p -join '; ')) WARN
        if ($current -ne 'Original') { $state.Bad["$current@$ver"] = $true; [void]$candidates.Remove($current) }
    }

    $remote = Get-RemoteSessionCount
    if ($remote -gt 0 -and -not $Force -and (Get-Service TermService).Status -eq 'Running') {
        Write-Log "Hay $remote sesion(es) remota(s) abierta(s); el cambio se pospone para no cortarlas (usa -Force para forzarlo)" WARN
        $state.LastResult = 'Pospuesto'; Save-State $state
        $script:ExitCode = 2
        return
    }

    Backup-Params
    foreach ($m in $candidates) {
        Write-Log "Aplicando modo $m..."
        Set-ServiceDll $Modes[$m].Dll
        try { Restart-TermService } catch { Write-Log "Error al reiniciar el servicio: $_" ERROR }
        $since = Get-Date
        $p = Get-HealthProblems $m $since 15
        if ((Get-ModeFromDll (Get-ServiceDll)) -ne $m) {
            Write-Log "Otro programa ha cambiado el servicio a '$(Get-ServiceDll)' mientras se probaba $m; no se marca como fallido" ERROR
            $state.LastResult = 'Interferencia'; Save-State $state
            $script:ExitCode = 1
            return
        }
        if ($p.Count -eq 0) {
            if ($m -eq 'Original') {
                Write-Log 'TermWrap no funciona con esta version; RDP activo en modo original de Windows (una sola sesion)' WARN
                $state.LastResult = 'Degradado'
            } else {
                Write-Log "Modo $m aplicado y estable" OK
                $state.LastResult = 'OK'
            }
            $state.Mode = $m; Save-State $state
            return
        }
        Write-Log ("Modo $m fallido: " + ($p -join '; ')) ERROR
        if ($m -ne 'Original') { $state.Bad["$m@$ver"] = $true }
        Save-State $state
    }
    Write-Log 'Ningun modo ha funcionado; revisa el servicio a mano' ERROR
    $state.LastResult = 'Error'; Save-State $state
    $script:ExitCode = 1
}

# Pasa el servicio a modo Original si esta usando una DLL de la carpeta indicada
function Release-ServiceFrom([string]$Dir) {
    $exp = [Environment]::ExpandEnvironmentVariables((Get-ServiceDll))
    if ($exp -like "$Dir\*") {
        Write-Log "El servicio usa $exp; se pasa a modo Original para poder tocar $Dir" WARN
        Set-ServiceDll $Modes.Original.Dll
        Restart-TermService
    }
}

# Elimina el RDP Wrapper clasico ("RDPWrap with Autoupdate") y su carpeta
function Remove-OldRdpWrapper {
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -ne $TaskName -and (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match 'autoupdate\.bat|RDPWInst|RDP Wrapper' } |
        ForEach-Object {
            Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false
            Write-Log "Tarea antigua eliminada: $($_.TaskPath)$($_.TaskName)"
        }
    foreach ($k in $OldUninstallKeys) {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force; Write-Log 'Entrada "RDPWrap with Autoupdate" quitada de Programas instalados' }
    }
    if (Test-Path $OldWrapDir) {
        Release-ServiceFrom $OldWrapDir
        try { Remove-Item $OldWrapDir -Recurse -Force -ErrorAction Stop; Write-Log "Carpeta antigua $OldWrapDir eliminada" OK }
        catch { Write-Log "No se pudo borrar del todo $OldWrapDir : $_" WARN }
    }
}

function Invoke-Install {
    $src = $PSScriptRoot
    foreach ($f in $AppFiles) {
        if (-not (Test-Path (Join-Path $src $f))) { throw "Falta $f en $src; la carpeta del programa debe llevarlo" }
    }
    Backup-Params

    # Copiar programa y DLL a la carpeta protegida (si cambian las DLL, soltarlas antes)
    if ($src -ine $AppDir) {
        $dllChanged = $false
        foreach ($f in $PinnedFiles) { if ((Get-Sha256 (Join-Path $src (Split-Path $f -Leaf))) -ne (Get-Sha256 $f)) { $dllChanged = $true } }
        if ($dllChanged) { Release-ServiceFrom $AppDir }
        foreach ($f in $AppFiles) { Copy-Item (Join-Path $src $f) (Join-Path $AppDir $f) -Force }
        Write-Log "Programa copiado de $src a $AppDir"
    }

    Remove-OldRdpWrapper

    $state = Read-State
    $state.Pins = @{}
    foreach ($f in $PinnedFiles) {
        $name = Split-Path $f -Leaf
        $state.Pins[$name] = Get-Sha256 $f
        Write-Log "Huella registrada: $name $($state.Pins[$name])"
    }
    $state.Bad = @{}
    Save-State $state

    $dest = Join-Path $AppDir 'RDPAutoPatch.ps1'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Mantiene el Escritorio remoto parcheado (RDPAutoPatch)</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>
    <CalendarTrigger>
      <Repetition><Interval>PT4H</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Service Control Manager'] and (EventID=7031 or EventID=7034)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$dest" -Check</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
    Write-Log "Tarea programada '$TaskName' creada (al arrancar, cada 4 horas y si el servicio se cae)" OK
    Invoke-Check
}

function Invoke-Uninstall {
    $remote = Get-RemoteSessionCount
    if ($remote -gt 0 -and -not $Force) {
        Write-Log "Hay $remote sesion(es) remota(s); no se desinstala para no cortarlas (usa -Force)" WARN
        $script:ExitCode = 2
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Tarea '$TaskName' eliminada"
    Set-ServiceDll $Modes.Original.Dll
    Restart-TermService
    Write-Log 'Servicio devuelto a termsrv.dll original de Windows' OK
    $script:RemoveAppDir = $true
}

function Show-Status {
    $state = Read-State
    $ver = Get-TermsrvVersion
    $dll = Get-ServiceDll
    $mode = Get-ModeFromDll $dll
    $svc = Get-Service TermService
    $svcPid = Get-TsProcessId
    $port = Get-RdpPort
    $listen = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $svcPid)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $mods = try { ((Get-Process -Id $svcPid -Module -ErrorAction Stop).ModuleName | Where-Object { $_ -match '^(TermWrap|Zydis|rdpwrap|termsrv)\.dll$' }) -join ', ' } catch { '(requiere administrador)' }

    [pscustomobject]@{
        'termsrv.dll'         = $ver
        'ServiceDll'          = $dll
        'Modo'                = $mode
        'Servicio'            = $svc.Status
        "Escucha en $port"    = $listen
        'DLL cargadas'        = $mods
        'Sesiones remotas'    = Get-RemoteSessionCount
        'Varias por usuario'  = ((Get-ItemProperty $TsKey).fSingleSessionPerUser -eq 0)
        'Tarea programada'    = if ($task) { $task.State } else { 'no instalada' }
        'Ultima comprobacion' = "$($state.LastCheck) $($state.LastResult)"
    } | Format-List

    if ($mode -ne 'TermWrap') {
        Write-Host 'AVISO: sin TermWrap solo hay una sesion; al entrar otra vez se cierra la anterior.' -ForegroundColor Yellow
    }
    if (Test-Path $OldWrapDir) { Write-Host "AVISO: sigue existiendo $OldWrapDir (RDP Wrapper clasico); Instalar.bat la elimina." -ForegroundColor Yellow }
    Write-Host 'Modos disponibles:'
    foreach ($m in $Modes.Keys) {
        $why = Get-ModeProblem $m $ver $state
        if ($why) { Write-Host "  $m : NO ($why)" -ForegroundColor Yellow } else { Write-Host "  $m : si" -ForegroundColor Green }
    }
    if (Test-Path $LogFile) {
        Write-Host "`nUltimas lineas de $LogFile"
        Get-Content $LogFile -Tail 10
    }
}

# ---------------------------------------------------------------- inicio

if (($Install -or $Check -or $Uninstall) -and -not (Test-Admin)) {
    Write-Host 'Hay que ejecutarlo como administrador.' -ForegroundColor Red
    exit 5
}

# Una sola ejecucion a la vez (la tarea tambien se dispara con los reinicios que hace el propio programa)
$mutex = $null
$script:RemoveAppDir = $false
try {
    if ($Install -or $Check -or $Uninstall) {
        if ($Check -and -not (Test-Path $AppDir)) { throw "No esta instalado ($AppDir no existe); ejecuta Instalar.bat" }
        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
        $mutex = New-Object System.Threading.Mutex($false, 'Global\RDPAutoPatch')
        try { $got = $mutex.WaitOne([TimeSpan]::FromMinutes(5)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { Write-Log 'Otra ejecucion sigue en marcha; se sale' WARN; $mutex.Dispose(); exit 3 }
    }
    if ($Install)       { Invoke-Install }
    elseif ($Check)     { Invoke-Check }
    elseif ($Uninstall) { Invoke-Uninstall }
    else                { Show-Status }
} catch {
    Write-Log "Error inesperado: $_" ERROR
    $script:ExitCode = 1
} finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}

if ($script:RemoveAppDir) {
    # Si se ejecuta desde la copia instalada, Windows permite borrar el .ps1 en uso
    Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Carpeta $AppDir eliminada" -ForegroundColor Green
}
exit $script:ExitCode
