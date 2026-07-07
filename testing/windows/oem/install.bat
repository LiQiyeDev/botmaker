@echo off
:: dockurr/windows OEM hook: this folder is copied to C:\OEM in the guest and this
:: file runs once (as SYSTEM) right after Windows finishes installing. It hands off to
:: install.ps1, which installs BotMaker Studio (a local .msi here if present, else the
:: latest Windows release from GitHub). Output is logged next to the script.
::
:: To (re)install on an already-provisioned VM, run this file manually from C:\OEM.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" >> "%~dp0install.log" 2>&1
