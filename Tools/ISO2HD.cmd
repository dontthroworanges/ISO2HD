@echo off
rem Double-click launcher for the ISO2HD GUI (it elevates itself).
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0..\ISO2HD.ps1" %*
