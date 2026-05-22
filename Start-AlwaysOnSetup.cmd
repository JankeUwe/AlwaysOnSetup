@echo off
:: ============================================================
:: AlwaysOnSetup - Starter
:: Startet PowerShell als Administrator und ruft das Setup-Tool auf.
:: Doppelklick genuegt - UAC-Abfrage erscheint automatisch.
:: ============================================================
setlocal

set "PSSCRIPT=%~dp0AlwaysOnSetup.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process powershell.exe ^
        -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%PSSCRIPT%""' ^
        -Verb RunAs"

endlocal
