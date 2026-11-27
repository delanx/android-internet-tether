@echo off
rem Double-click this file to start. It opens the Phone Internet menu.
title Phone Internet over USB
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Phone-Internet.ps1"
if errorlevel 1 (
  echo.
  echo The script ended with an error. Read the message above.
  pause
)
