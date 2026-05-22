@echo off
:: ============================================================
:: AlwaysOnSetup - Starter
:: ============================================================
:: Kopiert das Tool zunaechst lokal (C:\Windows\Temp\AlwaysOnSetup)
:: und startet es dann als Administrator (UAC).
::
:: Grund: Nach UAC-Elevation sind Netzlaufwerke und UNC-Shares
:: im erhobenen Prozess nicht mehr zuverlaessig erreichbar.
:: Das lokale Kopieren loest dieses Problem automatisch.
::
:: Ausfuehren: Doppelklick genuegt - kein manuelles Kopieren noetig.
:: ============================================================
setlocal EnableDelayedExpansion

set "SRCDIR=%~dp0"
set "LOCALDIR=%SystemRoot%\Temp\AlwaysOnSetup"
set "LOCALPS=%LOCALDIR%\AlwaysOnSetup.ps1"

echo.
echo  AlwaysOnSetup - Vorbereitung ...
echo  Quelle : %SRCDIR%
echo  Ziel   : %LOCALDIR%
echo.

:: Zielverzeichnis anlegen falls nicht vorhanden
if not exist "%LOCALDIR%" (
    mkdir "%LOCALDIR%"
    if errorlevel 1 (
        echo  FEHLER: Verzeichnis konnte nicht angelegt werden: %LOCALDIR%
        pause
        exit /b 1
    )
)

:: Alle Dateien kopieren (ueberschreibt vorhandene)
xcopy /Y /Q /E "%SRCDIR%." "%LOCALDIR%\" >nul 2>&1
if errorlevel 1 (
    echo  FEHLER: Kopieren fehlgeschlagen.
    pause
    exit /b 1
)

echo  Dateien kopiert - starte als Administrator ...
echo.

:: PowerShell-Script als Administrator starten
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%LOCALPS%""' -Verb RunAs"

endlocal
