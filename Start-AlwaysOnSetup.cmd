@echo off
:: ============================================================
:: AlwaysOnSetup - Starter
:: ============================================================
:: Installiert das Tool einmalig nach C:\ProgramData\AlwaysOnSetup
:: und startet es dann als Administrator (UAC).
::
:: Warum ProgramData?
::   - Standard Windows-Pfad fuer Anwendungsdaten (kein Temp)
::   - Nach UAC-Elevation zuverlaessig erreichbar
::   - Nicht von Cleanup-Scripts betroffen
::   - AppLocker / AV unbedenklich
::
:: Ausfuehren: Doppelklick vom Share genuegt.
:: Kein manuelles Kopieren durch den Admin noetig.
:: ============================================================
setlocal EnableDelayedExpansion

set "SRCDIR=%~dp0"
set "LOCALDIR=%ProgramData%\AlwaysOnSetup"
set "LOCALPS=%LOCALDIR%\AlwaysOnSetup.ps1"

echo.
echo  AlwaysOnSetup - Vorbereitung
echo  ============================================================
echo  Quelle : %SRCDIR%
echo  Ziel   : %LOCALDIR%
echo.

:: Zielverzeichnis anlegen falls nicht vorhanden
if not exist "%LOCALDIR%" (
    mkdir "%LOCALDIR%"
    if errorlevel 1 (
        echo  FEHLER: Verzeichnis konnte nicht angelegt werden: %LOCALDIR%
        echo  Bitte Script als Administrator ausfuehren.
        pause
        exit /b 1
    )
)

:: Alle Dateien kopieren (ueberschreibt vorhandene - immer aktuelle Version)
xcopy /Y /Q /E "%SRCDIR%." "%LOCALDIR%\" >nul 2>&1
if errorlevel 1 (
    echo  FEHLER: Kopieren fehlgeschlagen.
    echo  Pruefen: Lesezugriff auf Quelle, Schreibzugriff auf Ziel.
    pause
    exit /b 1
)

echo  Dateien bereit - starte als Administrator ...
echo.

:: PowerShell elevated starten
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%LOCALPS%""' -Verb RunAs"

endlocal
