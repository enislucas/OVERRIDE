@echo off
title OVERRIDE
cd /d "%~dp0"
if /I "%~1"=="test"   ( powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0override.ps1" -TestNow -TestWindowSec 30 & goto :eof )
if /I "%~1"=="arm"    ( powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0override.ps1" -Arm & pause & goto :eof )
if /I "%~1"=="disarm" ( powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0override.ps1" -Disarm & pause & goto :eof )
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File "%~dp0override.ps1"
