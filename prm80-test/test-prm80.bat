@echo off
rem Test der Hamlib-Korrekturen fuer den PRM80 - startet test-prm80.ps1
rem Die PRM80-Software vorher schliessen (COM-Port).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-prm80.ps1" %*
echo.
pause
