# OpenStreamMS extension: exit 0 if RDPAutoPatch is installed (program folder and scheduled task).
$ok = (Test-Path 'C:\Program Files\RDPAutoPatch\RDPAutoPatch.ps1') -and
      [bool](Get-ScheduledTask -TaskName 'RDPAutoPatch' -ErrorAction SilentlyContinue)
if ($ok) { exit 0 } else { exit 1 }
