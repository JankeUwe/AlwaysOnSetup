# AlwaysOnSetup

PowerShell WinForms-Tool zur vollautomatischen Konfiguration von SQL Server AlwaysOn Availability Groups — entwickelt von [dtcSoftware](https://www.powershelldba.de) (Uwe Janke).

## Übersicht

`AlwaysOnSetup.ps1` ist eine grafische PowerShell-Anwendung (WinForms) die einen bestehenden Windows Server Failover Cluster (WSFC) automatisch einliest und AlwaysOn Availability Groups vollständig konfiguriert — bis zu 3 Nodes.

**Getestet auf:** Windows Server 2022 / SQL Server 2022

## Features

- **Automatisches Cluster-Einlesen**: Liest Cluster- und SQL Server-Informationen automatisch ein und zeigt diese im PropertyGrid an
- **Kerberos/SQL-Auth-Fallback**: Bevorzugt Windows-Auth (Kerberos) — bei fehlenden SPNs automatischer Fallback auf temporäres SQL-Login
- **Temporäres Login-Management**: Erstellt zufälliges SQL-Login, zeigt T-SQL-Block zur manuellen Ausführung an, entfernt Login nach Abschluss automatisch
- **WSFC-Cleanup**: Entfernt verwaiste WSFC-Gruppen-Einträge
- **SPN-Prüfung**: Generiert AD-Team-Anforderungsdatei mit benötigten `setspn`-Befehlen
- **Cluster-Settings-Backup**: Sichert Cluster-Einstellungen vor jeder Änderung
- **Backup-Präferenz**: Konfigurierbar (Primary / Secondary / PreferSecondary / None)
- **Minimaler dbaTools-Einsatz**: Nur `Invoke-DbaQuery` und `Connect-DbaInstance`

## Voraussetzungen

| Anforderung | Mindestversion |
|-------------|---------------|
| Windows Server | 2022 |
| SQL Server | 2022 (Enterprise oder Standard) |
| PowerShell | 5.1 |
| Windows Server Failover Cluster | muss bereits existieren |

**Module** (werden automatisch geladen/installiert):
- `FailoverClusters` (RSAT-Clustering-PowerShell)
- `dbaTools` >= 2.0

## Verwendung

```powershell
# Als lokaler Administrator auf einem Cluster-Node ausführen
.\AlwaysOnSetup.ps1
```

> **Empfehlung**: SPNs vor dem Setup setzen — das spart den manuellen Bestätigungsschritt.  
> Das Script zeigt unter Schritt 9 (SPN-Prüfung) die benötigten `setspn`-Befehle an.

## Ablauf

1. Script erkennt WSFC-Cluster automatisch
2. SQL Server Instanzen auf allen Nodes werden ermittelt
3. Konfigurationsparameter im PropertyGrid anpassen
4. Kerberos-Verbindung zu allen Nodes wird getestet — bei Fehler: SQL-Fallback mit Anzeige des T-SQL-Blocks
5. Nach Bestätigung: vollautomatische AG-Konfiguration
6. Temporäres Login wird entfernt

## Dateien

| Datei | Inhalt |
|-------|--------|
| `AlwaysOnSetup.ps1` | Hauptscript (WinForms GUI + Automatisierungslogik) |
| `AlwaysOn_Doku.html` | Technische Dokumentation |
| `AlwaysOn_Handbuch.docx` | Benutzerhandbuch |

## Version

- **1.0.0** — 2026-04-27 — Erstveröffentlichung

## Mehr Informationen

- Website: [www.powershelldba.de](https://www.powershelldba.de)
- Entwickler: Uwe Janke, Senior IT-Spezialist / SQL Server DBA
