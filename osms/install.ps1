# OpenStreamMS extension: install or update RDPAutoPatch (runs as SYSTEM from the package folder).
# -EnableRemoteDesktop: OpenStreamMS sessions need Remote Desktop on; with it off (e.g. right after
# uninstalling RDP Wrapper) the port check failed every mode.
# RDPAutoPatch.ps1 exit codes: 0 OK (also "degraded" to a single session), 1 error,
# 2 postponed because remote sessions are connected, 3 another run in progress, 5 not admin.
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'RDPAutoPatch.ps1'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Install -EnableRemoteDesktop
$code = $LASTEXITCODE
switch ($code) {
    0 { exit 0 }
    2 {
        Write-Output 'Installed. Remote sessions are connected, so the patch is applied when they close or after restarting Windows.'
        exit 3010
    }
    default { Write-Output "RDPAutoPatch -Install failed with exit code $code."; exit $code }
}
