@echo off
rem Set up RayBan Claude (double-click is enough)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
pause
