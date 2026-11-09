@echo off
title Work Orders Server
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
