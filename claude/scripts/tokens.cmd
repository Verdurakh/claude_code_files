@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0token-summary.ps1" %*
pause
