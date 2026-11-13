@echo off
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoExit -ExecutionPolicy Bypass -File \"C:\Program Files\RDPAutoPatch\RDPAutoPatch.ps1\" -Uninstall'"
