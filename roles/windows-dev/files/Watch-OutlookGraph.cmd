@echo off
REM Shim: run Watch-OutlookGraph.ps1 from LocalAppData without typing the full path.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\Watch-OutlookGraph\Watch-OutlookGraph.ps1" %*
