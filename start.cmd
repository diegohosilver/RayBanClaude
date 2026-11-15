@echo off
rem Start RayBan Claude (double-click is enough)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" %*
