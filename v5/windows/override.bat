@echo off
rem OVERRIDE v3 - opens the control panel without a console window
start "" powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0override.ps1"
