# OpenStreamMS extension: remove RDPAutoPatch and point the Remote Desktop service back to termsrv.dll.
$ErrorActionPreference = 'Stop'
$installed = 'C:\Program Files\RDPAutoPatch\RDPAutoPatch.ps1'
$script = if (Test-Path $installed) { $installed } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'RDPAutoPatch.ps1' }
if (-not (Test-Path $installed) -and -not (Get-ScheduledTask -TaskName 'RDPAutoPatch' -ErrorAction SilentlyContinue)) {
    Write-Output 'RDPAutoPatch is not installed.'
    exit 0
}
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Uninstall
$code = $LASTEXITCODE
switch ($code) {
    0 { exit 0 }
    2 {
        Write-Output 'Remote sessions are connected: uninstalling restarts the Remote Desktop service and would cut them. Stop every session and try again.'
        exit 2
    }
    default { Write-Output "RDPAutoPatch -Uninstall failed with exit code $code."; exit $code }
}
