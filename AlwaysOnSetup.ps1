#Requires -RunAsAdministrator
<#
.SYNOPSIS
    SQL Server AlwaysOn Availability Group Setup Tool
.DESCRIPTION
    WinForms-Anwendung zum vollautomatischen Konfigurieren von SQL Server AlwaysOn
    Availability Groups auf einem bestehenden Windows Server Failover Cluster (max. 3 Nodes).
    Liest Cluster- und SQL-Informationen automatisch ein, zeigt diese im PropertyGrid an
    und führt nach Bestätigung alle Konfigurationsschritte durch.

    Verbindungsstrategie:
      - Windows-Auth (Kerberos) wird bevorzugt auf allen Nodes getestet.
      - Schlägt Kerberos auf einem Node fehl (fehlende SPNs), generiert das Script
        ein temporäres SQL-Login mit zufälligem Passwort, zeigt den T-SQL-Block
        zur manuellen Ausführung an und wartet auf Bestätigung ("Weiter"-Button).
      - Das temporäre Login wird nach Abschluss automatisch entfernt.

    EMPFEHLUNG: SPNs vor dem Setup setzen – spart den manuellen Schritt!
    Siehe Schritt 9 (SPN-Prüfung) für die benötigten setspn-Befehle.

.NOTES
    Version  : 1.0.0
    Datum    : 2026-04-27
    Autor    : DBA-Team
    Getestet : Windows Server 2022, SQL Server 2022

    Voraussetzungen:
      - Windows Server 2022 oder neuer
      - SQL Server 2022 oder neuer (Enterprise/Standard)
      - Bestehender Windows Server Failover Cluster (WSFC)
      - Ausführung als lokaler Administrator auf einem Cluster-Node
      - PowerShell 5.1 oder neuer
      - Netzwerkzugang zu allen Cluster-Nodes

    Module (werden automatisch geladen/installiert):
      - FailoverClusters (RSAT-Clustering-PowerShell)
      - dbaTools >= 2.0 (nur Invoke-DbaQuery / Connect-DbaInstance)

    Changelog:
      1.0.0  2026-04-27  Erstveröffentlichung
               - Automatisches Einlesen von Cluster- und SQL-Informationen
               - PropertyGrid zur Konfiguration der AG-Parameter
               - Automatische Kerberos/SQL-Auth-Erkennung mit Fallback
               - WSFC-Gruppe Cleanup bei verwaisten Einträgen
               - SPN-Prüfung und AD-Team Anforderungsdatei
               - Cluster-Settings Sicherung vor jeder Änderung
               - Backup-Präferenz (Primary/Secondary/PreferSecondary/None)
               - Minimaler dbaTools-Einsatz (nur Invoke-DbaQuery, Connect-DbaInstance)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Script-Version (für Log-Ausgabe)
# ---------------------------------------------------------------------------
$script:Version = '1.0.0'

# ---------------------------------------------------------------------------
# Assemblies laden
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.DirectoryServices
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Sprache und String-Tabelle
# ---------------------------------------------------------------------------
$script:CurrentLang = 'DE'

$script:LangStrings = @{
    DE = @{
        # Form and Window Titles
        'FormTitle'                          = 'SQL Server AlwaysOn Setup Tool'
        'TabConfig'                          = 'Konfiguration'

        # Toolbar Buttons
        'BtnReload'                          = '🔄  Neu einlesen'
        'BtnReloadTooltip'                   = 'Cluster- und SQL-Informationen erneut einlesen'
        'BtnValidate'                        = '✔  Konto prüfen'
        'BtnValidateTooltip'                 = 'Service-Konto gegen Active Directory prüfen'

        # Panel Labels
        'LblConfig'                          = 'AlwaysOn-Konfiguration'
        'LblLog'                             = 'Protokoll'

        # Main Buttons
        'BtnOK'                              = 'OK  –  Konfiguration starten'
        'BtnClose'                           = 'Schließen'
        'BtnContinue'                        = '▶  Weiter'
        'BtnClearLog'                        = 'Protokoll leeren'
        'BtnSaveLog'                         = '💾 Protokoll speichern'

        # Status Messages
        'StatusReady'                        = 'Bereit.'
        'StatusReadingCluster'               = 'Lese Cluster-Informationen ...'
        'StatusEntering'                     = 'Eingelesen: {0}  –  OK'
        'StatusReadError'                    = 'Fehler beim Einlesen – Details im Protokoll.'
        'StatusADCheck'                      = 'AD-Prüfung: {0} ...'
        'StatusAccountValid'                 = 'Konto ''{0}'' ist gültig.'
        'StatusAccountNotFound'              = 'Konto ''{0}'' NICHT gefunden.'
        'StatusManualLoginRequired'          = 'Bitte SQL-Login anlegen und dann "Weiter" klicken.'
        'StatusVerifying'                    = 'Verbindung wird geprüft ...'
        'StatusSQLAuthFailed'                = 'SQL-Login nicht auf allen Nodes erreichbar – bitte prüfen.'
        'StatusConfigRunning'                = 'Konfiguration läuft ...'
        'StatusServiceAccountChanged'        = 'Service-Konto geändert – bitte AD-Prüfung ausführen.'
        'StatusRestartRequired'              = 'Session-Neustart erforderlich!'
        'StatusModuleError'                  = 'FEHLER: Erforderliche Module nicht verfügbar – Details im Protokoll.'

        # Section Headers (Write-RtfSection)
        'SectionModuleReqs'                  = 'Modul-Voraussetzungen'
        'SectionClusterSQL'                  = 'Cluster- und SQL-Informationen einlesen'
        'SectionManualAction'                = 'Manuelle Aktion erforderlich: SQL-Login anlegen'
        'SectionMixedMode'                   = 'Mixed-Mode Authentifizierung prüfen'
        'SectionStep1'                       = 'Schritt 1: SQL-Service-Konto prüfen'
        'SectionStep2'                       = 'Schritt 2: HADR auf allen Nodes aktivieren'
        'SectionStep3'                       = 'Schritt 3: Endpoint ''HADR_Endpoint'' (Port {0}) konfigurieren'
        'SectionStep4'                       = 'Schritt 4: Endpoint CONNECT-Berechtigung setzen'
        'SectionStep5'                       = 'Schritt 5: Testdatenbank ''{0}'' erstellen'
        'SectionStep6'                       = 'Schritt 6: Availability Group ''{0}'' erstellen'
        'SectionStep7'                       = 'Schritt 7: AG-Listener ''{}'' konfigurieren'
        'SectionStep8'                       = 'Schritt 8: AG-Sync Job anlegen'
        'SectionStep9'                       = 'Schritt 9: Konfiguration abgeschlossen – Status'
        'SectionStep10'                      = 'Schritt 10: SPN-Prüfung'
        'SectionSPNCommands'                 = 'SPN-Befehle – Ausführung durch AD-Team erforderlich'
        'SectionCleanup'                     = 'Cleanup: Temporäres SQL-Login entfernen'

        # Info Messages
        'InfoAlreadyLoaded'                  = '[{0}] Bereits geladen (v{1}) – kein Nachladen.'
        'InfoImportSuccess'                  = '[{0}] Import erfolgreich (v{1}).'
        'InfoImportFailed'                   = '[{0}] Import fehlgeschlagen: {0}'
        'InfoNotFound'                       = '[{0}] Nicht gefunden – Installation wird gestartet ...'
        'InfoInstallSuccess'                 = '[{0}] Installation und Import erfolgreich (v{1}).'
        'InfoInstallFailed'                  = '[{0}] FEHLER bei Installation: {0}'
        'InfoFailoverClusterFound'           = '[FailoverClusters] Import erfolgreich.'
        'InfoFailoverClusterRSAT'            = '[FailoverClusters] RSAT-Feature installiert und Modul geladen.'
        'InfoINILoaded'                      = 'INI geladen: {0}'
        'InfoClusterFound'                   = 'Cluster gefunden: {0}'
        'InfoNodes'                          = 'Nodes: {0}'
        'InfoListenerPort'                   = '  Listener-Port aus ProbePort gelesen: {0}'
        'InfoListenerPortNetRes'             = '  Listener-Port aus Netzwerkname-Ressource gelesen: {0}'
        'InfoListenerInfo'                   = 'Listener-Name: {0}  |  IP: {1}  |  Port: {2}'
        'InfoNodeService'                    = '{0}  –  Dienst: {1}  |  Konto: {2}  |  AlwaysOn: {3}'
        'InfoClusterGroups'                  = 'Cluster-Rollen: {0}'
        'InfoReadComplete'                   = 'Einlesen abgeschlossen.'
        'InfoWindowsAuthOK'                  = '  Windows-Auth ''{0}'': OK'
        'InfoAuthSuccess'                    = 'Authentifizierung: Windows-Auth (Kerberos/NTLM) auf allen Nodes OK'
        'InfoAccountFound'                   = 'Konto gefunden: {0}  ({1})'
        'InfoADCheckFor'                     = 'AD-Prüfung für Konto ''{0}'' ...'
        'InfoServicesChanged'                = '  {0}: Konto wird von ''{1}'' auf ''{2}'' geändert ...'
        'InfoServiceUpdated'                 = '  {0}: Service-Konto erfolgreich aktualisiert.'
        'InfoHADRActivating'                 = '  {0}: HADR wird aktiviert ...'
        'InfoSQLReady'                       = '  {0}: Warte auf SQL Server Bereitschaft ...'
        'InfoHADRActive'                     = '  {0}: HADR aktiviert – SQL Server bereit.'
        'InfoHADRAlreadyActive'              = '  {0}: HADR bereits aktiv – übersprungen.'
        'InfoEndpointCreating'               = '  {0}: Endpoint wird erstellt ...'
        'InfoEndpointExists'                 = '  {0}: Endpoint bereits vorhanden – übersprungen.'
        'InfoLoginCreating'                  = '  {0}: Login ''{1}'' wird angelegt ...'
        'InfoLoginExists'                    = '  {0}: Login ''{1}'' bereits vorhanden – übersprungen.'
        'InfoDomainUserLogin'                = '  {0}: Login angelegt (DOMAIN\User).'
        'InfoUPNFormat'                      = '  {0}: Versuche UPN-Format ''{1}'' ...'
        'InfoUPNLoginSuccess'                = '  {0}: Login angelegt (UPN-Format).'
        'InfoCertAuthSetup'                  = '  {0}: Endpoint wird auf Zertifikat-Authentifizierung umgestellt ...'
        'InfoConnectGranted'                 = '  {0}: CONNECT-Berechtigung gesetzt für ''{1}''.'
        'InfoDatabaseCreating'               = '  Datenbank wird angelegt ...'
        'InfoDatabaseExists'                 = '  Datenbank ''{0}'' bereits vorhanden.'
        'InfoRecoveryFull'                   = '  Recovery-Modell wird auf FULL gesetzt ...'
        'InfoRecoveryFullSet'                = '  Recovery-Modell: FULL'
        'InfoBackupCreating'                 = '  Initiales Full-Backup wird erstellt ...'
        'InfoBackupSuccess'                  = '  Backup erfolgreich: {0}'
        'InfoAGCreating'                     = '  AG wird per T-SQL angelegt ...'
        'InfoSecondaryJoining'               = '  {0}: AG beitreten ...'
        'InfoFailoverModeSet'                = '  {0}: Failover-Modus auf ''{1}'' setzen ...'
        'InfoListenerCreating'               = '  Listener wird angelegt ...'
        'InfoListenerNotVisible'             = '  AG noch nicht sichtbar – warte 10s (Versuch {0}/6) ...'
        'InfoJobName'                        = '  Job-Name: ''{0}''{1}'
        'InfoJobUpdate'                      = '  {0}: Job ''{1}'' bereits vorhanden – wird aktualisiert.'
        'InfoJobSuccess'                     = '  {0}: Job ''{1}'' angelegt (täglich 02:00).'
        'InfoSPNCheck'                       = '  Prüfe SPNs für Konto: {0}'
        'InfoSPNFound'                       = '  Gefundene MSSQLSvc-SPNs: {0}'
        'InfoSPNOK'                          = '  OK  {0}'
        'InfoAllSPNsValid'                   = '  Alle erwarteten SPNs sind registriert – kein SSPI-Problem zu erwarten.'
        'InfoTempLoginRemoving'              = '  Temporäres Login ''{0}'' wird entfernt ...'
        'InfoLogfileSaved'                   = 'Logfile gespeichert: {0}'
        'InfoClusterSettingsSaved'           = 'Cluster-Settings gesichert: {0}'
        'InfoADRequestSaved'                 = '  AD-Team Anforderungsdatei gespeichert: {0}'
        'InfoModuleVersion'                  = '{0} v{1}  – OK'
        'InfoProcessing'                     = 'Dieser Node ({0}) ist nicht Primary ({1}) - kein Sync nötig.'
        'InfoSyncTo'                         = 'Sync von {0} nach {1} ...'
        'InfoMixedModeActive'                = '  {0}: Mixed-Mode bereits aktiv (LoginMode=2) – OK.'
        'InfoMixedModeActivating'            = '  {0}: Dienst-Neustart (Mixed-Mode Aktivierung) ...'
        'InfoMixedModeActivated'             = '  {0}: Mixed-Mode aktiviert, SQL Server bereit.'
        'InfoCertCreating'                   = '  {0}: Erstelle Zertifikat ''{1}'' ...'
        'InfoCertCreated'                    = '  {0}: Zertifikat erstellt und exportiert nach ''{1}''.'
        'InfoCertAuthConfigured'             = '  {0}: Endpoint auf Zertifikat-Auth umgestellt.'
        'InfoCertImported'                   = '  {0}: Zertifikat von ''{1}'' importiert, CONNECT gesetzt.'
        'InfoCertAuthComplete'               = '  Zertifikat-basierte Endpoint-Authentifizierung auf allen Nodes konfiguriert.'
        'InfoConfigStarting'                 = 'Konfiguration startet  –  Primary: {0}'
        'InfoLoginOnAllNodes'                = '  Bitte auf ALLEN Nodes folgendes T-SQL als sysadmin ausführen:'
        'InfoLoginManually'                  = '  (z.B. per SSMS lokal auf dem jeweiligen Node oder per RDP)'
        'InfoLoginContinueAfter'             = '  Nach Ausführung auf allen Nodes: Klick auf ''Weiter'' um fortzufahren.'
        'InfoLoginCredentials'               = '  Login: {0}   Passwort: {1}'
        'InfoUnableToCreate'                 = '  Weder Install-WindowsFeature noch Add-WindowsCapability verfügbar.'
        'InfoAGStatusOK'                     = 'AG ''{0}''  |  Sync: {1}  |  Primary: {2}'
        'InfoReplicaStatus'                  = '  Replica: {0}  |  Rolle: {1}  |  Sync: {2}'
        'InfoFinished'                       = 'Fertig.'
        'InfoSQLAuthSuccess'                 = '  SQL-Auth ''{0}'': OK'
        'InfoSQLAuthOnAllSuccess'            = '  SQL-Auth auf allen Nodes erfolgreich – Konfiguration wird fortgesetzt.'
        'InfoNodesToChange'                  = '  Folgende Nodes sind per Windows-Auth (Kerberos) nicht erreichbar:'
        'InfoEmptyLine'                      = ''
        'InfoUPNConverted'                   = '  UPN ''{0}'' konvertiert: ''{1}'' (NetBIOS: {2})'
        'InfoNoAccountChange'                = '  Service-Konto ''{0}'' entspricht dem bereits eingetragenen Konto – kein Update erforderlich.'
        'InfoDomainUserNotResolvable'        = '  {0}: DOMAIN\User nicht auflösbar (''{1}'')'
        'InfoUPNNotResolvable'               = '  {0}: UPN-Format ebenfalls nicht auflösbar – Cross-Domain AD-Lookup schlägt fehl.'
        'InfoRegistryCleanupSuccess'         = '  Registry HadrAgNameToldMap auf ''{0}'' bereinigt.'
        'InfoAgStatus'                       = 'AG ''{0}'' auf Primary angelegt.'
        'InfoSecondarySynced'                = '  {0}: Beigetreten, Autoseed genehmigt.'
        'InfoListenerExists'                 = '  Listener bereits vorhanden – übersprungen.'

        # Warning Messages
        'WarnClusterNotReachable'            = 'Cluster nicht erreichbar: {0}'
        'WarnNodesReadFailed'                = 'Nodes konnten nicht gelesen werden: {0}'
        'WarnListenerIncomplete'             = 'Listener-Informationen unvollständig: {0}'
        'WarnListenerPortFallback'           = '  Listener-Port nicht im Cluster hinterlegt – Fallback: {0}'
        'WarnNoSQLService'                   = '{0}: Kein SQL-Engine-Dienst gefunden'
        'WarnSQLInfoReadFailed'              = '{0}: SQL-Info nicht lesbar – {0}'
        'WarnClusterSettingsFailed'          = 'Cluster-Settings konnten nicht gesichert werden: {0}'
        'WarnListenerListFailed'             = 'Listener-Informationen unvollständig: {0}'
        'WarnNetBIOSUnresolvable'            = '  NetBIOS-Name nicht ermittelbar – Fallback: ''{0}'' (aus UPN-Suffix, möglicherweise falsch)'
        'WarnMixedModeNotActive'             = '  {0}: Mixed-Mode nicht aktiv (LoginMode={1}) – wird aktiviert ...'
        'WarnMixedModeCheckFailed'           = '  {0}: Mixed-Mode-Prüfung fehlgeschlagen – {0}'
        'WarnMixedModeManual'                = '  {0}: Bitte Mixed-Mode manuell aktivieren: Server Properties → Security → SQL Server and Windows Authentication mode'
        'WarnNoServiceAccount'               = '  Kein Service-Konto angegeben – Schritt übersprungen.'
        'WarnPasswordMissing'                = '  Neues Konto ''{0}'' angegeben, aber kein Passwort – Schritt übersprungen.'
        'WarnOrphanedGroup'                  = '  Verwaiste WSFC-Gruppe ''{0}'' gefunden – wird bereinigt ...'
        'WarnGroupCleanupFailed'             = '  WSFC-Gruppe konnte nicht gelöscht werden: {0}'
        'WarnRegistryCleanupFailed'          = '  Registry auf ''{0}'' nicht bereinigt: {0}'
        'WarnAGExists'                       = '  AG ''{0}'' bereits vorhanden – Schritt übersprungen.'
        'WarnModifyReplicaFailed'            = '  {0}: MODIFY REPLICA fehlgeschlagen (nicht kritisch) – {0}'
        'WarnModifyReplicaError'             = '  {0}: MODIFY REPLICA Fehler (nicht kritisch) – {0}'
        'WarnListenerIPMissing'              = '  Listener-IP oder -Port fehlen – übersprungen.'
        'WarnAGNotVisible'                   = '  AG nach 60s noch nicht sichtbar – Listener-Schritt übersprungen.'
        'WarnStatusQueryFailed'              = 'Status-Abfrage fehlgeschlagen – {0}'
        'WarnSecondsNotSpelling'             = '  {0}: AG beitreten ...'
        'WarnNoServiceAccountKnown'          = '  Kein Dienstkonto bekannt – SPN-Prüfung übersprungen.'
        'WarnSPNMissing'                     = '  FEHLT  {0}'
        'WarnSPNCount'                       = '  {0} SPN(s) fehlen. Ohne korrekte SPNs schlägt die'
        'WarnSPNAuth'                        = '  Windows-Authentifizierung mit SSPI-Kontextfehler fehl.'
        'WarnAdTeamExecution'                = '  Folgende Befehle müssen durch einen Domänen-Admin ausgeführt werden:'
        'WarnAGSeeding'                      = 'AG-Status noch nicht abfragbar – Seeding läuft möglicherweise noch.'
        'WarnConfirmPassword'                = "Das Service-Konto wurde auf ''{0}'' geändert,`naber es wurde kein Passwort eingegeben. Trotzdem fortfahren?"
        'WarnLoginRemovedFailed'             = '    ''{0}'': Login konnte nicht entfernt werden – bitte manuell prüfen: {0}'
        'WarnModuleRestartNeeded'            = 'Ein oder mehrere Module wurden neu installiert.`nDie aktuelle PowerShell-Session muss neu gestartet werden,`ndamit alle Module korrekt geladen werden.`n`nBitte das Skript nach dem Neustart erneut ausführen.'
        'WarnAccountValidationFailed'        = 'Service-Konto geändert auf ''{0}'' – AD-Prüfung empfohlen.'
        'WarnNodesToImprovement'             = '  Folgende Nodes sind per Windows-Auth (Kerberos) nicht erreichbar:'
        'WarnWindowsAuthFailed'              = '  Windows-Auth ''{0}'': fehlgeschlagen – {0}'
        'WarnSecondarySecondJoin'            = '  {0}: Beitritt fehlgeschlagen – {0}'
        'WarnSQLAuthFailedNode'              = '  SQL-Auth ''{0}'': fehlgeschlagen – {0}'
        'WarnLoginRetry'                     = '  Bitte Login prüfen und erneut auf ''Weiter'' klicken.'
        'WarnSetupComplete'                  = 'Nach Ausführung auf allen Nodes: Klick auf ''Weiter'' um fortzufahren.'
        'WarnLognotWritable'                 = 'Logfile konnte nicht geschrieben werden: {0}'

        # Error Messages
        'ErrorClusterUnreachable'            = 'Cluster nicht erreichbar: {0}'
        'ErrorAccountNotInAD'                = 'Konto nicht im AD gefunden.'
        'ErrorADCheckFailed'                 = 'AD-Prüfung fehlgeschlagen: {0}'
        'ErrorWMIChange'                     = '  {0}: WMI Change() ReturnValue={1}'
        'ErrorAccountUpdateFailed'           = '  {0}: Fehler beim Konto-Update – {0}'
        'ErrorHADRFailed'                    = '  {0}: HADR-Aktivierung fehlgeschlagen – {0}'
        'ErrorSQLNotReady'                   = '  {0}: SQL Server nach 2 Minuten noch nicht erreichbar.'
        'ErrorEndpointFailed'                = '  {0}: Endpoint-Fehler – {0}'
        'ErrorStep4Failed'                   = '  {0}: Fehler in Schritt 4 – {0}'
        'ErrorDatabaseFailed'                = '  Datenbankvorb. fehlgeschlagen – {0}'
        'ErrorAGCreationFailed'              = '  AG-Erstellung fehlgeschlagen – {0}'
        'ErrorListenerFailed'                = '  Listener-Konfiguration fehlgeschlagen – {0}'
        'ErrorJobFailed'                     = '  AG-Sync Job fehlgeschlagen – {0}'
        'ErrorJobCreationFailed'             = '  {0}: Job-Anlage fehlgeschlagen – {0}'
        'ErrorSPNCheckFailed'                = '  SPN-Prüfung fehlgeschlagen: {0}'
        'ErrorADTeamFileFailed'              = '  AD-Team Datei konnte nicht geschrieben werden: {0}'
        'ErrorCertAuthFailed'                = '  {0}: Zertifikat-Setup fehlgeschlagen – {0}'
        'ErrorManualRequired'                = '  MANUELL ERFORDERLICH: CREATE LOGIN + GRANT CONNECT ON ENDPOINT durch AD-Team'
        'ErrorConfigStep1'                   = '  {0}: Fehler beim Konto-Update – {0}'
        'ErrorStep4General'                  = '  {0}: Fehler in Schritt 4 – {0}'
        'ErrorListenerCreationFailed'        = '  Listener-Anlage fehlgeschlagen: {0}'

        # Dialog/MessageBox Titles
        'MsgTitleAccountCheck'               = 'Konto prüfen'
        'MsgTitleError'                      = 'Fehler'
        'MsgTitleConfirm'                    = 'Bestätigung'
        'MsgTitleADCheck'                    = 'AD-Prüfung'
        'MsgTitlePasswordMissing'            = 'Passwort fehlt'
        'MsgTitleModuleInstallFailed'        = 'Modul-Installation fehlgeschlagen'
        'MsgTitleRestartRequired'            = 'Neustart erforderlich'

        # Dialog/MessageBox Content
        'MsgNoAccount'                       = 'Bitte zuerst ein Service-Konto im PropertyGrid eingeben.'
        'MsgAccountFound'                    = "Konto gefunden:`nAnzeigename: {0}`nUPN: {1}"
        'MsgAccountNotFound'                 = "Konto nicht gefunden:`n{0}"
        'MsgAGNameRequired'                  = 'Bitte einen AG-Namen eingeben.'
        'MsgListenerNameRequired'            = 'Bitte einen Listener-Namen eingeben. Keine Cluster-Rolle gefunden - manuell eintragen!'
        'BtnReset'                           = 'Zuruecksetzen'
        'BtnResetTooltip'                    = 'AG-Name und Listener-Name auf erkannte Werte zuruecksetzen'
        'InfoResetDone'                      = 'AG-Name und Listener-Name zurueckgesetzt.'
        'InfoIPCheckOK'                      = 'IP-Adresse {0} aufgeloest: {1}'
        'WarnIPCheckFail'                    = 'IP-Adresse {0} konnte nicht aufgeloest werden - bitte pruefen!'
        'MsgConfigStarting'                  = "AlwaysOn-Konfiguration wird gestartet:`n`n" +
                                              "  AG-Name    : {0}`n" +
                                              "  Primary    : {1}`n" +
                                              "  Endpoint   : Port {2}`n" +
                                              "  Failover   : {3}`n" +
                                              "  Datenbank  : {4}`n" +
                                              "{5}`n`n" +
                                              'Jetzt ausführen?'
        'MsgAccountChangeInfo'               = '  Konto      : ÄNDERUNG  ''{0}''  →  ''{1}'''
        'MsgAccountNoChange'                 = '  Konto      : unverändert ({0})'
    }

    EN = @{
        # Form and Window Titles
        'FormTitle'                          = 'SQL Server AlwaysOn Setup Tool'
        'TabConfig'                          = 'Configuration'

        # Toolbar Buttons
        'BtnReload'                          = '🔄  Reload'
        'BtnReloadTooltip'                   = 'Re-read cluster and SQL information'
        'BtnValidate'                        = '✔  Validate Account'
        'BtnValidateTooltip'                 = 'Validate service account against Active Directory'

        # Panel Labels
        'LblConfig'                          = 'AlwaysOn Configuration'
        'LblLog'                             = 'Log'

        # Main Buttons
        'BtnOK'                              = 'OK  –  Start Configuration'
        'BtnClose'                           = 'Close'
        'BtnContinue'                        = '▶  Continue'
        'BtnClearLog'                        = 'Clear Log'
        'BtnSaveLog'                         = '💾 Save Log'

        # Status Messages
        'StatusReady'                        = 'Ready.'
        'StatusReadingCluster'               = 'Reading cluster information ...'
        'StatusEntering'                     = 'Read: {0}  –  OK'
        'StatusReadError'                    = 'Error reading configuration – see log for details.'
        'StatusADCheck'                      = 'AD check: {0} ...'
        'StatusAccountValid'                 = 'Account ''{0}'' is valid.'
        'StatusAccountNotFound'              = 'Account ''{0}'' NOT found.'
        'StatusManualLoginRequired'          = 'Please create SQL login and then click "Continue".'
        'StatusVerifying'                    = 'Verifying connection ...'
        'StatusSQLAuthFailed'                = 'SQL login not accessible on all nodes – please check.'
        'StatusConfigRunning'                = 'Configuration running ...'
        'StatusServiceAccountChanged'        = 'Service account changed – AD validation recommended.'
        'StatusRestartRequired'              = 'Session restart required!'
        'StatusModuleError'                  = 'ERROR: Required modules unavailable – see log for details.'

        # Section Headers (Write-RtfSection)
        'SectionModuleReqs'                  = 'Module Requirements'
        'SectionClusterSQL'                  = 'Reading cluster and SQL information'
        'SectionManualAction'                = 'Manual action required: Create SQL login'
        'SectionMixedMode'                   = 'Checking Mixed-Mode authentication'
        'SectionStep1'                       = 'Step 1: Validate SQL service account'
        'SectionStep2'                       = 'Step 2: Activate HADR on all nodes'
        'SectionStep3'                       = 'Step 3: Configure endpoint ''HADR_Endpoint'' (Port {0})'
        'SectionStep4'                       = 'Step 4: Set endpoint CONNECT permission'
        'SectionStep5'                       = 'Step 5: Create test database ''{0}'''
        'SectionStep6'                       = 'Step 6: Create Availability Group ''{0}'''
        'SectionStep7'                       = 'Step 7: Configure AG listener ''{}'''
        'SectionStep8'                       = 'Step 8: Create AG sync job'
        'SectionStep9'                       = 'Step 9: Configuration complete – Status'
        'SectionStep10'                      = 'Step 10: SPN validation'
        'SectionSPNCommands'                 = 'SPN commands – execution required by AD team'
        'SectionCleanup'                     = 'Cleanup: Remove temporary SQL login'

        # Info Messages
        'InfoAlreadyLoaded'                  = '[{0}] Already loaded (v{1}) – no reload.'
        'InfoImportSuccess'                  = '[{0}] Import successful (v{1}).'
        'InfoImportFailed'                   = '[{0}] Import failed: {0}'
        'InfoNotFound'                       = '[{0}] Not found – starting installation ...'
        'InfoInstallSuccess'                 = '[{0}] Installation and import successful (v{1}).'
        'InfoInstallFailed'                  = '[{0}] ERROR during installation: {0}'
        'InfoFailoverClusterFound'           = '[FailoverClusters] Import successful.'
        'InfoFailoverClusterRSAT'            = '[FailoverClusters] RSAT feature installed and module loaded.'
        'InfoINILoaded'                      = 'INI loaded: {0}'
        'InfoClusterFound'                   = 'Cluster found: {0}'
        'InfoNodes'                          = 'Nodes: {0}'
        'InfoListenerPort'                   = '  Listener port from ProbePort: {0}'
        'InfoListenerPortNetRes'             = '  Listener port from network name resource: {0}'
        'InfoListenerInfo'                   = 'Listener name: {0}  |  IP: {1}  |  Port: {2}'
        'InfoNodeService'                    = '{0}  –  Service: {1}  |  Account: {2}  |  AlwaysOn: {3}'
        'InfoClusterGroups'                  = 'Cluster roles: {0}'
        'InfoReadComplete'                   = 'Read complete.'
        'InfoWindowsAuthOK'                  = '  Windows auth ''{0}'': OK'
        'InfoAuthSuccess'                    = 'Authentication: Windows auth (Kerberos/NTLM) on all nodes OK'
        'InfoAccountFound'                   = 'Account found: {0}  ({1})'
        'InfoADCheckFor'                     = 'AD check for account ''{0}'' ...'
        'InfoServicesChanged'                = '  {0}: Changing account from ''{1}'' to ''{2}'' ...'
        'InfoServiceUpdated'                 = '  {0}: Service account updated successfully.'
        'InfoHADRActivating'                 = '  {0}: Activating HADR ...'
        'InfoSQLReady'                       = '  {0}: Waiting for SQL Server readiness ...'
        'InfoHADRActive'                     = '  {0}: HADR activated – SQL Server ready.'
        'InfoHADRAlreadyActive'              = '  {0}: HADR already active – skipped.'
        'InfoEndpointCreating'               = '  {0}: Creating endpoint ...'
        'InfoEndpointExists'                 = '  {0}: Endpoint already exists – skipped.'
        'InfoLoginCreating'                  = '  {0}: Creating login ''{1}'' ...'
        'InfoLoginExists'                    = '  {0}: Login ''{1}'' already exists – skipped.'
        'InfoDomainUserLogin'                = '  {0}: Login created (DOMAIN\User).'
        'InfoUPNFormat'                      = '  {0}: Trying UPN format ''{1}'' ...'
        'InfoUPNLoginSuccess'                = '  {0}: Login created (UPN format).'
        'InfoCertAuthSetup'                  = '  {0}: Switching endpoint to certificate authentication ...'
        'InfoConnectGranted'                 = '  {0}: CONNECT permission set for ''{1}''.'
        'InfoDatabaseCreating'               = '  Creating database ...'
        'InfoDatabaseExists'                 = '  Database ''{0}'' already exists.'
        'InfoRecoveryFull'                   = '  Setting recovery model to FULL ...'
        'InfoRecoveryFullSet'                = '  Recovery model: FULL'
        'InfoBackupCreating'                 = '  Creating initial full backup ...'
        'InfoBackupSuccess'                  = '  Backup successful: {0}'
        'InfoAGCreating'                     = '  Creating AG via T-SQL ...'
        'InfoSecondaryJoining'               = '  {0}: Joining AG ...'
        'InfoFailoverModeSet'                = '  {0}: Setting failover mode to ''{1}'' ...'
        'InfoListenerCreating'               = '  Creating listener ...'
        'InfoListenerNotVisible'             = '  AG not yet visible – waiting 10s (attempt {0}/6) ...'
        'InfoJobName'                        = '  Job name: ''{0}''{1}'
        'InfoJobUpdate'                      = '  {0}: Job ''{1}'' already exists – updating.'
        'InfoJobSuccess'                     = '  {0}: Job ''{1}'' created (daily at 02:00).'
        'InfoSPNCheck'                       = '  Checking SPNs for account: {0}'
        'InfoSPNFound'                       = '  Found MSSQLSvc SPNs: {0}'
        'InfoSPNOK'                          = '  OK  {0}'
        'InfoAllSPNsValid'                   = '  All expected SPNs registered – no SSPI issues expected.'
        'InfoTempLoginRemoving'              = '  Removing temporary login ''{0}'' ...'
        'InfoLogfileSaved'                   = 'Log saved: {0}'
        'InfoClusterSettingsSaved'           = 'Cluster settings backed up: {0}'
        'InfoADRequestSaved'                 = '  AD team request file saved: {0}'
        'InfoModuleVersion'                  = '{0} v{1}  – OK'
        'InfoProcessing'                     = 'This node ({0}) is not primary ({1}) - no sync needed.'
        'InfoSyncTo'                         = 'Syncing from {0} to {1} ...'
        'InfoMixedModeActive'                = '  {0}: Mixed-Mode already active (LoginMode=2) – OK.'
        'InfoMixedModeActivating'            = '  {0}: Restarting service (Mixed-Mode activation) ...'
        'InfoMixedModeActivated'             = '  {0}: Mixed-Mode activated, SQL Server ready.'
        'InfoCertCreating'                   = '  {0}: Creating certificate ''{1}'' ...'
        'InfoCertCreated'                    = '  {0}: Certificate created and exported to ''{1}''.'
        'InfoCertAuthConfigured'             = '  {0}: Endpoint switched to certificate auth.'
        'InfoCertImported'                   = '  {0}: Certificate from ''{1}'' imported, CONNECT set.'
        'InfoCertAuthComplete'               = '  Certificate-based endpoint authentication configured on all nodes.'
        'InfoConfigStarting'                 = 'Configuration starting  –  Primary: {0}'
        'InfoLoginOnAllNodes'                = '  Please execute the following T-SQL as sysadmin on ALL nodes:'
        'InfoLoginManually'                  = '  (e.g. via SSMS locally on the respective node or via RDP)'
        'InfoLoginContinueAfter'             = '  After execution on all nodes: Click ''Continue'' to proceed.'
        'InfoLoginCredentials'               = '  Login: {0}   Password: {1}'
        'InfoUnableToCreate'                 = '  Neither Install-WindowsFeature nor Add-WindowsCapability available.'
        'InfoAGStatusOK'                     = 'AG ''{0}''  |  Sync: {1}  |  Primary: {2}'
        'InfoReplicaStatus'                  = '  Replica: {0}  |  Role: {1}  |  Sync: {2}'
        'InfoFinished'                       = 'Complete.'
        'InfoSQLAuthSuccess'                 = '  SQL auth ''{0}'': OK'
        'InfoSQLAuthOnAllSuccess'            = '  SQL auth on all nodes successful – configuration continuing.'
        'InfoNodesToChange'                  = '  The following nodes are not accessible via Windows auth (Kerberos):'
        'InfoEmptyLine'                      = ''
        'InfoUPNConverted'                   = '  UPN ''{0}'' converted: ''{1}'' (NetBIOS: {2})'
        'InfoNoAccountChange'                = '  Service account ''{0}'' matches the existing account – no update needed.'
        'InfoDomainUserNotResolvable'        = '  {0}: DOMAIN\User not resolvable (''{1}'')'
        'InfoUPNNotResolvable'               = '  {0}: UPN format also not resolvable – cross-domain AD lookup failed.'
        'InfoRegistryCleanupSuccess'         = '  Registry HadrAgNameToldMap cleaned on ''{0}''.'
        'InfoAgStatus'                       = 'AG ''{0}'' created on primary.'
        'InfoSecondarySynced'                = '  {0}: Joined, autoseed approved.'
        'InfoListenerExists'                 = '  Listener already exists – skipped.'

        # Warning Messages
        'WarnClusterNotReachable'            = 'Cluster not reachable: {0}'
        'WarnNodesReadFailed'                = 'Could not read nodes: {0}'
        'WarnListenerIncomplete'             = 'Listener information incomplete: {0}'
        'WarnListenerPortFallback'           = '  Listener port not in cluster – fallback: {0}'
        'WarnNoSQLService'                   = '{0}: No SQL Engine service found'
        'WarnSQLInfoReadFailed'              = '{0}: Could not read SQL info – {0}'
        'WarnClusterSettingsFailed'          = 'Could not back up cluster settings: {0}'
        'WarnListenerListFailed'             = 'Listener information incomplete: {0}'
        'WarnNetBIOSUnresolvable'            = '  NetBIOS name not resolvable – fallback: ''{0}'' (from UPN suffix, may be incorrect)'
        'WarnMixedModeNotActive'             = '  {0}: Mixed-Mode not active (LoginMode={1}) – activating ...'
        'WarnMixedModeCheckFailed'           = '  {0}: Mixed-Mode check failed – {0}'
        'WarnMixedModeManual'                = '  {0}: Please manually activate Mixed-Mode: Server Properties → Security → SQL Server and Windows Authentication mode'
        'WarnNoServiceAccount'               = '  No service account specified – step skipped.'
        'WarnPasswordMissing'                = '  New account ''{0}'' specified, but no password – step skipped.'
        'WarnOrphanedGroup'                  = '  Orphaned WSFC group ''{0}'' found – cleaning up ...'
        'WarnGroupCleanupFailed'             = '  Could not delete WSFC group: {0}'
        'WarnRegistryCleanupFailed'          = '  Registry not cleaned on ''{0}'': {0}'
        'WarnAGExists'                       = '  AG ''{0}'' already exists – step skipped.'
        'WarnModifyReplicaFailed'            = '  {0}: MODIFY REPLICA failed (not critical) – {0}'
        'WarnModifyReplicaError'             = '  {0}: MODIFY REPLICA error (not critical) – {0}'
        'WarnListenerIPMissing'              = '  Listener IP or port missing – skipped.'
        'WarnAGNotVisible'                   = '  AG not visible after 60s – listener step skipped.'
        'WarnStatusQueryFailed'              = 'Status query failed – {0}'
        'WarnSecondsNotSpelling'             = '  {0}: Joining AG ...'
        'WarnNoServiceAccountKnown'          = '  No service account known – SPN check skipped.'
        'WarnSPNMissing'                     = '  MISSING  {0}'
        'WarnSPNCount'                       = '  {0} SPN(s) missing. Without correct SPNs,'
        'WarnSPNAuth'                        = '  Windows authentication fails with SSPI context error.'
        'WarnAdTeamExecution'                = '  The following commands must be executed by a domain admin:'
        'WarnAGSeeding'                      = 'AG status not yet queryable – seeding may still be in progress.'
        'WarnConfirmPassword'                = "Service account changed to ''{0}''`nbut no password entered. Continue anyway?"
        'WarnLoginRemovedFailed'             = '    ''{0}'': Could not remove login – please check manually: {0}'
        'WarnModuleRestartNeeded'            = 'One or more modules were newly installed.`nThe current PowerShell session must be restarted`nfor all modules to load correctly.`n`nPlease run the script again after restart.'
        'WarnAccountValidationFailed'        = 'Service account changed to ''{0}'' – AD validation recommended.'
        'WarnNodesToImprovement'             = '  The following nodes are not accessible via Windows auth (Kerberos):'
        'WarnWindowsAuthFailed'              = '  Windows auth ''{0}'': failed – {0}'
        'WarnSecondarySecondJoin'            = '  {0}: Join failed – {0}'
        'WarnSQLAuthFailedNode'              = '  SQL auth ''{0}'': failed – {0}'
        'WarnLoginRetry'                     = '  Please check login and click ''Continue'' again.'
        'WarnSetupComplete'                  = 'After execution on all nodes: Click ''Continue'' to proceed.'
        'WarnLognotWritable'                 = 'Could not write log file: {0}'

        # Error Messages
        'ErrorClusterUnreachable'            = 'Cluster not reachable: {0}'
        'ErrorAccountNotInAD'                = 'Account not found in AD.'
        'ErrorADCheckFailed'                 = 'AD check failed: {0}'
        'ErrorWMIChange'                     = '  {0}: WMI Change() ReturnValue={1}'
        'ErrorAccountUpdateFailed'           = '  {0}: Error updating account – {0}'
        'ErrorHADRFailed'                    = '  {0}: HADR activation failed – {0}'
        'ErrorSQLNotReady'                   = '  {0}: SQL Server not reachable after 2 minutes.'
        'ErrorEndpointFailed'                = '  {0}: Endpoint error – {0}'
        'ErrorStep4Failed'                   = '  {0}: Error in step 4 – {0}'
        'ErrorDatabaseFailed'                = '  Database preparation failed – {0}'
        'ErrorAGCreationFailed'              = '  AG creation failed – {0}'
        'ErrorListenerFailed'                = '  Listener configuration failed – {0}'
        'ErrorJobFailed'                     = '  AG sync job failed – {0}'
        'ErrorJobCreationFailed'             = '  {0}: Job creation failed – {0}'
        'ErrorSPNCheckFailed'                = '  SPN check failed: {0}'
        'ErrorADTeamFileFailed'              = '  Could not write AD team file: {0}'
        'ErrorCertAuthFailed'                = '  {0}: Certificate setup failed – {0}'
        'ErrorManualRequired'                = '  MANUAL REQUIRED: CREATE LOGIN + GRANT CONNECT ON ENDPOINT by AD team'
        'ErrorConfigStep1'                   = '  {0}: Error updating account – {0}'
        'ErrorStep4General'                  = '  {0}: Error in step 4 – {0}'
        'ErrorListenerCreationFailed'        = '  Listener creation failed: {0}'

        # Dialog/MessageBox Titles
        'MsgTitleAccountCheck'               = 'Check Account'
        'MsgTitleError'                      = 'Error'
        'MsgTitleConfirm'                    = 'Confirmation'
        'MsgTitleADCheck'                    = 'AD Check'
        'MsgTitlePasswordMissing'            = 'Password Missing'
        'MsgTitleModuleInstallFailed'        = 'Module Installation Failed'
        'MsgTitleRestartRequired'            = 'Restart Required'

        # Dialog/MessageBox Content
        'MsgNoAccount'                       = 'Please first enter a service account in the PropertyGrid.'
        'MsgAccountFound'                    = "Account found:`nDisplay name: {0}`nUPN: {1}"
        'MsgAccountNotFound'                 = "Account not found:`n{0}"
        'MsgAGNameRequired'                  = 'Please enter an AG name.'
        'MsgListenerNameRequired'            = 'Please enter a listener name. No cluster role found - enter manually!'
        'BtnReset'                           = 'Reset'
        'BtnResetTooltip'                    = 'Reset AG name and listener name to detected values'
        'InfoResetDone'                      = 'AG name and listener name reset to detected values.'
        'InfoIPCheckOK'                      = 'IP address {0} resolved: {1}'
        'WarnIPCheckFail'                    = 'IP address {0} could not be resolved - please check!'
        'MsgConfigStarting'                  = "AlwaysOn configuration starting:`n`n" +
                                              "  AG name     : {0}`n" +
                                              "  Primary     : {1}`n" +
                                              "  Endpoint    : Port {2}`n" +
                                              "  Failover    : {3}`n" +
                                              "  Database    : {4}`n" +
                                              "{5}`n`n" +
                                              'Run now?'
        'MsgAccountChangeInfo'               = '  Account    : CHANGE  ''{0}''  →  ''{1}'''
        'MsgAccountNoChange'                 = '  Account    : unchanged ({0})'
    }
}

# ---------------------------------------------------------------------------
# Helper function for string translation
# ---------------------------------------------------------------------------
function T {
    param([string]$Key, [object[]]$f)
    $s = $script:LangStrings[$script:CurrentLang][$Key]
    if (-not $s) { return "[$Key]" }
    if ($f)      { return $s -f $f }
    return $s
}

# ---------------------------------------------------------------------------
# Update all UI control labels based on current language
# ---------------------------------------------------------------------------
function Update-UILanguage {
    $form.Text              = T 'FormTitle'
    $tabKonfig.Text         = T 'TabConfig'
    $tsBtnLoad.Text         = T 'BtnReload'
    $tsBtnLoad.ToolTipText  = T 'BtnReloadTooltip'
    $tsBtnValidate.Text     = T 'BtnValidate'
    $tsBtnValidate.ToolTipText = T 'BtnValidateTooltip'
    $tsBtnReset.Text        = T 'BtnReset'
    $tsBtnReset.ToolTipText = T 'BtnResetTooltip'
    if ($tsBtnLang) {
        $tsBtnLang.Text     = if ($script:CurrentLang -eq 'DE') { '🌐 EN' } else { '🌐 DE' }
    }
    $lblGrid.Text           = T 'LblConfig'
    $lblLog.Text            = T 'LblLog'
    $btnOK.Text             = T 'BtnOK'
    $btnClose.Text          = T 'BtnClose'
    $btnContinue.Text       = T 'BtnContinue'
    $btnClearLog.Text       = T 'BtnClearLog'
    $btnSaveLog.Text        = T 'BtnSaveLog'
}

# ---------------------------------------------------------------------------
# Modul-Voraussetzungen prüfen und ggf. automatisch installieren
# ---------------------------------------------------------------------------
function Install-RequiredModule {
    param(
        [string]$ModuleName,
        [string]$InstallCommand = "Install-Module -Name '$ModuleName' -Scope AllUsers -Force -AllowClobber"
    )

    # Bereits in dieser Session geladen → sofort zurück, kein Import
    if (Get-Module -Name $ModuleName -ErrorAction SilentlyContinue) {
        $ver = (Get-Module -Name $ModuleName).Version
        Write-Host (T 'InfoAlreadyLoaded' -f $ModuleName, $ver)
        return $true
    }

    # Verfügbar aber noch nicht importiert?
    $available = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    if ($available) {
        try {
            Import-Module -Name $ModuleName -Force -ErrorAction Stop
            Write-Host (T 'InfoImportSuccess' -f $ModuleName, $available.Version)
            return $true
        } catch {
            Write-Host (T 'InfoImportFailed' -f $ModuleName, $_)
        }
    }

    # Nicht vorhanden – Installation versuchen
    Write-Host (T 'InfoNotFound' -f $ModuleName)
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        Invoke-Expression $InstallCommand | Out-Null
        Import-Module -Name $ModuleName -Force -ErrorAction Stop
        $ver = (Get-Module -Name $ModuleName).Version
        Write-Host (T 'InfoInstallSuccess' -f $ModuleName, $ver)
        return $true
    } catch {
        Write-Host (T 'InfoInstallFailed' -f $ModuleName, $_)
        return $false
    }
}

# FailoverClusters: Windows-Feature (RSAT) – andere Installationsmethode
function Install-FailoverClustersModule {
    if (Get-Module -Name FailoverClusters -ErrorAction SilentlyContinue) { return $true }
    $available = Get-Module -ListAvailable -Name FailoverClusters -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    if ($available) {
        try {
            Import-Module -Name FailoverClusters -Force -ErrorAction Stop
            Write-Host (T 'InfoFailoverClusterFound')
            return $true
        } catch { }
    }

    Write-Host (T 'InfoNotFound' -f 'FailoverClusters')
    try {
        # Windows Server: Install-WindowsFeature
        if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
            Install-WindowsFeature -Name RSAT-Clustering-PowerShell -IncludeManagementTools -ErrorAction Stop | Out-Null
        }
        # Windows 10/11 Client: DISM / Add-WindowsCapability
        elseif (Get-Command Add-WindowsCapability -ErrorAction SilentlyContinue) {
            Add-WindowsCapability -Online -Name 'Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0' -ErrorAction Stop | Out-Null
        }
        else {
            throw (T 'InfoUnableToCreate')
        }

        Import-Module -Name FailoverClusters -Force -ErrorAction Stop
        Write-Host (T 'InfoFailoverClusterRSAT')
        return $true
    } catch {
        Write-Host "FailoverClusters FEHLER bei Installation: $_"
        return $false
    }
}

# --- Prüfungen durchführen (vor GUI-Start, Ausgabe in Konsole) ---
$script:moduleErrors = [System.Collections.Generic.List[string]]::new()

Write-Host "=== Modul-Voraussetzungen prüfen ==="

$fcOk = Install-FailoverClustersModule
if (-not $fcOk) {
    $script:moduleErrors.Add(
        "FailoverClusters-Modul konnte nicht installiert werden.`n" +
        "Bitte manuell installieren:`n" +
        "  Install-WindowsFeature -Name RSAT-Clustering-PowerShell -IncludeManagementTools`n" +
        "Danach PowerShell-Session neu starten."
    )
}

$dbaOk = Install-RequiredModule -ModuleName 'dbatools'
if (-not $dbaOk) {
    $script:moduleErrors.Add(
        "dbaTools-Modul konnte nicht geladen werden.`n" +
        "Bitte manuell installieren:`n" +
        "  Install-Module -Name dbatools -Scope AllUsers -Force -AllowClobber`n" +
        "Danach PowerShell-Session neu starten."
    )
}

# Neu-Start der Session erforderlich?
# Prüfen ob Module nach Installation zwar im Dateisystem, aber noch nicht im
# aktuellen Prozess verfügbar sind (kann bei manchen Windows-Feature-Installs vorkommen).
$script:restartRequired = $false
if ($fcOk  -and -not (Get-Module -Name FailoverClusters -ErrorAction SilentlyContinue)) {
    $script:restartRequired = $true
}
if ($dbaOk -and -not (Get-Module -Name dbatools        -ErrorAction SilentlyContinue)) {
    $script:restartRequired = $true
}

Write-Host "=== Modul-Prüfung abgeschlossen ==="

# ---------------------------------------------------------------------------
# INI-Konfiguration einlesen
# ---------------------------------------------------------------------------
$script:iniConfig = @{
    AG_SYNC_JOB_NAME = ''   # leer = Standardname verwenden
}
$iniFile = Join-Path $PSScriptRoot 'AlwaysOnSetup.ini'
if (Test-Path $iniFile) {
    Get-Content $iniFile | Where-Object { $_ -match '^\s*[^;].*=' } | ForEach-Object {
        $parts = $_ -split '=', 2
        $key   = $parts[0].Trim()
        $value = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        if ($script:iniConfig.ContainsKey($key)) {
            $script:iniConfig[$key] = $value
        }
    }
    Write-Host (T 'InfoINILoaded' -f $iniFile)
}

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Write-RtfLog {
    param(
        [System.Windows.Forms.RichTextBox]$Rtb,
        [string]$Message,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::Black,
        [switch]$Bold
    )
    $Rtb.SelectionStart  = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $Rtb.SelectionColor  = $Color
    if ($Bold) {
        $Rtb.SelectionFont = New-Object System.Drawing.Font($Rtb.Font, [System.Drawing.FontStyle]::Bold)
    } else {
        $Rtb.SelectionFont = $Rtb.Font
    }
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $Rtb.AppendText("[$timestamp] $Message`n")
    $Rtb.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Write-RtfInfo    { param($Rtb,$Msg) Write-RtfLog -Rtb $Rtb -Message $Msg -Color ([System.Drawing.Color]::FromArgb(210, 210, 210)) }
function Write-RtfSuccess { param($Rtb,$Msg) Write-RtfLog -Rtb $Rtb -Message $Msg -Color ([System.Drawing.Color]::FromArgb(100, 220, 100)) -Bold }
function Write-RtfWarn    { param($Rtb,$Msg) Write-RtfLog -Rtb $Rtb -Message $Msg -Color ([System.Drawing.Color]::FromArgb(255, 200, 60)) }
function Write-RtfError   { param($Rtb,$Msg) Write-RtfLog -Rtb $Rtb -Message $Msg -Color ([System.Drawing.Color]::FromArgb(255, 100, 100)) -Bold }
function Write-RtfSection { param($Rtb,$Msg) Write-RtfLog -Rtb $Rtb -Message "=== $Msg ===" -Color ([System.Drawing.Color]::FromArgb(80, 180, 255)) -Bold }

function Test-ADAccount {
    param([string]$AccountName)
    try {
        # Domain-Anteil trennen falls vorhanden (DOMAIN\User oder user@domain)
        $samName = $AccountName -replace '^.*\\', '' -replace '@.*$', ''
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain
        )
        $user = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($ctx, $samName)
        if ($null -ne $user) { return @{ Found = $true; DisplayName = $user.DisplayName; UPN = $user.UserPrincipalName } }

        # Als Gruppen-/Dienstkonto (MSA/gMSA) prüfen
        $computer = [System.DirectoryServices.AccountManagement.ComputerPrincipal]::FindByIdentity($ctx, $samName)
        if ($null -ne $computer) { return @{ Found = $true; DisplayName = $computer.DisplayName; UPN = $samName } }

        return @{ Found = $false }
    } catch {
        return @{ Found = $false; Error = $_.Exception.Message }
    }
}

function Get-ClusterAndSqlInfo {
    param([System.Windows.Forms.RichTextBox]$Rtb)

    Write-RtfSection -Rtb $Rtb -Msg 'Cluster- und SQL-Informationen einlesen'

    $info = [ordered]@{}

    # ---- Windows Failover Cluster ----
    try {
        $cluster = Get-Cluster
        $info['ClusterName'] = $cluster.Name.Trim()
        Write-RtfInfo -Rtb $Rtb -Msg "Cluster gefunden: $($cluster.Name.Trim())"
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "Cluster nicht erreichbar: $_"
        throw
    }

    # ---- Cluster Nodes ----
    try {
        $nodes = Get-ClusterNode | Select-Object -ExpandProperty Name
        $info['Node1'] = if ($nodes.Count -ge 1) { $nodes[0] } else { '' }
        $info['Node2'] = if ($nodes.Count -ge 2) { $nodes[1] } else { '' }
        $info['Node3'] = if ($nodes.Count -ge 3) { $nodes[2] } else { '' }
        Write-RtfInfo -Rtb $Rtb -Msg "Nodes: $($nodes -join ', ')"
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "Nodes konnten nicht gelesen werden: $_"
        throw
    }

    # ---- Cluster Rollen / Listener ----
    $listenerName  = ''
    $listenerIP    = ''
    $listenerPort  = 1433   # Fallback falls Cluster keinen Port liefert
    try {
        $roles = Get-ClusterGroup
        Write-RtfInfo -Rtb $Rtb -Msg "Cluster-Rollen: $(($roles | Select-Object -ExpandProperty Name) -join ', ')"

        # Listener-Rolle: erste Rolle mit Netzwerkname-Ressource
        foreach ($role in $roles) {
            $roleName = $role.Name.Trim()  # Trim cluster role names to avoid sync issues

            $netNameRes = Get-ClusterResource | Where-Object {
                $_.OwnerGroup -eq $roleName -and $_.ResourceType -like '*Network Name*'
            } | Select-Object -First 1

            if ($netNameRes) {
                $listenerName = Get-ClusterParameter -InputObject $netNameRes -Name Name -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
                if (-not $listenerName) { $listenerName = $roleName }

                $ipRes = Get-ClusterResource | Where-Object {
                    $_.OwnerGroup -eq $roleName -and $_.ResourceType -like '*IP Address*'
                } | Select-Object -First 1

                if ($ipRes) {
                    $listenerIP = Get-ClusterParameter -InputObject $ipRes -Name Address -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue

                    $probePort = Get-ClusterParameter -InputObject $ipRes -Name ProbePort -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
                    $netPort   = Get-ClusterParameter -InputObject $netNameRes -Name Port -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue

                    if ($probePort -and [int]$probePort -gt 0) {
                        $listenerPort = [int]$probePort
                        Write-RtfInfo -Rtb $Rtb -Msg "  Listener-Port aus ProbePort gelesen: $listenerPort"
                    } elseif ($netPort -and [int]$netPort -gt 0) {
                        $listenerPort = [int]$netPort
                        Write-RtfInfo -Rtb $Rtb -Msg "  Listener-Port aus Netzwerkname-Ressource gelesen: $listenerPort"
                    } else {
                        Write-RtfWarn -Rtb $Rtb -Msg "  Listener-Port nicht im Cluster hinterlegt – Fallback: $listenerPort"
                    }
                }
                break
            }
        }
        if (-not $listenerName) {
            Write-RtfWarn -Rtb $Rtb -Msg "Keine Cluster-Rolle mit Netzwerkname gefunden. Listener-Name und AG-Name muessen manuell eingetragen werden!"
        }
        Write-RtfInfo -Rtb $Rtb -Msg "Listener-Name: $listenerName  |  IP: $listenerIP  |  Port: $listenerPort"
    } catch {
        Write-RtfWarn -Rtb $Rtb -Msg "Listener-Informationen unvollständig: $_"
    }

    $info['ListenerName'] = $listenerName
    $info['ListenerIP']   = $listenerIP
    $info['ListenerPort'] = $listenerPort

    # AG-Name: Default = Listener-Name (nur wenn Listener gefunden!)
    # Wenn leer -> manuell eintragen, NICHT ClusterName verwenden!
    $info['AGName']       = $listenerName

    # ---- SQL Server Instanzen pro Node ----
    $sqlInstances   = @()
    $serviceAccount = ''
    $alwaysOnStates = @()

    foreach ($node in ($nodes | Where-Object { $_ })) {
        try {
            # SQL-Dienst per WMI – kein dbaTools
            $svc = Get-WmiObject -ComputerName $node -Class Win32_Service `
                   -Filter "Name='MSSQLSERVER' OR Name LIKE 'MSSQL$%'" `
                   -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' } |
                   Select-Object -First 1

            if ($svc) {
                $instName = if ($svc.Name -eq 'MSSQLSERVER') { $node }
                            else { "$node\$($svc.Name -replace '^MSSQL\$','')" }
                $sqlInstances += $instName
                if (-not $serviceAccount) { $serviceAccount = $svc.StartName }

                # HADR-Status per T-SQL direkt abfragen
                $aoEnabled = $false
                try {
                    $hadrResult = Invoke-DbaQuery -SqlInstance $instName -ErrorAction SilentlyContinue `
                        -Query 'SELECT value_in_use FROM sys.configurations WHERE name = ''hadr enabled''' |
                        Select-Object -First 1
                    $aoEnabled = ($hadrResult -and $hadrResult.value_in_use -eq 1)
                } catch { }

                $alwaysOnStates += "$($node): $(if($aoEnabled){'Aktiviert'}else{'Deaktiviert'})"
                Write-RtfInfo -Rtb $Rtb -Msg "$node  –  Dienst: $($svc.DisplayName)  |  Konto: $($svc.StartName)  |  AlwaysOn: $(if($aoEnabled){'AN'}else{'AUS'})"
            } else {
                Write-RtfWarn -Rtb $Rtb -Msg "$($node): Kein SQL-Engine-Dienst gefunden"
                $sqlInstances += $node
            }
        } catch {
            Write-RtfWarn -Rtb $Rtb -Msg "$($node): SQL-Info nicht lesbar – $_"
            $sqlInstances += $node
        }
    }

    # Backup-Pfad per T-SQL statt Get-DbaDefaultPath
    $bakupPath = 'C:\System\Backups'
    try {
        $pathResult = Invoke-DbaQuery -SqlInstance $sqlInstances[0] -ErrorAction SilentlyContinue `
            -Query "EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory'" |
            Select-Object -First 1
        if ($pathResult -and $pathResult.Data) { $bakupPath = $pathResult.Data }
    } catch { }

    $info['SqlInstance1']   = if ($sqlInstances.Count -ge 1) { $sqlInstances[0] } else { $nodes[0] }
    $info['SqlInstance2']   = if ($sqlInstances.Count -ge 2) { $sqlInstances[1] } else { '' }
    $info['SqlInstance3']   = if ($sqlInstances.Count -ge 3) { $sqlInstances[2] } else { '' }
    $info['ServiceAccount']         = $serviceAccount
    $info['OriginalServiceAccount'] = $serviceAccount   # Unveränderter Referenzwert für Änderungsvergleich
    $info['ServicePassword']        = ''
    $info['AlwaysOnStatus'] = $alwaysOnStates -join ' | '
    $info['EndpointPort']   = 5022
    $info['FailoverMode']   = 'Automatic'   # Automatic | Manual
    $info['TestDatabase']   = 'AlwaysOnTest'
    $info['BackupShare']    = $bakupPath

    Write-RtfSuccess -Rtb $Rtb -Msg 'Einlesen abgeschlossen.'
    return $info
}

# ---------------------------------------------------------------------------
# PropertyGrid-Descriptor-Klasse  (TypeDescriptor / ExpandableObject)
# ---------------------------------------------------------------------------
Add-Type -Language CSharp @'
using System;
using System.ComponentModel;
using System.Collections.Generic;

[TypeConverter(typeof(ExpandableObjectConverter))]
public class NodeConfig {
    [Category("Node")]
    [DisplayName("SQL-Instanz")]
    [Description("SQL Server Instanzname dieses Nodes")]
    [ReadOnly(true)]
    public string SqlInstance { get; set; }

    [Category("Node")]
    [DisplayName("Hostname")]
    [Description("Windows-Hostname des Cluster-Nodes")]
    [ReadOnly(true)]
    public string Hostname { get; set; }

    [Category("Node")]
    [DisplayName("AlwaysOn-Status")]
    [Description("Aktueller AlwaysOn/HADR-Status")]
    [ReadOnly(true)]
    public string AlwaysOnStatus { get; set; }

    public override string ToString() { return SqlInstance ?? Hostname ?? ""; }
}

public class FailoverModeConverter : StringConverter {
    public override bool GetStandardValuesSupported(ITypeDescriptorContext ctx) { return true; }
    public override bool GetStandardValuesExclusive(ITypeDescriptorContext ctx) { return true; }
    public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext ctx) {
        return new StandardValuesCollection(new[] { "Automatic", "Manual" });
    }
}

public class BackupPreferenceConverter : StringConverter {
    public override bool GetStandardValuesSupported(ITypeDescriptorContext ctx) { return true; }
    public override bool GetStandardValuesExclusive(ITypeDescriptorContext ctx) { return true; }
    public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext ctx) {
        return new StandardValuesCollection(new[] { "Primary", "Secondary", "PreferSecondary", "None" });
    }
}

public class AgConfig {
    // ---- Cluster ----
    [Category("1 - Cluster")]
    [DisplayName("Cluster-Name")]
    [ReadOnly(true)]
    public string ClusterName { get; set; }

    [Category("1 - Cluster")]
    [DisplayName("Listener-Name")]
    [Description("Listener-Name (automatisch erkannt oder manuell eintragen wenn keine Cluster-Rolle gefunden)")]
    public string ListenerName { get; set; }

    [Category("1 - Cluster")]
    [DisplayName("Listener-IP")]
    [ReadOnly(true)]
    public string ListenerIP { get; set; }

    [Category("1 - Cluster")]
    [DisplayName("Listener-Port")]
    [Description("TCP-Port des AG-Listeners – vom Cluster gelesen.")]
    [ReadOnly(true)]
    public int ListenerPort { get; set; }

    // ---- Nodes ----
    [Category("2 - Nodes")]
    [DisplayName("Node 1")]
    [TypeConverter(typeof(ExpandableObjectConverter))]
    public NodeConfig Node1 { get; set; }

    [Category("2 - Nodes")]
    [DisplayName("Node 2")]
    [TypeConverter(typeof(ExpandableObjectConverter))]
    public NodeConfig Node2 { get; set; }

    [Category("2 - Nodes")]
    [DisplayName("Node 3")]
    [TypeConverter(typeof(ExpandableObjectConverter))]
    public NodeConfig Node3 { get; set; }

    // ---- AG-Konfiguration ----
    [Category("3 - Availability Group")]
    [DisplayName("AG-Name")]
    [Description("Name der Availability Group (Default = Listener-Rolle)")]
    public string AGName { get; set; }

    [Category("3 - Availability Group")]
    [DisplayName("Endpoint-Port")]
    [Description("TCP-Port des Datenbank-Spiegelungs-Endpoints (Default: 5022)")]
    public int EndpointPort { get; set; }

    [Category("3 - Availability Group")]
    [DisplayName("Failover-Modus")]
    [Description("Automatic = automatisches Failover; Manual = manuell")]
    [TypeConverter(typeof(FailoverModeConverter))]
    public string FailoverMode { get; set; }

    [Category("3 - Availability Group")]
    [DisplayName("Backup-Präferenz")]
    [Description("Primary = nur Primary; Secondary = bevorzugt Secondary; PreferSecondary = Secondary wenn möglich; None = keine Präferenz")]
    [TypeConverter(typeof(BackupPreferenceConverter))]
    public string BackupPreference { get; set; }

    [Category("3 - Availability Group")]
    [DisplayName("Test-Datenbank")]
    [Description("Name der automatisch erstellten und per Autoseed verteilten Testdatenbank")]
    public string TestDatabase { get; set; }

    [Category("3 - Availability Group")]
    [DisplayName("Backup-Share")]
    [Description("UNC-Pfad für initiales Backup (wird nur bei Non-Autoseed benötigt)")]
    public string BackupShare { get; set; }

    // ---- Dienstkonto ----
    [Category("4 - SQL Service-Konto")]
    [DisplayName("Dienst-Konto")]
    [Description("Domänenkonto für SQL Server-Dienst (DOMAIN\\User)")]
    public string ServiceAccount { get; set; }

    [Category("4 - SQL Service-Konto")]
    [DisplayName("Kennwort")]
    [Description("Passwort des SQL Service-Kontos")]
    [PasswordPropertyText(true)]
    public string ServicePassword { get; set; }

}
'@

# ---------------------------------------------------------------------------
# Skript-weiter Policy-Name (einmalig änderbar)
# ---------------------------------------------------------------------------
$script:pbmPolicyName = 'New Login_Enforce Passwort Policy'

# ---------------------------------------------------------------------------
# Hilfsfunktion: PBM-Policy auf allen Nodes aktivieren oder deaktivieren
# $Enable = $true → aktivieren, $false → deaktivieren
# Verwendet $sqlCred wenn übergeben, sonst Windows-Auth
# ---------------------------------------------------------------------------
function Set-PbmPolicy {
    param(
        [bool]$Enable,
        [object[]]$Nodes,
        [System.Management.Automation.PSCredential]$SqlCred,
        [System.Windows.Forms.RichTextBox]$Rtb
    )
    $state  = if ($Enable) { 1 } else { 0 }
    $action = if ($Enable) { 'aktiviert' } else { 'deaktiviert' }
    $query  = "EXEC msdb.dbo.sp_syspolicy_update_policy @name = N'$($script:pbmPolicyName)', @is_enabled = $state"

    foreach ($nc in $Nodes) {
        $instance   = if ($nc -is [string]) { $nc } else { $nc.SqlInstance }
        $targetHost = ($instance -split '\\')[0]
        $done = $false

        # Erst per SQL-Auth oder Windows-Auth (je nach $SqlCred)
        try {
            Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCred `
                -Database msdb -Query $query -ErrorAction Stop
            Write-RtfInfo -Rtb $Rtb -Msg "  $($instance): Policy '$($script:pbmPolicyName)' $action."
            $done = $true
        } catch { }

        # Fallback: PSRemoting (lokal auf Ziel-Node, kein Kerberos-Hop nötig)
        if (-not $done) {
            try {
                Invoke-Command -ComputerName $targetHost -ErrorAction Stop -ScriptBlock {
                    param($inst, $q)
                    sqlcmd -S $inst -E -d msdb -Q $q 2>&1 | Out-Null
                } -ArgumentList $instance, $query
                Write-RtfInfo -Rtb $Rtb -Msg "  $($instance): Policy '$($script:pbmPolicyName)' $action (via PSRemoting)."
            } catch {
                Write-RtfWarn -Rtb $Rtb -Msg "  $($instance): Policy '$($script:pbmPolicyName)' konnte nicht $action werden."
            }
        }
    }
}

# ---------------------------------------------------------------------------
function New-RandomPassword {
    # Nur Zeichen die weder in T-SQL-Strings (kein ') noch in PowerShell-Strings (kein ` $ @ ")
    # noch in XML/Batch-Kontexten problematisch sind.
    # SQL Server Password Policy: min. 1 Großbuchstabe, 1 Kleinbuchstabe, 1 Ziffer, 1 Sonderzeichen.
    $lower   = 'abcdefghijkmnpqrstuvwxyz'.ToCharArray()
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $digits  = '23456789'.ToCharArray()
    $special = '!#%&*-=?'.ToCharArray()   # kein ' ` $ @ " \ / + die T-SQL oder PS stören
    $all     = $lower + $upper + $digits + $special

    $rng   = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes = [byte[]]::new(28)
    $rng.GetBytes($bytes)
    $rng.Dispose()

    # Mindestens 1 aus jeder Gruppe garantieren (erste 4 Bytes)
    $pwd = [System.Collections.Generic.List[char]]::new()
    $pwd.Add($lower[$bytes[0]  % $lower.Length])
    $pwd.Add($upper[$bytes[1]  % $upper.Length])
    $pwd.Add($digits[$bytes[2] % $digits.Length])
    $pwd.Add($special[$bytes[3] % $special.Length])

    # Restliche Zeichen aus dem Gesamtvorrat
    for ($i = 4; $i -lt $bytes.Length; $i++) {
        $pwd.Add($all[$bytes[$i] % $all.Length])
    }

    # Fisher-Yates-Shuffle damit die garantierten Zeichen nicht immer vorne stehen
    for ($i = $pwd.Count - 1; $i -gt 0; $i--) {
        $j   = $bytes[$i % $bytes.Length] % ($i + 1)
        $tmp = $pwd[$i]; $pwd[$i] = $pwd[$j]; $pwd[$j] = $tmp
    }

    return -join $pwd
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Findet einen gültigen sysadmin-Login für Job/Endpoint Owner
# (Handhabe: 'sa' könnte umbenannt oder deaktiviert sein)
# ---------------------------------------------------------------------------
function Get-ValidSysAdminLogin {
    param (
        [string]$SqlInstance,
        [PSCredential]$SqlCredential,
        [string]$PreferredLogin  # z.B. ServiceAccount wenn bekannt
    )

    # Wenn PreferredLogin gesetzt, versuche das zuerst
    if ($PreferredLogin -and $PreferredLogin -ne 'sa') {
        try {
            $result = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
                -Query "SELECT name FROM sys.server_principals WHERE name = N'$PreferredLogin' AND is_srvrolemember('sysadmin', name) = 1" `
                -ErrorAction SilentlyContinue
            if ($result) { return $PreferredLogin }
        } catch { }
    }

    # Versuche 'sa' zu finden (ist häufig noch vorhanden, auch wenn umbenannt)
    try {
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
            -Query "SELECT name FROM sys.server_principals WHERE name = N'sa' AND is_srvrolemember('sysadmin', name) = 1" `
            -ErrorAction SilentlyContinue
        if ($result) { return 'sa' }
    } catch { }

    # Fallback: Erster verfügbarer sysadmin
    try {
        $result = Invoke-DbaQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential `
            -Query "SELECT TOP 1 name FROM sys.server_principals WHERE is_srvrolemember('sysadmin', name) = 1 AND name NOT LIKE '##%' ORDER BY name" `
            -ErrorAction SilentlyContinue
        if ($result) { return $result.name }
    } catch { }

    # Letzter Resort: 'sa' (könnte fehlschlagen, aber dann ist sowieso was falsch)
    return 'sa'
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Temporäres sysadmin-Login auf allen Nodes anlegen
# Gibt PSCredential zurück wenn SQL-Auth nötig war, sonst $null (Windows-Auth)
# $script:setupLoginName wird gesetzt damit Remove-SetupCredential aufräumen kann
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Hilfsfunktion: Temporäres sysadmin-Login auf allen Nodes anlegen
# Gibt PSCredential zurück wenn SQL-Auth nötig war, sonst $null (Windows-Auth)
# $script:setupLoginName wird gesetzt damit Remove-SetupCredential aufräumen kann
# ---------------------------------------------------------------------------
$script:setupLoginName  = $null
$script:setupLoginNodes = @()
$script:setupLoginCred  = $null   # Wird von Start-AlwaysOnConfiguration nach Weiter-Klick befüllt

function Initialize-SetupCredential {
    param(
        [string]$PrimaryInstance,
        [object[]]$AllNodes,
        [System.Windows.Forms.RichTextBox]$Rtb
    )

    # Windows-Auth auf ALLEN Nodes testen
    $failedNodes = @()
    foreach ($nc in $AllNodes) {
        try {
            $testConn = Connect-DbaInstance -SqlInstance $nc.SqlInstance -ErrorAction Stop
            $testConn.ConnectionContext.Disconnect()
            Write-RtfInfo -Rtb $Rtb -Msg "  Windows-Auth '$($nc.SqlInstance)': OK"
        } catch {
            Write-RtfWarn -Rtb $Rtb -Msg "  Windows-Auth '$($nc.SqlInstance)': fehlgeschlagen – $_"
            $failedNodes += $nc.SqlInstance
        }
    }

    if ($failedNodes.Count -eq 0) {
        Write-RtfInfo -Rtb $Rtb -Msg "Authentifizierung: Windows-Auth (Kerberos/NTLM) auf allen Nodes OK"
        return $null   # kein SQL-Login nötig
    }

    # Mindestens ein Node nicht per Windows-Auth erreichbar → SQL-Login erforderlich.
    # Voraussetzung: SQL Server muss im Mixed-Mode laufen.
    # Prüfung und automatische Aktivierung per xp_instance_regwrite (lokal via PSRemoting).
    Write-RtfSection -Rtb $Rtb -Msg 'Manuelle Aktion erforderlich: SQL-Login anlegen'
    Write-RtfWarn -Rtb $Rtb -Msg "  Folgende Nodes sind per Windows-Auth (Kerberos) nicht erreichbar:"
    foreach ($n in $failedNodes) {
        Write-RtfWarn -Rtb $Rtb -Msg "    – $n"
    }

    # Mixed-Mode prüfen und bei Bedarf aktivieren
    Write-RtfInfo -Rtb $Rtb -Msg ""
    Write-RtfSection -Rtb $Rtb -Msg 'Mixed-Mode Authentifizierung prüfen'
    foreach ($nc in ($AllNodes | Where-Object { $failedNodes -contains $_.SqlInstance })) {
        $node = $nc.Hostname
        try {
            $loginMode = Invoke-Command -ComputerName $node -ScriptBlock {
                $regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQLServer'
                $key = (Get-Item -Path $regPath -ErrorAction Stop)
                $key.GetValue('LoginMode', 1)
            } -ErrorAction Stop

            if ($loginMode -ne 2) {
                Write-RtfWarn -Rtb $Rtb -Msg "  $node`: Mixed-Mode nicht aktiv (LoginMode=$loginMode) – wird aktiviert ..."
                Invoke-Command -ComputerName $node -ScriptBlock {
                    $regPath = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQLServer').PSPath
                    Set-ItemProperty -Path $regPath -Name 'LoginMode' -Value 2 -Type DWord
                } -ErrorAction Stop
                # SQL Server Dienst neu starten damit Mixed-Mode wirksam wird
                Write-RtfInfo -Rtb $Rtb -Msg "  $node`: Dienst-Neustart (Mixed-Mode Aktivierung) ..."
                $svc = Get-WmiObject Win32_Service -ComputerName $node -Filter "Name='MSSQLSERVER'" -ErrorAction Stop
                $svc.StopService() | Out-Null
                $deadline = (Get-Date).AddSeconds(60)
                while ((Get-WmiObject Win32_Service -ComputerName $node -Filter "Name='MSSQLSERVER'").State -ne 'Stopped') {
                    if ((Get-Date) -gt $deadline) { throw "Timeout: Dienst stoppt nicht" }
                    Start-Sleep -Seconds 2
                }
                $svc.StartService() | Out-Null
                $deadline = (Get-Date).AddSeconds(120)
                $ready = $false
                while (-not $ready) {
                    if ((Get-Date) -gt $deadline) { throw "Timeout: Dienst startet nicht" }
                    try { Invoke-DbaQuery -SqlInstance $nc.SqlInstance -Query 'SELECT 1' -ErrorAction Stop | Out-Null; $ready = $true }
                    catch { Start-Sleep -Seconds 2 }
                }
                Write-RtfSuccess -Rtb $Rtb -Msg "  $node`: Mixed-Mode aktiviert, SQL Server bereit."
            } else {
                Write-RtfInfo -Rtb $Rtb -Msg "  $node`: Mixed-Mode bereits aktiv (LoginMode=2) – OK."
            }
        } catch {
            Write-RtfWarn -Rtb $Rtb -Msg "  $node`: Mixed-Mode-Prüfung fehlgeschlagen – $_"
            Write-RtfWarn -Rtb $Rtb -Msg "  $node`: Bitte Mixed-Mode manuell aktivieren: Server Properties → Security → SQL Server and Windows Authentication mode"
        }
    }

    Write-RtfInfo -Rtb $Rtb -Msg ""
    Write-RtfInfo -Rtb $Rtb -Msg "  Bitte auf ALLEN Nodes folgendes T-SQL als sysadmin ausführen:"
    Write-RtfInfo -Rtb $Rtb -Msg "  (z.B. per SSMS lokal auf dem jeweiligen Node oder per RDP)"
    Write-RtfInfo -Rtb $Rtb -Msg ""

    # Login-Name und Passwort generieren
    $loginName = 'AGSetup_' + ([System.Guid]::NewGuid().ToString('N').Substring(0,8))
    $loginPwd  = New-RandomPassword

    $createSql = @'
-- Policy temporär deaktivieren
EXEC msdb.dbo.sp_syspolicy_update_policy
    @name = N'{0}', @is_enabled = 0;

-- Temporäres Setup-Login anlegen
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '{1}')
BEGIN
    CREATE LOGIN [{1}] WITH PASSWORD = '{2}',
        CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [{1}];
END
'@ -f $script:pbmPolicyName, $loginName, $loginPwd

    Write-RtfLog -Rtb $Rtb -Message $createSql `
        -Color ([System.Drawing.Color]::FromArgb(180, 255, 180)) -Bold

    Write-RtfInfo -Rtb $Rtb -Msg ""
    Write-RtfWarn -Rtb $Rtb -Msg "  Nach Ausführung auf allen Nodes: Klick auf 'Weiter' um fortzufahren."
    Write-RtfWarn -Rtb $Rtb -Msg "  Login: $loginName   Passwort: $loginPwd"

    # Login-Daten für die Fortsetzung merken
    $script:setupLoginName  = $loginName
    $script:setupLoginNodes = @($AllNodes | ForEach-Object { $_.SqlInstance })
    $secPwd = ConvertTo-SecureString $loginPwd -AsPlainText -Force
    $script:setupLoginCred  = New-Object System.Management.Automation.PSCredential($loginName, $secPwd)

    return '__WAIT__'   # Signal an den Caller: pausieren und auf Weiter warten
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Temporäres Setup-Login auf allen Nodes entfernen
# ---------------------------------------------------------------------------
function Remove-SetupCredential {
    param(
        [System.Management.Automation.PSCredential]$SqlCred,
        [System.Windows.Forms.RichTextBox]$Rtb
    )
    if (-not $script:setupLoginName) { return }

    Write-RtfInfo -Rtb $Rtb -Msg "  Temporäres Login '$($script:setupLoginName)' wird entfernt ..."
    $dropQuery = "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$($script:setupLoginName)') DROP LOGIN [$($script:setupLoginName)]"

    foreach ($instance in $script:setupLoginNodes) {
        $targetHost = ($instance -split '\\')[0]

        # Erst per SQL-Auth versuchen, dann Fallback auf PSRemoting
        $removed = $false
        try {
            Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCred `
                -Query $dropQuery -ErrorAction Stop
            Write-RtfSuccess -Rtb $Rtb -Msg "    '$instance': Login entfernt."
            $removed = $true
        } catch { }

        if (-not $removed) {
            try {
                Invoke-Command -ComputerName $targetHost -ErrorAction Stop -ScriptBlock {
                    param($inst, $q)
                    sqlcmd -S $inst -E -Q $q 2>&1 | Out-Null
                } -ArgumentList $instance, $dropQuery
                Write-RtfSuccess -Rtb $Rtb -Msg "    '$instance': Login entfernt (via PSRemoting)."
            } catch {
                Write-RtfWarn -Rtb $Rtb -Msg "    '$instance': Login konnte nicht entfernt werden – bitte manuell prüfen: $_"
            }
        }
    }

    # Policy nach Login-Entfernung wieder aktivieren
    Set-PbmPolicy -Enable $true -Nodes $script:setupLoginNodes -SqlCred $SqlCred -Rtb $Rtb

    $script:setupLoginName  = $null
    $script:setupLoginNodes = @()
}

# ---------------------------------------------------------------------------
# Hilfsfunktion: Zertifikat-basierte Endpoint-Authentifizierung
# Fallback wenn CREATE LOGIN FROM WINDOWS cross-domain nicht funktioniert.
# Jeder Node bekommt ein selbst-signiertes Zertifikat, tauscht es mit dem
# anderen Node aus – kein AD-Lookup nötig.
# ---------------------------------------------------------------------------
function _Set-HadrEndpointCertAuth {
    param(
        [array]  $ActiveNodes,
        $SqlCred,
        $Rtb,
        [string] $PrimaryInstance
    )

    $certs   = @{}   # Node -> Zertifikatname
    $tmpPath = 'C:\System\Certs'

    # Sicherstellen dass $tmpPath auf allen Nodes existiert
    foreach ($nc in $ActiveNodes) {
        Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $SqlCred -EnableException:$true `
            -Query "EXEC xp_create_subdir N'$tmpPath'"
    }

    # Phase 1: Master Key + Zertifikat auf jedem Node erstellen und exportieren
    foreach ($nc in $ActiveNodes) {
        $short    = ($nc.Hostname -split '\.')[0].ToUpper()
        $certName = "HADR_Cert_$short"
        $cerFile  = "$tmpPath\$certName.cer"
        $certs[$nc.SqlInstance] = @{ CertName = $certName; CerFile = $cerFile; Short = $short }

        Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Erstelle Zertifikat '$certName' ..."

        Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $SqlCred -EnableException:$true -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(New-RandomPassword -Length 32)';
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'$certName')
    CREATE CERTIFICATE [$certName]
        WITH SUBJECT = 'AlwaysOn Endpoint Certificate $short',
        EXPIRY_DATE  = '2035-12-31';
BACKUP CERTIFICATE [$certName] TO FILE = N'$cerFile';
"@
        Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Zertifikat erstellt und exportiert nach '$cerFile'."
    }

    # Phase 2: Zertifikate kreuzweise importieren + Endpoint umstellen
    foreach ($nc in $ActiveNodes) {
        $myInfo = $certs[$nc.SqlInstance]

        # Endpoint auf eigenes Zertifikat umstellen
        Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $SqlCred -EnableException:$true `
            -Query "ALTER ENDPOINT [HADR_Endpoint] FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE [$($myInfo.CertName)]);"
        Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Endpoint auf Zertifikat-Auth umgestellt."

        # Fremdzertifikate importieren
        foreach ($other in $ActiveNodes | Where-Object { $_.SqlInstance -ne $nc.SqlInstance }) {
            $otherInfo  = $certs[$other.SqlInstance]
            $loginName  = "HADR_Login_$($otherInfo.Short)"
            $userName   = "HADR_User_$($otherInfo.Short)"

            # Zertifikatdatei vom anderen Node kopieren (UNC)
            $uncSrc = $otherInfo.CerFile -replace '^(\w):\\', "\\$($other.Hostname)\`$1`$\"
            $uncDst = $myInfo.CerFile    -replace '^(\w):\\', "\\$($nc.Hostname)\`$1`$\"
            if (-not (Test-Path $uncSrc)) { throw "Zertifikatdatei nicht erreichbar: $uncSrc" }
            if ($uncSrc -ne $uncDst) { Copy-Item $uncSrc -Destination ($uncDst -replace '[^\\]+$', '') -Force }

            Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $SqlCred -EnableException:$true -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$loginName')
    CREATE LOGIN [$loginName] WITH PASSWORD = '$(New-RandomPassword -Length 32)';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$userName')
BEGIN
    USE master;
    CREATE USER [$userName] FOR LOGIN [$loginName];
END
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = N'$($otherInfo.CertName)')
    CREATE CERTIFICATE [$($otherInfo.CertName)]
        AUTHORIZATION [$userName]
        FROM FILE = N'$($otherInfo.CerFile)';
GRANT CONNECT ON ENDPOINT::[HADR_Endpoint] TO [$loginName];
"@
            Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Zertifikat von '$($other.SqlInstance)' importiert, CONNECT gesetzt."
        }
    }

    Write-RtfSuccess -Rtb $Rtb -Msg "  Zertifikat-basierte Endpoint-Authentifizierung auf allen Nodes konfiguriert."
}

# ---------------------------------------------------------------------------
# Haupt-Konfigurationsroutine
# ---------------------------------------------------------------------------
function Start-AlwaysOnConfiguration {
    param(
        [AgConfig]$Config,
        [System.Windows.Forms.RichTextBox]$Rtb,
        [System.Windows.Forms.Button]$BtnOK
    )

    $BtnOK.Enabled = $false

    # Aktive Nodes sammeln (wird für Initialize-SetupCredential benötigt)
    $activeNodes = @()
    foreach ($nc in @($Config.Node1, $Config.Node2, $Config.Node3)) {
        if ($nc -and $nc.SqlInstance) { $activeNodes += $nc }
    }
    $primaryInstance = $activeNodes[0].SqlInstance
    $secondaries     = @($activeNodes | Select-Object -Skip 1)

    Write-RtfSection -Rtb $Rtb -Msg "Konfiguration startet  –  Primary: $primaryInstance"

    # ------------------------------------------------------------------ #
    # Verbindungs-Credential automatisch ermitteln                        #
    # Windows-Auth OK → weiter. Fehlgeschlagen → Anwender-Aktion nötig.  #
    # ------------------------------------------------------------------ #
    $initResult = Initialize-SetupCredential -PrimaryInstance $primaryInstance -AllNodes $activeNodes -Rtb $Rtb

    if ($initResult -eq '__WAIT__') {
        # Anwender muss Login manuell anlegen → "Weiter"-Button einblenden
        $btnContinue.Visible = $true
        $btnContinue.Enabled = $true
        $statusLabel.Text    = 'Bitte SQL-Login anlegen und dann "Weiter" klicken.'
        # Konfiguration wird durch den Weiter-Button-Handler fortgesetzt
        return
    }

    # Windows-Auth auf allen Nodes OK → direkt weitermachen
    Invoke-AlwaysOnSteps -Config $Config -Rtb $Rtb -BtnOK $BtnOK -SqlCred $null
}

# ---------------------------------------------------------------------------
# Alle Konfigurations-Schritte (1–9) – wird direkt oder nach Weiter-Klick aufgerufen
# ---------------------------------------------------------------------------
function Invoke-AlwaysOnSteps {
    param(
        [AgConfig]$Config,
        [System.Windows.Forms.RichTextBox]$Rtb,
        [System.Windows.Forms.Button]$BtnOK,
        [System.Management.Automation.PSCredential]$SqlCred
    )

    # Aktive Nodes und Primary aus Config ableiten
    $activeNodes = @()
    foreach ($nc in @($Config.Node1, $Config.Node2, $Config.Node3)) {
        if ($nc -and $nc.SqlInstance) { $activeNodes += $nc }
    }
    $primaryInstance = $activeNodes[0].SqlInstance
    $secondaries     = @($activeNodes | Select-Object -Skip 1)

    # ------------------------------------------------------------------ #
    # Cluster-Settings sichern (vor jeder Änderung)                       #
    # ------------------------------------------------------------------ #
    try {
        $settingsDir = 'C:\System\WinSrvLog\MSSQL'
        if (-not (Test-Path -LiteralPath $settingsDir)) {
            New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        }
        $settingsFile = Join-Path $settingsDir ("AlwaysOn_ClusterSettings_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('=' * 72)
        $lines.Add('AlwaysOn Setup – Cluster-Settings Sicherung')
        $lines.Add('Erstellt : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $lines.Add('=' * 72)
        $lines.Add('')
        $lines.Add('AG-Konfiguration:')
        $lines.Add("  Cluster       : $($Config.ClusterName)")
        $lines.Add("  AG-Name       : $($Config.AGName)")
        $lines.Add("  Listener-Name : $($Config.ListenerName)")
        $lines.Add("  Listener-IP   : $($Config.ListenerIP)")
        $lines.Add("  Listener-Port : $($Config.ListenerPort)")
        $lines.Add("  Endpoint-Port : $($Config.EndpointPort)")
        $lines.Add("  Failover-Modus: $($Config.FailoverMode)")
        $lines.Add("  Backup-Präf.  : $($Config.BackupPreference)")
        $lines.Add("  Test-DB       : $($Config.TestDatabase)")
        $lines.Add("  Backup-Share  : $($Config.BackupShare)")
        $lines.Add("  Service-Konto : $($Config.ServiceAccount)")
        $lines.Add('')
        $lines.Add('Nodes:')
        foreach ($nc in $activeNodes) {
            $lines.Add("  $($nc.SqlInstance)  |  Host: $($nc.Hostname)  |  AlwaysOn: $($nc.AlwaysOnStatus)")
        }
        $lines.Add('')
        $lines.Add('Cluster-Ressourcen (WSFC):')
        try {
            Get-ClusterGroup | ForEach-Object {
                $lines.Add("  Gruppe: $($_.Name.Trim())  |  Status: $($_.State)  |  Owner: $($_.OwnerNode.Trim())")
            }
        } catch { $lines.Add("  (nicht lesbar: $_)") }
        $lines.Add('')
        $lines.Add('Cluster-Nodes:')
        try {
            Get-ClusterNode | ForEach-Object {
                $lines.Add("  Node: $($_.Name.Trim())  |  Status: $($_.State)")
            }
        } catch { $lines.Add("  (nicht lesbar: $_)") }
        $lines.Add('')
        $lines.Add('=' * 72)

        $lines | Set-Content -LiteralPath $settingsFile -Encoding UTF8
        Write-RtfSuccess -Rtb $Rtb -Msg "Cluster-Settings gesichert: $settingsFile"
    } catch {
        Write-RtfWarn -Rtb $Rtb -Msg "Cluster-Settings konnten nicht gesichert werden: $_"
    }

     # ------------------------------------------------------------------ #
    # UPN-Konvertierung: user@domain.local  →  DOMAIN\user               #
    # Wird einmalig durchgeführt – alle Folgeschritte nutzen den          #
    # normalisierten DOMAIN\User-Format                                   #
    # ------------------------------------------------------------------ #
    # Original-UPN merken (fuer CREATE LOGIN Fallback bei Cross-Domain-Konten)
    $script:serviceAccountUpn = if ($Config.ServiceAccount -match '@') { $Config.ServiceAccount } else { $null }

    if ($Config.ServiceAccount -and $Config.ServiceAccount -match '@') {
        $upnUser   = $Config.ServiceAccount -replace '@.*$', ''
        $upnSuffix = $Config.ServiceAccount -replace '^[^@]+@', ''

        # NetBIOS-Domänenname der SERVICE-KONTO-Domäne ermitteln (nicht die des laufenden Users!)
        # Beispiel: SvcXY@bayernlb.sfinance.net -> NetBIOS-Name von bayernlb.sfinance.net = BLBMASTER
        $netBiosName = ''
        try {
            $domCtx  = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext(
                           'Domain', $upnSuffix)
            $adDomain    = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($domCtx)
            $netBiosName = $adDomain.GetDirectoryEntry().Properties['name'].Value
            if (-not $netBiosName) { throw 'Leer' }
        } catch {
            # Fallback: NetBIOS per Get-ADDomain versuchen
            try {
                $netBiosName = (Get-ADDomain -Server $upnSuffix -ErrorAction Stop).NetBIOSName
            } catch {
                # Letzter Fallback: ersten Teil des UPN-Suffixes (unzuverlaessig)
                $netBiosName = ($upnSuffix -split '\.')[0].ToUpper()
                Write-RtfWarn -Rtb $Rtb -Msg "  NetBIOS-Name nicht ermittelbar – Fallback: '$netBiosName' (aus UPN-Suffix, moeglicherweise falsch)"
            }
        }

        $converted = "$netBiosName\$upnUser"
        Write-RtfInfo -Rtb $Rtb -Msg "  UPN '$($Config.ServiceAccount)' konvertiert: '$converted' (NetBIOS: $netBiosName)"
        $Config.ServiceAccount = $converted
    }


    # ------------------------------------------------------------------ #
    # 1. Service-Konto ändern – NUR wenn gegenüber dem eingelesenen      #
    #    Originalwert tatsächlich ein anderes Konto eingetragen wurde     #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg 'Schritt 1: SQL-Service-Konto prüfen'

    $accountChanged = (
        $Config.ServiceAccount -and
        $script:originalServiceAccount -and
        ($Config.ServiceAccount.Trim() -ne $script:originalServiceAccount.Trim())
    )

    if (-not $Config.ServiceAccount) {
        Write-RtfWarn -Rtb $Rtb -Msg '  Kein Service-Konto angegeben – Schritt übersprungen.'
    } elseif (-not $accountChanged) {
        Write-RtfInfo -Rtb $Rtb -Msg "  Service-Konto '$($Config.ServiceAccount)' entspricht dem bereits eingetragenen Konto – kein Update erforderlich."
    } else {
        # Passwort-Prüfung nur wenn tatsächlich geschrieben wird
        if (-not $Config.ServicePassword) {
            Write-RtfError -Rtb $Rtb -Msg "  Neues Konto '$($Config.ServiceAccount)' angegeben, aber kein Passwort – Schritt übersprungen."
        } else {
            $secPwd = ConvertTo-SecureString $Config.ServicePassword -AsPlainText -Force
            foreach ($nc in $activeNodes) {
                try {
                    Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Konto wird von '$($script:originalServiceAccount)' auf '$($Config.ServiceAccount)' geändert ..."
                    $svcName = if ($nc.SqlInstance -match '\\') {
                        'MSSQL$' + ($nc.SqlInstance -split '\\')[1]
                    } else { 'MSSQLSERVER' }
                    $wmiSvc = Get-WmiObject -ComputerName $nc.Hostname -Class Win32_Service `
                              -Filter "Name='$svcName'" -ErrorAction Stop
                    $ret = $wmiSvc.Change($null,$null,$null,$null,$null,$null,
                                          $Config.ServiceAccount,$Config.ServicePassword)
                    if ($ret.ReturnValue -eq 0) {
                        $wmiSvc.StopService() | Out-Null
                        Start-Sleep -Seconds 3
                        $wmiSvc.StartService() | Out-Null
                        Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Service-Konto erfolgreich aktualisiert."
                    } else {
                        Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): WMI Change() ReturnValue=$($ret.ReturnValue)"
                    }
                } catch {
                    Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): Fehler beim Konto-Update – $_"
                }
            }
        }
    }

    # ------------------------------------------------------------------ #
    # 2. AlwaysOn / HADR aktivieren                                       #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg 'Schritt 2: HADR auf allen Nodes aktivieren'
    foreach ($nc in $activeNodes) {
        try {
            # HADR-Status per T-SQL
            $hadrResult = Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                -Query 'SELECT value_in_use FROM sys.configurations WHERE name = ''hadr enabled''' `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            $hadrEnabled = ($hadrResult -and $hadrResult.value_in_use -eq 1)

            if (-not $hadrEnabled) {
                Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): HADR wird aktiviert ..."
                # show advanced options in separatem Aufruf – RECONFIGURE muss wirksam sein
                # bevor sp_configure 'hadr enabled' aufgerufen wird
                Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred -ErrorAction Stop `
                    -Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;"
                Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred -ErrorAction Stop `
                    -Query "EXEC sp_configure 'hadr enabled', 1; RECONFIGURE;"

                $svcName = if ($nc.SqlInstance -match '\\') {
                    'MSSQL$' + ($nc.SqlInstance -split '\\')[1]
                } else { 'MSSQLSERVER' }
                $wmiSvc = Get-WmiObject -ComputerName $nc.Hostname -Class Win32_Service `
                          -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
                if ($wmiSvc) {
                    $wmiSvc.StopService() | Out-Null
                    Start-Sleep -Seconds 5
                    $wmiSvc.StartService() | Out-Null

                    # Warten bis SQL Server wirklich bereit ist – nicht nur gestartet
                    Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Warte auf SQL Server Bereitschaft ..."
                    $ready = $false
                    for ($w = 1; $w -le 24; $w++) {  # max. 2 Minuten
                        Start-Sleep -Seconds 5
                        try {
                            $ping = Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                                -Query 'SELECT 1 AS ok' -ErrorAction Stop |
                                Select-Object -First 1
                            if ($ping.ok -eq 1) { $ready = $true; break }
                        } catch { }
                    }
                    if ($ready) {
                        Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): HADR aktiviert – SQL Server bereit."
                    } else {
                        Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): SQL Server nach 2 Minuten noch nicht erreichbar."
                    }
                }
            } else {
                Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): HADR bereits aktiv – übersprungen."
            }
        } catch {
            Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): HADR-Aktivierung fehlgeschlagen – $_"
        }
    }

    # ------------------------------------------------------------------ #
    # 3. Mirroring-Endpoint anlegen                                       #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg "Schritt 3: Endpoint 'HADR_Endpoint' (Port $($Config.EndpointPort)) konfigurieren"
    foreach ($nc in $activeNodes) {
        try {
            # Endpoint per T-SQL prüfen
            $epCheck = Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                -Query "SELECT name FROM sys.endpoints WHERE type = 4" `
                -ErrorAction SilentlyContinue | Select-Object -First 1

            if (-not $epCheck) {
                Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Endpoint wird erstellt ..."
                # AUTHORIZATION setzt explizit den Endpoint-Eigentümer.
                # Ohne Klausel wäre es der aktuell ausführende Login –
                # beim SQL-Auth-Fallback der temporäre AGSetup_*-Login,
                # der am Ende gelöscht wird (verwaister Eigentümer).
                # Wir verwenden das Service-Konto wenn bekannt, sonst suchen wir einen gültigen sysadmin
                # (handhabe: 'sa' könnte umbenannt oder deaktiviert sein)
                $epOwner = Get-ValidSysAdminLogin -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred -PreferredLogin $Config.ServiceAccount
                Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred -ErrorAction Stop -Query @"
CREATE ENDPOINT [HADR_Endpoint]
    AUTHORIZATION [$epOwner]
    STATE = STARTED
    AS TCP (LISTENER_PORT = $($Config.EndpointPort))
    FOR DATABASE_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
"@
                Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Endpoint erstellt und gestartet."
            } else {
                # Sicherstellen dass Endpoint gestartet ist
                Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred -ErrorAction SilentlyContinue `
                    -Query "ALTER ENDPOINT [HADR_Endpoint] STATE = STARTED;"
                Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Endpoint bereits vorhanden – übersprungen."
            }
        } catch {
            Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): Endpoint-Fehler – $_"
        }
    }

    # ------------------------------------------------------------------ #
    # 4. Endpoint-Berechtigungen für Service-Konto                        #
    # ------------------------------------------------------------------ #
    if ($Config.ServiceAccount) {
        Write-RtfSection -Rtb $Rtb -Msg 'Schritt 4: Endpoint CONNECT-Berechtigung setzen'

        foreach ($nc in $activeNodes) {
            try {
                # Login prüfen – beide Formate (DOMAIN\User und UPN) abdecken
                $loginCheckSql = "SELECT name FROM sys.server_principals WHERE name IN (N'$($Config.ServiceAccount)'"
                if ($script:serviceAccountUpn) { $loginCheckSql += ", N'$($script:serviceAccountUpn)'" }
                $loginCheckSql += ')'
                $loginCheck = Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                    -Query $loginCheckSql -ErrorAction SilentlyContinue | Select-Object -First 1

                # Tatsächlich verwendeter Login-Name (fuer GRANT CONNECT)
                $actualLoginName = if ($loginCheck) { $loginCheck.name } else { $Config.ServiceAccount }

                if (-not $loginCheck) {
                    Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Login '$($Config.ServiceAccount)' wird angelegt ..."
                    $loginCreated = $false

                    # Versuch 1: DOMAIN\User Format
                    try {
                        Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                            -Query "CREATE LOGIN [$($Config.ServiceAccount)] FROM WINDOWS" `
                            -EnableException:$true
                        $actualLoginName = $Config.ServiceAccount
                        $loginCreated    = $true
                        Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Login angelegt (DOMAIN\User)."
                    } catch {
                        Write-RtfWarn -Rtb $Rtb -Msg "  $($nc.SqlInstance): DOMAIN\User nicht auflösbar ('$($_.Exception.Message -replace '\r?\n',' ')')"
                    }

                    # Versuch 2: UPN-Format (Cross-Domain-Fallback)
                    if (-not $loginCreated -and $script:serviceAccountUpn) {
                        Write-RtfWarn -Rtb $Rtb -Msg "  $($nc.SqlInstance): Versuche UPN-Format '$($script:serviceAccountUpn)' ..."
                        try {
                            Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                                -Query "CREATE LOGIN [$($script:serviceAccountUpn)] FROM WINDOWS" `
                                -EnableException:$true
                            $actualLoginName = $script:serviceAccountUpn
                            $loginCreated    = $true
                            Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Login angelegt (UPN-Format)."
                        } catch {
                            Write-RtfWarn -Rtb $Rtb -Msg "  $($nc.SqlInstance): UPN-Format ebenfalls nicht auflösbar – Cross-Domain AD-Lookup schlägt fehl."
                        }
                    }

                    # Versuch 3: Zertifikat-basierte Endpoint-Authentifizierung einrichten
                    if (-not $loginCreated) {
                        Write-RtfWarn -Rtb $Rtb -Msg "  $($nc.SqlInstance): Windows-Login nicht anlegbar. Endpoint wird auf Zertifikat-Authentifizierung umgestellt ..."
                        try {
                            _Set-HadrEndpointCertAuth -ActiveNodes $activeNodes -SqlCred $sqlCred -Rtb $Rtb -PrimaryInstance $primaryInstance
                            # Nach Zertifikat-Setup kein weiteres GRANT LOGIN nötig
                            continue
                        } catch {
                            Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): Zertifikat-Setup fehlgeschlagen – $_"
                            Write-RtfError -Rtb $Rtb -Msg "  MANUELL ERFORDERLICH: CREATE LOGIN + GRANT CONNECT ON ENDPOINT durch AD-Team"
                            continue
                        }
                    }
                } else {
                    Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Login '$actualLoginName' bereits vorhanden – übersprungen."
                }

                # Endpoint per T-SQL prüfen, dann CONNECT grantieren
                $epExists = Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                    -Query "SELECT name FROM sys.endpoints WHERE type = 4" `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($epExists) {
                    try {
                        Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                            -Query "GRANT CONNECT ON ENDPOINT::[HADR_Endpoint] TO [$actualLoginName]" `
                            -EnableException:$true
                        Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): CONNECT-Berechtigung gesetzt für '$actualLoginName'."
                    } catch {
                        Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): GRANT CONNECT fehlgeschlagen – $_"
                    }
                }
            } catch {
                Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): Fehler in Schritt 4 – $_"
            }
        }
    }

    # ------------------------------------------------------------------ #
    # 5. Test-Datenbank auf Primary anlegen                               #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg "Schritt 5: Testdatenbank '$($Config.TestDatabase)' erstellen"
    try {
        $dbCheck = Invoke-DbaQuery -SqlInstance $primaryInstance -SqlCredential $sqlCred `
            -Query "SELECT name FROM sys.databases WHERE name = N'$($Config.TestDatabase)'" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dbCheck) {
            Write-RtfInfo -Rtb $Rtb -Msg "  Datenbank wird angelegt ..."
            Invoke-DbaQuery -SqlInstance $primaryInstance -SqlCredential $sqlCred -ErrorAction Stop `
                -Query "CREATE DATABASE [$($Config.TestDatabase)];"
            Write-RtfSuccess -Rtb $Rtb -Msg "  Datenbank '$($Config.TestDatabase)' erstellt."
        } else {
            Write-RtfInfo -Rtb $Rtb -Msg "  Datenbank '$($Config.TestDatabase)' bereits vorhanden."
        }

        # Recovery-Modell auf FULL setzen
        Write-RtfInfo -Rtb $Rtb -Msg "  Recovery-Modell wird auf FULL gesetzt ..."
        Invoke-DbaQuery -SqlInstance $primaryInstance -SqlCredential $sqlCred -ErrorAction Stop `
            -Query "ALTER DATABASE [$($Config.TestDatabase)] SET RECOVERY FULL;"
        Write-RtfSuccess -Rtb $Rtb -Msg "  Recovery-Modell: FULL"

        # Initial-Backup per T-SQL
        Write-RtfInfo -Rtb $Rtb -Msg "  Initiales Full-Backup wird erstellt ..."
        $backupFile = "$($Config.BackupShare)\$($Config.TestDatabase)_init.bak"
        Invoke-DbaQuery -SqlInstance $primaryInstance -SqlCredential $sqlCred -ErrorAction Stop `
            -Query "BACKUP DATABASE [$($Config.TestDatabase)] TO DISK = N'$backupFile' WITH INIT, STATS = 10;"
        Write-RtfSuccess -Rtb $Rtb -Msg "  Backup erfolgreich: $backupFile"
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "  Datenbankvorb. fehlgeschlagen – $_"
    }

    # ------------------------------------------------------------------ #
    # 6. Availability Group anlegen                                       #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg "Schritt 6: Availability Group '$($Config.AGName)' erstellen"
    try {
        $agCheck = Invoke-DbaQuery -SqlInstance $primaryInstance -SqlCredential $sqlCred `
            -Query "SELECT name FROM sys.availability_groups WHERE name = N'$($Config.AGName)'" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($agCheck) {
            Write-RtfWarn -Rtb $Rtb -Msg "  AG '$($Config.AGName)' bereits vorhanden – Schritt übersprungen."
        } else {
            Write-RtfInfo -Rtb $Rtb -Msg "  AG wird per T-SQL angelegt ..."

            $failMode  = if ($Config.FailoverMode -eq 'Automatic') { 'AUTOMATIC' } else { 'MANUAL' }
            $availMode = if ($Config.FailoverMode -eq 'Automatic') { 'SYNCHRONOUS_COMMIT' } else { 'ASYNCHRONOUS_COMMIT' }
            $agName    = $Config.AGName
            $dbName    = $Config.TestDatabase
            $epPort    = $Config.EndpointPort

            $backupPref = switch ($Config.BackupPreference) {
                'Secondary'        { 'SECONDARY_ONLY' }
                'PreferSecondary'  { 'SECONDARY' }
                'None'             { 'NONE' }
                default            { 'PRIMARY' }
            }

            # WSFC-Gruppe prüfen und bereinigen
            # Wenn eine WSFC-Gruppe mit dem AG-Namen existiert aber keine SQL-AG dazu,
            # ist das ein Überrest eines fehlgeschlagenen Versuchs.
            # Lösung: WSFC-Gruppe löschen + Registry-Key HadrAgNameToldMap bereinigen,
            # dann CREATE AVAILABILITY GROUP neu anlegen.
            $wsfcGroup = Get-ClusterGroup -Name $agName -ErrorAction SilentlyContinue
            if ($wsfcGroup) {
                Write-RtfWarn -Rtb $Rtb -Msg "  Verwaiste WSFC-Gruppe '$agName' gefunden – wird bereinigt ..."

                # 1. WSFC-Gruppe offline nehmen und löschen
                try {
                    $wsfcGroup | Stop-ClusterGroup -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Seconds 2
                    Remove-ClusterGroup -Name $agName -RemoveResources -Force -ErrorAction Stop
                    Write-RtfSuccess -Rtb $Rtb -Msg "  WSFC-Gruppe '$agName' gelöscht."
                } catch {
                    Write-RtfWarn -Rtb $Rtb -Msg "  WSFC-Gruppe konnte nicht gelöscht werden: $_"
                }

                # 2. Registry-Key HadrAgNameToldMap auf allen Nodes bereinigen
                # Dieser Key mappt AG-Namen auf WSFC-Gruppen-IDs und verhindert Neuanlage
                foreach ($nc in $activeNodes) {
                    try {
                        Invoke-Command -ComputerName $nc.Hostname -ErrorAction Stop -ScriptBlock {
                            $regPath = 'HKLM:\Cluster\HadrAgNameToldMap'
                            if (Test-Path $regPath) {
                                $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                                $props.PSObject.Properties |
                                    Where-Object { $_.Name -notlike 'PS*' -and $_.Name -eq $using:agName } |
                                    ForEach-Object {
                                        Remove-ItemProperty -Path $regPath -Name $_.Name -ErrorAction SilentlyContinue
                                    }
                            }
                        }
                        Write-RtfSuccess -Rtb $Rtb -Msg "  Registry HadrAgNameToldMap auf '$($nc.Hostname)' bereinigt."
                    } catch {
                        Write-RtfWarn -Rtb $Rtb -Msg "  Registry auf '$($nc.Hostname)' nicht bereinigt: $_"
                    }
                }
                Start-Sleep -Seconds 3
            }

            # Replica-Definitionen – alle in einer REPLICA ON Klausel, kommagetrennt
            $replicaDefs = @()
            foreach ($nc in $activeNodes) {
                $fqhn = if ($nc.Hostname) { $nc.Hostname } else { ($nc.SqlInstance -split '\\')[0] }
                $replicaDefs += "N'$($nc.SqlInstance)' WITH (ENDPOINT_URL = N'TCP://$($fqhn):$($epPort)', FAILOVER_MODE = $failMode, AVAILABILITY_MODE = $availMode, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))"
            }
            $replicaClause = $replicaDefs -join ",`r`n    "

            # CLUSTER_TYPE = WSFC immer angeben – WSFC-Gruppe wurde ggf. oben bereinigt
            $createAgSql = @"
CREATE AVAILABILITY GROUP [$agName]
WITH (
    AUTOMATED_BACKUP_PREFERENCE = $backupPref,
    DB_FAILOVER = OFF,
    DTC_SUPPORT = NONE,
    CLUSTER_TYPE = WSFC,
    REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0
)
FOR DATABASE [$dbName]
REPLICA ON
    $replicaClause;
"@

            # Leere Zeilen bereinigen
            $createAgSql = ($createAgSql -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join "`r`n"

            # AG-Anlage per sqlcmd – garantiert frische Verbindung nach Dienst-Neustart.
            $sqlFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.sql'
            $createAgSql | Set-Content -Path $sqlFile -Encoding UTF8

            try {
                if ($sqlCred) {
                    $sqlOut = & sqlcmd -S $primaryInstance -U $sqlCred.UserName `
                        -P $sqlCred.GetNetworkCredential().Password `
                        -i $sqlFile -b 2>&1
                } else {
                    $sqlOut = & sqlcmd -S $primaryInstance -E -i $sqlFile -b 2>&1
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "sqlcmd ExitCode $LASTEXITCODE`: $($sqlOut -join ' ')"
                }
                Write-RtfSuccess -Rtb $Rtb -Msg "  AG '$agName' auf Primary angelegt."
            } finally {
                Remove-Item $sqlFile -ErrorAction SilentlyContinue
            }

            # Secondaries der AG beitreten lassen und Autoseed genehmigen
            foreach ($sec in $secondaries) {
                try {
                    Write-RtfInfo -Rtb $Rtb -Msg "  $($sec.SqlInstance): AG beitreten ..."
                    $joinSql = "ALTER AVAILABILITY GROUP [$agName] JOIN; ALTER AVAILABILITY GROUP [$agName] GRANT CREATE ANY DATABASE;"
                    if ($sqlCred) {
                        $joinOut = & sqlcmd -S $sec.SqlInstance -U $sqlCred.UserName `
                            -P $sqlCred.GetNetworkCredential().Password `
                            -Q $joinSql -b 2>&1
                    } else {
                        $joinOut = & sqlcmd -S $sec.SqlInstance -E -Q $joinSql -b 2>&1
                    }
                    if ($LASTEXITCODE -ne 0) {
                        throw "sqlcmd ExitCode $LASTEXITCODE`: $($joinOut -join ' ')"
                    }
                    Write-RtfSuccess -Rtb $Rtb -Msg "  $($sec.SqlInstance): Beigetreten, Autoseed genehmigt."
                } catch {
                    Write-RtfError -Rtb $Rtb -Msg "  $($sec.SqlInstance): Beitritt fehlgeschlagen – $_"
                }
            }

            # Failover-Modus auf Secondary explizit setzen (vom Primary aus).
            # CREATE AVAILABILITY GROUP setzt den Modus in der Definition, aber
            # beim JOIN kann SQL Server den Modus zuruecksetzen (besonders bei
            # Zertifikat-Auth oder verzoegerter Endpoint-Verbindung).
            # MODIFY REPLICA stellt sicher dass Primary UND Secondary denselben
            # konfigurierten Modus haben.
            foreach ($sec in $secondaries) {
                try {
                    $modifyReplicaSql = "ALTER AVAILABILITY GROUP [$agName] MODIFY REPLICA ON N'$($sec.SqlInstance)' WITH (FAILOVER_MODE = $failMode, AVAILABILITY_MODE = $availMode);"
                    Write-RtfInfo -Rtb $Rtb -Msg "  $($sec.SqlInstance): Failover-Modus auf '$failMode' setzen ..."
                    if ($sqlCred) {
                        $modOut = & sqlcmd -S $primaryInstance -U $sqlCred.UserName `
                            -P $sqlCred.GetNetworkCredential().Password `
                            -Q $modifyReplicaSql -b 2>&1
                    } else {
                        $modOut = & sqlcmd -S $primaryInstance -E -Q $modifyReplicaSql -b 2>&1
                    }
                    if ($LASTEXITCODE -ne 0) {
                        Write-RtfWarn -Rtb $Rtb -Msg "  $($sec.SqlInstance): MODIFY REPLICA fehlgeschlagen (nicht kritisch) – $($modOut -join ' ')"
                    } else {
                        Write-RtfSuccess -Rtb $Rtb -Msg "  $($sec.SqlInstance): Failover-Modus '$failMode' gesetzt."
                    }
                } catch {
                    Write-RtfWarn -Rtb $Rtb -Msg "  $($sec.SqlInstance): MODIFY REPLICA Fehler (nicht kritisch) – $_"
                }
            }

            Write-RtfSuccess -Rtb $Rtb -Msg "  AG '$agName' erfolgreich erstellt."
        }
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "  AG-Erstellung fehlgeschlagen – $_"
    }


    # ------------------------------------------------------------------ #
    # 7. Listener konfigurieren                                           #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg "Schritt 7: AG-Listener '$($Config.ListenerName)' konfigurieren"
    try {
        # Frische sqlcmd-Verbindung – umgeht dbaTools Connection-Cache nach Dienst-Neustart
        $agCheckSql = "SET NOCOUNT ON; SELECT COUNT(*) AS n FROM sys.availability_groups WHERE name = N'$($Config.AGName)';"
        $agCount = '0'
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            if ($sqlCred) {
                $agOut = & sqlcmd -S $primaryInstance -U $sqlCred.UserName `
                    -P $sqlCred.GetNetworkCredential().Password `
                    -Q $agCheckSql -h -1 -b 2>&1
            } else {
                $agOut = & sqlcmd -S $primaryInstance -E -Q $agCheckSql -h -1 -b 2>&1
            }
            $agCount = ($agOut | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1) -replace '\s',''
            if ($agCount -eq '1') { break }
            Write-RtfInfo -Rtb $Rtb -Msg "  AG noch nicht sichtbar – warte 10s (Versuch $attempt/6) ..."
            Start-Sleep -Seconds 10
        }

        if ($agCount -eq '1') {
            $lsnSql = "SET NOCOUNT ON; SELECT COUNT(*) AS n FROM sys.availability_group_listeners l JOIN sys.availability_groups ag ON ag.group_id = l.group_id WHERE ag.name = N'$($Config.AGName)';"
            if ($sqlCred) {
                $lsnOut = & sqlcmd -S $primaryInstance -U $sqlCred.UserName `
                    -P $sqlCred.GetNetworkCredential().Password `
                    -Q $lsnSql -h -1 -b 2>&1
            } else {
                $lsnOut = & sqlcmd -S $primaryInstance -E -Q $lsnSql -h -1 -b 2>&1
            }
            $lsnCount = ($lsnOut | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1) -replace '\s',''

            if ($lsnCount -ne '1') {
                if ($Config.ListenerIP -and $Config.ListenerPort) {
                    Write-RtfInfo -Rtb $Rtb -Msg "  Listener wird angelegt ..."
                    $subnetMask = '255.255.255.0'
                    $lsnCreateSql = "ALTER AVAILABILITY GROUP [$($Config.AGName)] ADD LISTENER N'$($Config.ListenerName)' (WITH IP ((N'$($Config.ListenerIP)', N'$subnetMask')), PORT = $($Config.ListenerPort));"
                    if ($sqlCred) {
                        $lsnCreate = & sqlcmd -S $primaryInstance -U $sqlCred.UserName `
                            -P $sqlCred.GetNetworkCredential().Password `
                            -Q $lsnCreateSql -b 2>&1
                    } else {
                        $lsnCreate = & sqlcmd -S $primaryInstance -E -Q $lsnCreateSql -b 2>&1
                    }
                    if ($LASTEXITCODE -eq 0) {
                        Write-RtfSuccess -Rtb $Rtb -Msg "  Listener '$($Config.ListenerName)' ($($Config.ListenerIP):$($Config.ListenerPort)) erstellt."
                    } else {
                        Write-RtfError -Rtb $Rtb -Msg "  Listener-Anlage fehlgeschlagen: $($lsnCreate -join ' ')"
                    }
                } else {
                    Write-RtfWarn -Rtb $Rtb -Msg "  Listener-IP oder -Port fehlen – übersprungen."
                }
            } else {
                Write-RtfInfo -Rtb $Rtb -Msg "  Listener bereits vorhanden – übersprungen."
            }
        } else {
            Write-RtfWarn -Rtb $Rtb -Msg "  AG nach 60s noch nicht sichtbar – Listener-Schritt übersprungen."
        }
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "  Listener-Konfiguration fehlgeschlagen – $_"
    }


    # ------------------------------------------------------------------ #
    # 8. AG-Sync Job auf allen Nodes anlegen                             #
    #    Synchronisiert Logins, Agent-Jobs und Linked Server vom Primary  #
    #    zum Secondary. Laeuft auf beiden Nodes, prueft selbst ob Primary. #
    #    Named Instance sicher: Instanzname beim Anlegen eingebettet.    #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg 'Schritt 8: AG-Sync Job anlegen'
    try {
        # Job-Name: INI-Wert wenn gesetzt, sonst Standardname
        $jobNameDefault = 'AG Sync - Logins, Jobs, LinkedServer'
        $jobName = if ($script:iniConfig['AG_SYNC_JOB_NAME']) {
            $script:iniConfig['AG_SYNC_JOB_NAME']
        } else {
            $jobNameDefault
        }
        Write-RtfInfo -Rtb $Rtb -Msg "  Job-Name: '$jobName'$(if ($script:iniConfig['AG_SYNC_JOB_NAME']) {' (aus INI)'} else {' (Standardname)'})"
        $jobCategory = 'Database Maintenance'
        $jobDesc     = 'Synchronisiert Logins, Agent-Jobs und Linked Server vom Primary zum Secondary. Wird auf allen AG-Nodes ausgefuehrt, laeuft aber nur auf dem aktuellen Primary.'
        $jobSchedule = 'AG Sync täglich 02:00'

        foreach ($nc in $activeNodes) {
            try {
                # Gegenknoten ermitteln (alle anderen Nodes)
                $otherInstances = ($activeNodes |
                    Where-Object { $_.SqlInstance -ne $nc.SqlInstance } |
                    ForEach-Object { $_.SqlInstance }) -join "','"

                # Instanznamen fest einbetten – Named Instance sicher
                $thisInst  = $nc.SqlInstance
                $jobScript = @"
Import-Module dbatools -ErrorAction Stop

# Instanznamen beim Job-Anlegen eingebettet (Named Instance sicher)
`$thisInstance   = '$thisInst'
`$otherInstances = @('$otherInstances')

# Nur auf dem aktuellen Primary ausfuehren
try {
    `$primary = (Invoke-DbaQuery -SqlInstance `$thisInstance ``
        -Query 'SELECT primary_replica FROM sys.dm_hadr_availability_group_states' ``
        -ErrorAction Stop).primary_replica
} catch {
    Write-Output "Fehler bei Primary-Ermittlung: `$_"; exit 1
}

if (`$thisInstance -ne `$primary) {
    Write-Output "Dieser Node (`$thisInstance) ist nicht Primary (`$primary) - kein Sync noetig."; exit 0
}

# Sync zu allen Secondary-Nodes
foreach (`$dest in `$otherInstances) {
    Write-Output "Sync von `$thisInstance nach `$dest ..."
    try {
        Copy-DbaLogin        -Source `$thisInstance -Destination `$dest ``
                             -SyncSysDbPermissions -ExcludeSystemLogin -EnableException
        Write-Output "  Logins: OK"
    } catch { Write-Output "  Logins: FEHLER - `$_" }
    try {
        Copy-DbaAgentJob     -Source `$thisInstance -Destination `$dest ``
                             -ExcludeJob 'AG Sync*' -EnableException
        Write-Output "  Agent-Jobs: OK"
    } catch { Write-Output "  Agent-Jobs: FEHLER - `$_" }
    try {
        Copy-DbaLinkedServer -Source `$thisInstance -Destination `$dest ``
                             -EnableException
        Write-Output "  Linked Server: OK"
    } catch { Write-Output "  Linked Server: FEHLER - `$_" }
    Write-Output "Sync nach `$dest abgeschlossen."
}
"@

                # Job bereits vorhanden?
                $jobExists = Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                    -Query "SELECT name FROM msdb.dbo.sysjobs WHERE name = N'$jobName'" `
                    -ErrorAction SilentlyContinue | Select-Object -First 1

                if ($jobExists) {
                    Write-RtfInfo -Rtb $Rtb -Msg "  $($nc.SqlInstance): Job '$jobName' bereits vorhanden – wird aktualisiert."
                    Remove-DbaAgentJob -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                        -Job $jobName -Confirm:$false -EnableException
                }

                # Job anlegen
                # Verwende gültigen sysadmin als Owner (handhabe: 'sa' könnte umbenannt/deaktiviert sein)
                $jobOwner = Get-ValidSysAdminLogin -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred -PreferredLogin $Config.ServiceAccount
                $job = New-DbaAgentJob -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                    -Job $jobName -Description $jobDesc -Category $jobCategory `
                    -OwnerLogin $jobOwner -EnableException

                # Job-Step anlegen (PowerShell)
                New-DbaAgentJobStep -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                    -Job $jobName -StepName 'AG Sync via dbatools' `
                    -Subsystem PowerShell -Command $jobScript `
                    -OnSuccessAction QuitWithSuccess -OnFailAction QuitWithFailure `
                    -EnableException | Out-Null

                # Zeitplan: täglich 02:00 Uhr
                $schedExists = Invoke-DbaQuery -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                    -Query "SELECT name FROM msdb.dbo.sysschedules WHERE name = N'$jobSchedule'" `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $schedExists) {
                    New-DbaAgentSchedule -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                        -Job $jobName -Schedule $jobSchedule `
                        -FrequencyType Daily -FrequencyInterval 1 `
                        -StartTime '020000' -EnableException | Out-Null
                } else {
                    Set-DbaAgentJobSchedule -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                        -Job $jobName -ScheduleName $jobSchedule -Enabled -EnableException | Out-Null
                }

                # Job aktivieren
                Set-DbaAgentJob -SqlInstance $nc.SqlInstance -SqlCredential $sqlCred `
                    -Job $jobName -Enabled -EnableException | Out-Null

                Write-RtfSuccess -Rtb $Rtb -Msg "  $($nc.SqlInstance): Job '$jobName' angelegt (täglich 02:00)."

            } catch {
                Write-RtfError -Rtb $Rtb -Msg "  $($nc.SqlInstance): Job-Anlage fehlgeschlagen – $_"
            }
        }
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "  AG-Sync Job fehlgeschlagen – $_"
    }


    # ------------------------------------------------------------------ #
    # 9. Abschlussstatus per T-SQL                                        #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg 'Schritt 9: Konfiguration abgeschlossen – Status'
    Start-Sleep -Seconds 5   # AG-DMVs kurz Zeit geben sich zu füllen
    try {
        $agStatus = Invoke-DbaQuery -SqlInstance $primaryInstance -SqlCredential $sqlCred `
            -Query "SELECT ag.name, ags.primary_replica, ags.synchronization_health_desc
                    FROM sys.availability_groups ag
                    JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
                    WHERE ag.name = N'$($Config.AGName)'" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($agStatus) {
            Write-RtfSuccess -Rtb $Rtb -Msg "AG '$($agStatus.name)'  |  Sync: $($agStatus.synchronization_health_desc)  |  Primary: $($agStatus.primary_replica)"
        } else {
            Write-RtfWarn -Rtb $Rtb -Msg "AG-Status noch nicht abfragbar – Seeding läuft möglicherweise noch."
        }
        $replicas = Invoke-DbaQuery -SqlInstance $primaryInstance -SqlCredential $sqlCred `
            -Query "SELECT ar.replica_server_name, ars.role_desc, ars.synchronization_state_desc
                    FROM sys.availability_replicas ar
                    JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
                    JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
                    WHERE ag.name = N'$($Config.AGName)'" `
            -ErrorAction SilentlyContinue
        foreach ($r in $replicas) {
            Write-RtfInfo -Rtb $Rtb -Msg "  Replica: $($r.replica_server_name)  |  Rolle: $($r.role_desc)  |  Sync: $($r.synchronization_state_desc)"
        }
    } catch {
        Write-RtfWarn -Rtb $Rtb -Msg "Status-Abfrage fehlgeschlagen – $_"
    }

    $BtnOK.Enabled = $true
    Write-RtfSuccess -Rtb $Rtb -Msg 'Fertig.'

    # ------------------------------------------------------------------ #
    # 10. SPN-Prüfung via setspn                                          #
    # ------------------------------------------------------------------ #
    Write-RtfSection -Rtb $Rtb -Msg 'Schritt 10: SPN-Prüfung'
    try {
        # Dienstkonto ermitteln – aktuelles Konto aus Konfiguration oder Original
        $spnAccount = if ($Config.ServiceAccount) { $Config.ServiceAccount } else { $script:originalServiceAccount }

        if (-not $spnAccount) {
            Write-RtfWarn -Rtb $Rtb -Msg '  Kein Dienstkonto bekannt – SPN-Prüfung übersprungen.'
        } else {
            Write-RtfInfo -Rtb $Rtb -Msg "  Prüfe SPNs für Konto: $spnAccount"

            # setspn -L gibt alle registrierten SPNs des Kontos zurück
            $setspnOutput = & setspn -L $spnAccount 2>&1
            $registeredSpns = $setspnOutput |
                Where-Object { $_ -match 'MSSQLSvc' } |
                ForEach-Object { $_.Trim().ToLower() }

            Write-RtfInfo -Rtb $Rtb -Msg "  Gefundene MSSQLSvc-SPNs: $(if($registeredSpns){"$($registeredSpns.Count)"}else{'keine'})"

            # Erwartete SPNs berechnen: pro Node je FQDN+Port und Hostname+Port
            # sowie für den Listener
            $missingSpns  = [System.Collections.Generic.List[string]]::new()
            $sqlPort      = 1433   # Standard SQL-Port – bei benannten Instanzen ggf. anpassen

            # DNS-Suffix der Domäne ermitteln
            $dnsSuffix = ''
            try {
                $dnsSuffix = ([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()).DomainName
            } catch { }

            $checkTargets = [System.Collections.Generic.List[string]]::new()

            # Nodes
            foreach ($nc in $activeNodes) {
                if (-not $nc.Hostname) { continue }
                $hostShort = $nc.Hostname.ToLower()
                $checkTargets.Add("MSSQLSvc/${hostShort}:${sqlPort}")
                if ($dnsSuffix) {
                    $checkTargets.Add("MSSQLSvc/${hostShort}.${dnsSuffix}:${sqlPort}")
                }
            }

            # Listener
            if ($Config.ListenerName) {
                $ln = $Config.ListenerName.ToLower()
                $lp = $Config.ListenerPort
                $checkTargets.Add("MSSQLSvc/${ln}:${lp}")
                if ($dnsSuffix) {
                    $checkTargets.Add("MSSQLSvc/${ln}.${dnsSuffix}:${lp}")
                }
            }

            foreach ($expected in $checkTargets) {
                $found = $registeredSpns | Where-Object { $_ -eq $expected.ToLower() }
                if ($found) {
                    Write-RtfSuccess -Rtb $Rtb -Msg "  OK  $expected"
                } else {
                    Write-RtfWarn -Rtb $Rtb -Msg "  FEHLT  $expected"
                    $missingSpns.Add($expected)
                }
            }

            # Fehlende SPNs – Ausgabe im Log und Textdatei für AD-Team
            if ($missingSpns.Count -gt 0) {
                Write-RtfSection -Rtb $Rtb -Msg "SPN-Befehle – Ausführung durch AD-Team erforderlich"
                Write-RtfWarn   -Rtb $Rtb -Msg "  $($missingSpns.Count) SPN(s) fehlen. Ohne korrekte SPNs schlägt die"
                Write-RtfWarn   -Rtb $Rtb -Msg "  Windows-Authentifizierung mit SSPI-Kontextfehler fehl."
                Write-RtfInfo   -Rtb $Rtb -Msg "  Folgende Befehle müssen durch einen Domänen-Admin ausgeführt werden:"
                Write-RtfInfo   -Rtb $Rtb -Msg ""
                foreach ($spn in $missingSpns) {
                    $cmd = "setspn -S $spn $spnAccount"
                    Write-RtfLog -Rtb $Rtb -Message "  $cmd" `
                        -Color ([System.Drawing.Color]::FromArgb(180, 255, 180)) -Bold
                }
                Write-RtfInfo -Rtb $Rtb -Msg ""
                Write-RtfInfo -Rtb $Rtb -Msg "  Prüfung nach dem Setzen:"
                Write-RtfLog  -Rtb $Rtb -Message "  setspn -L $spnAccount" `
                    -Color ([System.Drawing.Color]::FromArgb(180, 255, 180)) -Bold

                # ---- Textdatei für AD-Team erstellen ----
                try {
                    $spnDir  = 'C:\System\WinSrvLog\MSSQL'
                    if (-not (Test-Path -LiteralPath $spnDir)) {
                        New-Item -ItemType Directory -Path $spnDir -Force | Out-Null
                    }
                    $spnFile = Join-Path $spnDir ("AlwaysOn_SPN_ADTeam_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

                    $adLines = [System.Collections.Generic.List[string]]::new()
                    $adLines.Add('=' * 72)
                    $adLines.Add('SPN-Anforderung fuer SQL Server AlwaysOn')
                    $adLines.Add('Erstellt: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
                    $adLines.Add('Cluster : ' + $Config.ClusterName)
                    $adLines.Add('AG-Name : ' + $Config.AGName)
                    $adLines.Add('Konto   : ' + $spnAccount)
                    $adLines.Add('=' * 72)
                    $adLines.Add('')
                    $adLines.Add('Hintergrund:')
                    $adLines.Add('  Fuer SQL Server AlwaysOn mit Windows-Authentifizierung (Kerberos)')
                    $adLines.Add('  muessen fuer das SQL-Dienstkonto Service Principal Names (SPNs)')
                    $adLines.Add('  im Active Directory registriert sein. Die folgenden SPNs fehlen')
                    $adLines.Add('  und muessen durch einen Domänen-Admin gesetzt werden.')
                    $adLines.Add('')
                    $adLines.Add('Ausfuehren als Domänen-Admin (eine Zeile pro Befehl):')
                    $adLines.Add('-' * 72)
                    foreach ($spn in $missingSpns) {
                        $adLines.Add("setspn -S $spn $spnAccount")
                    }
                    $adLines.Add('-' * 72)
                    $adLines.Add('')
                    $adLines.Add('Prüfung nach dem Setzen:')
                    $adLines.Add("  setspn -L $spnAccount")
                    $adLines.Add('')
                    $adLines.Add('Erwartete Ausgabe: Alle oben aufgeführten SPNs müssen gelistet sein.')
                    $adLines.Add('')
                    $adLines.Add('Bei Rückfragen: SQL-DBA-Team')
                    $adLines.Add('=' * 72)

                    $adLines | Set-Content -LiteralPath $spnFile -Encoding UTF8
                    Write-RtfSuccess -Rtb $Rtb -Msg "  AD-Team Anforderungsdatei gespeichert: $spnFile"
                    $statusLabel.Text = "SPN-Datei: $spnFile"
                } catch {
                    Write-RtfError -Rtb $Rtb -Msg "  AD-Team Datei konnte nicht geschrieben werden: $_"
                }
            } else {
                Write-RtfSuccess -Rtb $Rtb -Msg "  Alle erwarteten SPNs sind registriert – kein SSPI-Problem zu erwarten."
            }
        }
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "  SPN-Prüfung fehlgeschlagen: $_"
    }

    # ------------------------------------------------------------------ #
    # Cleanup: Temporäres Setup-Login entfernen (falls angelegt)          #
    # ------------------------------------------------------------------ #
    if ($script:setupLoginName) {
        Write-RtfSection -Rtb $Rtb -Msg 'Cleanup: Temporäres SQL-Login entfernen'
        Remove-SetupCredential -SqlCred $sqlCred -Rtb $Rtb
    }

    # ------------------------------------------------------------------ #
    # Logfile automatisch schreiben                                        #
    # ------------------------------------------------------------------ #
    $logDir = 'C:\System\WinSrvLog\MSSQL'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $logFile = Join-Path $logDir ("AlwaysOn_Setup_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $Rtb.Lines | Set-Content -LiteralPath $logFile -Encoding UTF8
        Write-RtfInfo -Rtb $Rtb -Msg "Logfile gespeichert: $logFile"
        $statusLabel.Text = "Logfile: $logFile"
    } catch {
        Write-RtfError -Rtb $Rtb -Msg "Logfile konnte nicht geschrieben werden: $_"
    }
}

# ===========================================================================
# WinForms Hauptfenster
# ===========================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = 'SQL Server AlwaysOn Setup Tool'
$form.Size            = New-Object System.Drawing.Size(1200, 780)
$form.StartPosition   = 'CenterScreen'
$form.MinimumSize     = New-Object System.Drawing.Size(900, 600)
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

# ---- Toolbar ----
$toolStrip = New-Object System.Windows.Forms.ToolStrip
$toolStrip.Dock = 'Top'

$tsBtnLoad = New-Object System.Windows.Forms.ToolStripButton
$toolStrip.Items.Add($tsBtnLoad) | Out-Null

$toolStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$tsBtnValidate = New-Object System.Windows.Forms.ToolStripButton
$toolStrip.Items.Add($tsBtnValidate) | Out-Null

$toolStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$tsBtnReset = New-Object System.Windows.Forms.ToolStripButton
$tsBtnReset.Enabled = $false
$toolStrip.Items.Add($tsBtnReset) | Out-Null

$toolStrip.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$tsBtnLang = New-Object System.Windows.Forms.ToolStripButton
$tsBtnLang.ToolTipText = 'Switch language / Sprache wechseln'
$toolStrip.Items.Add($tsBtnLang) | Out-Null

$form.Controls.Add($toolStrip)

# ---- TabControl (Erweiterungspunkt für künftige Tabs) ----
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = 'Fill'
$form.Controls.Add($tabControl)

$tabKonfig = New-Object System.Windows.Forms.TabPage
$tabKonfig.Padding = New-Object System.Windows.Forms.Padding(4)
$tabControl.TabPages.Add($tabKonfig)

# ---- Hauptlayout: SplitContainer (liegt jetzt in der TabPage) ----
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock        = 'Fill'
$split.Orientation = 'Vertical'
# Panel1MinSize vor dem Hinzufügen setzen – Panel2MinSize und SplitterDistance
# erst danach, da .NET die SplitterDistance gegen die Gesamtbreite validiert.

$tabKonfig.Controls.Add($split)
$split.Panel1MinSize = 200
#$split.Panel2MinSize    = 200
$split.SplitterDistance = 420

# ---- Linke Seite: PropertyGrid + Buttons ----
$panelLeft = New-Object System.Windows.Forms.Panel
$panelLeft.Dock = 'Fill'
$split.Panel1.Controls.Add($panelLeft)

$lblGrid = New-Object System.Windows.Forms.Label
$lblGrid.Dock     = 'Top'
$lblGrid.Height   = 24
$lblGrid.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblGrid.TextAlign = 'MiddleLeft'
$panelLeft.Controls.Add($lblGrid)

$propGrid = New-Object System.Windows.Forms.PropertyGrid
$propGrid.Dock          = 'Fill'
$propGrid.PropertySort  = 'Categorized'
$propGrid.HelpVisible   = $true
$panelLeft.Controls.Add($propGrid)

$panelButtons = New-Object System.Windows.Forms.Panel
$panelButtons.Dock   = 'Bottom'
$panelButtons.Height = 42
$panelLeft.Controls.Add($panelButtons)

$btnOK = New-Object System.Windows.Forms.Button
$btnOK.Size     = New-Object System.Drawing.Size(220, 32)
$btnOK.Location = New-Object System.Drawing.Point(6, 5)
$btnOK.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnOK.ForeColor = [System.Drawing.Color]::White
$btnOK.FlatStyle = 'Flat'
$btnOK.Enabled  = $false
$panelButtons.Controls.Add($btnOK)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Size     = New-Object System.Drawing.Size(100, 32)
$btnClose.Location = New-Object System.Drawing.Point(234, 5)
$btnClose.FlatStyle = 'Flat'
$panelButtons.Controls.Add($btnClose)

$btnContinue = New-Object System.Windows.Forms.Button
$btnContinue.Size      = New-Object System.Drawing.Size(120, 32)
$btnContinue.Location  = New-Object System.Drawing.Point(342, 5)
$btnContinue.BackColor = [System.Drawing.Color]::FromArgb(0, 160, 80)
$btnContinue.ForeColor = [System.Drawing.Color]::White
$btnContinue.FlatStyle = 'Flat'
$btnContinue.Visible   = $false
$btnContinue.Enabled   = $false
$panelButtons.Controls.Add($btnContinue)

# ---- Rechte Seite: RTF-Box ----
$panelRight = New-Object System.Windows.Forms.Panel
$panelRight.Dock = 'Fill'
$split.Panel2.Controls.Add($panelRight)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Dock      = 'Top'
$lblLog.Height    = 24
$lblLog.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblLog.TextAlign = 'MiddleLeft'
$panelRight.Controls.Add($lblLog)

$rtfBox = New-Object System.Windows.Forms.RichTextBox
$rtfBox.Dock      = 'Fill'
$rtfBox.ReadOnly  = $true
$rtfBox.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$rtfBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$rtfBox.Font      = New-Object System.Drawing.Font('Consolas', 10)
$rtfBox.ScrollBars = 'Vertical'
$panelRight.Controls.Add($rtfBox)

$panelRtfButtons = New-Object System.Windows.Forms.Panel
$panelRtfButtons.Dock   = 'Bottom'
$panelRtfButtons.Height = 42
$panelRight.Controls.Add($panelRtfButtons)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Size     = New-Object System.Drawing.Size(140, 32)
$btnClearLog.Location = New-Object System.Drawing.Point(6, 5)
$btnClearLog.FlatStyle = 'Flat'
$panelRtfButtons.Controls.Add($btnClearLog)

$btnSaveLog = New-Object System.Windows.Forms.Button
$btnSaveLog.Size     = New-Object System.Drawing.Size(160, 32)
$btnSaveLog.Location = New-Object System.Drawing.Point(154, 5)
$btnSaveLog.FlatStyle = 'Flat'
$panelRtfButtons.Controls.Add($btnSaveLog)

# ---------------------------------------------------------------------------
# Status-Label unten
# ---------------------------------------------------------------------------
$statusBar = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusBar.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusBar)

# ---------------------------------------------------------------------------
# Initialize UI with current language
# ---------------------------------------------------------------------------
Update-UILanguage
$statusLabel.Text = T 'StatusReady'

# ---------------------------------------------------------------------------
# Script-globale Config-Variable
# ---------------------------------------------------------------------------
$script:agConfig               = $null
$script:originalServiceAccount = ''   # Beim Einlesen gesetzter Referenzwert

# ---------------------------------------------------------------------------
# Funktion: Daten laden und PropertyGrid befüllen
# ---------------------------------------------------------------------------
function Invoke-LoadData {
    $btnOK.Enabled = $false
    $statusLabel.Text = T 'StatusReadingCluster'
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $rawInfo = Get-ClusterAndSqlInfo -Rtb $rtfBox

        $script:rawClusterInfo = $rawInfo   # Originalwerte fuer Reset-Button
        $script:agConfig = New-Object AgConfig
        $script:agConfig.ClusterName     = $rawInfo['ClusterName']
        $script:agConfig.ListenerName    = $rawInfo['ListenerName']
        $script:agConfig.ListenerIP      = $rawInfo['ListenerIP']
        $script:agConfig.ListenerPort    = [int]$rawInfo['ListenerPort']
        $script:agConfig.AGName          = $rawInfo['AGName']
        $script:agConfig.EndpointPort    = [int]$rawInfo['EndpointPort']
        $script:agConfig.FailoverMode    = $rawInfo['FailoverMode']
        $script:agConfig.BackupPreference = 'Primary'
        $script:agConfig.TestDatabase    = $rawInfo['TestDatabase']
        $script:agConfig.BackupShare     = $rawInfo['BackupShare']
        $script:agConfig.ServiceAccount  = $rawInfo['ServiceAccount']
        $script:agConfig.ServicePassword = ''

        # Originalwert für späteren Änderungsvergleich sichern
        $script:originalServiceAccount   = $rawInfo['OriginalServiceAccount']

        # Node-Objekte
        $nodes = @($rawInfo['Node1'], $rawInfo['Node2'], $rawInfo['Node3'])
        $insts = @($rawInfo['SqlInstance1'], $rawInfo['SqlInstance2'], $rawInfo['SqlInstance3'])
        $aoSplit = $rawInfo['AlwaysOnStatus'] -split '\|'

        for ($i = 0; $i -lt 3; $i++) {
            if ($nodes[$i]) {
                $nc = New-Object NodeConfig
                $nc.Hostname      = $nodes[$i].Trim()
                $nc.SqlInstance   = $insts[$i].Trim()
                $nc.AlwaysOnStatus = if ($aoSplit.Count -gt $i) { $aoSplit[$i].Trim() } else { 'N/A' }
                switch ($i) {
                    0 { $script:agConfig.Node1 = $nc }
                    1 { $script:agConfig.Node2 = $nc }
                    2 { $script:agConfig.Node3 = $nc }
                }
            }
        }

        $propGrid.SelectedObject = $script:agConfig
        $propGrid.ExpandAllGridItems()
        $btnOK.Enabled = $true
        $tsBtnReset.Enabled = $true
        $statusLabel.Text = T 'StatusEntering' -f $rawInfo['ClusterName']
    } catch {
        Write-RtfError -Rtb $rtfBox -Msg "$(T 'ErrorDatabaseFailed' -f $_)"
        $statusLabel.Text = T 'StatusReadError'
    }
}

# ---------------------------------------------------------------------------
# Event-Handler
# ---------------------------------------------------------------------------

# Toolbar: Neu einlesen
$tsBtnLoad.Add_Click({ Invoke-LoadData })

# Toolbar: Language switch
$tsBtnLang.Add_Click({
    $script:CurrentLang = if ($script:CurrentLang -eq 'DE') { 'EN' } else { 'DE' }
    Update-UILanguage
    $statusLabel.Text = T 'StatusReady'
})

# Toolbar: AD-Konto prüfen
$tsBtnValidate.Add_Click({
    if (-not $script:agConfig -or -not $script:agConfig.ServiceAccount) {
        [System.Windows.Forms.MessageBox]::Show(
            (T 'MsgNoAccount'),
            (T 'MsgTitleAccountCheck'), 'OK', 'Warning') | Out-Null
        return
    }
    $statusLabel.Text = T 'StatusADCheck' -f $script:agConfig.ServiceAccount
    [System.Windows.Forms.Application]::DoEvents()
    Write-RtfInfo -Rtb $rtfBox -Msg (T 'InfoADCheckFor' -f $script:agConfig.ServiceAccount)
    $result = Test-ADAccount -AccountName $script:agConfig.ServiceAccount
    if ($result.Found) {
        Write-RtfSuccess -Rtb $rtfBox -Msg (T 'InfoAccountFound' -f $result.DisplayName, $result.UPN)
        $statusLabel.Text = T 'StatusAccountValid' -f $script:agConfig.ServiceAccount
        [System.Windows.Forms.MessageBox]::Show(
            (T 'MsgAccountFound' -f $result.DisplayName, $result.UPN),
            (T 'MsgTitleADCheck'), 'OK', 'Information') | Out-Null
    } else {
        $errMsg = if ($result.Error) { $result.Error } else { T 'ErrorAccountNotInAD' }
        Write-RtfError -Rtb $rtfBox -Msg "  $(T 'ErrorADCheckFailed' -f $errMsg)"
        $statusLabel.Text = T 'StatusAccountNotFound' -f $script:agConfig.ServiceAccount
        [System.Windows.Forms.MessageBox]::Show(
            (T 'MsgAccountNotFound' -f $errMsg),
            (T 'MsgTitleADCheck'), 'OK', 'Warning') | Out-Null
    }
})

# OK-Button: Konfiguration starten
$btnOK.Add_Click({
    if (-not $script:agConfig) { return }

    # Pflichtfeld-Prüfung
    if (-not $script:agConfig.AGName) {
        [System.Windows.Forms.MessageBox]::Show((T 'MsgAGNameRequired'), (T 'MsgTitleError'), 'OK', 'Error') | Out-Null
        return
    }
    if (-not $script:agConfig.ListenerName) {
        [System.Windows.Forms.MessageBox]::Show((T 'MsgListenerNameRequired'), (T 'MsgTitleError'), 'OK', 'Error') | Out-Null
        return
    }
    # Passwort nur prüfen wenn das Konto gegenüber dem Original geändert wurde
    $accountChanged = (
        $script:agConfig.ServiceAccount -and
        $script:originalServiceAccount -and
        ($script:agConfig.ServiceAccount.Trim() -ne $script:originalServiceAccount.Trim())
    )
    if ($accountChanged -and -not $script:agConfig.ServicePassword) {
        $dlg = [System.Windows.Forms.MessageBox]::Show(
            (T 'WarnConfirmPassword' -f $script:agConfig.ServiceAccount),
            (T 'MsgTitlePasswordMissing'), 'YesNo', 'Warning')
        if ($dlg -ne 'Yes') { return }
    }

    $kontoStatus = if ($accountChanged) {
        T 'MsgAccountChangeInfo' -f $script:originalServiceAccount, $script:agConfig.ServiceAccount
    } else {
        T 'MsgAccountNoChange' -f $script:agConfig.ServiceAccount
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        (T 'MsgConfigStarting' -f $script:agConfig.AGName, $script:agConfig.Node1.SqlInstance, $script:agConfig.EndpointPort, $script:agConfig.FailoverMode, $script:agConfig.TestDatabase, $kontoStatus),
        (T 'MsgTitleConfirm'), 'YesNo', 'Question')

    if ($confirm -eq 'Yes') {
        Start-AlwaysOnConfiguration -Config $script:agConfig -Rtb $rtfBox -BtnOK $btnOK
    }
})

# Schließen
$btnClose.Add_Click({ $form.Close() })

# Weiter – nach manuellem Login-Anlegen durch den Anwender
$btnContinue.Add_Click({
    $btnContinue.Enabled = $false
    $statusLabel.Text    = T 'StatusVerifying'

    # SQL-Login auf allen Nodes testen
    $cred    = $script:setupLoginCred
    $allOk   = $true
    $failed  = @()

    foreach ($instance in $script:setupLoginNodes) {
        try {
            $testConn = Connect-DbaInstance -SqlInstance $instance -SqlCredential $cred -ErrorAction Stop
            $testConn.ConnectionContext.Disconnect()
            Write-RtfSuccess -Rtb $rtfBox -Msg (T 'InfoSQLAuthSuccess' -f $instance)
        } catch {
            Write-RtfError -Rtb $rtfBox -Msg (T 'WarnSQLAuthFailedNode' -f $instance, $_)
            $failed += $instance
            $allOk = $false
        }
    }

    if (-not $allOk) {
        Write-RtfError -Rtb $rtfBox -Msg "$(T 'ErrorDatabaseFailed' -f (T 'WarnLoginRetry'))"
        Write-RtfWarn  -Rtb $rtfBox -Msg (T 'WarnLoginRetry')
        $btnContinue.Enabled = $true
        $statusLabel.Text    = T 'StatusSQLAuthFailed'
        return
    }

    # Alle Nodes erreichbar → Konfiguration fortsetzen
    $btnContinue.Visible = $false
    $statusLabel.Text    = T 'StatusConfigRunning'
    Write-RtfSuccess -Rtb $rtfBox -Msg (T 'InfoSQLAuthOnAllSuccess')

    Invoke-AlwaysOnSteps -Config $script:agConfig -Rtb $rtfBox -BtnOK $btnOK -SqlCred $cred
})

# Protokoll leeren
$btnClearLog.Add_Click({ $rtfBox.Clear() })

# Protokoll speichern
$btnSaveLog.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = T 'SaveDialogFilter'
    $dlg.FileName = T 'SaveDialogFileName' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    if ($dlg.ShowDialog() -eq 'OK') {
        if ($dlg.FileName -like '*.rtf') {
            $rtfBox.SaveFile($dlg.FileName, 'RichText')
        } else {
            $rtfBox.SaveFile($dlg.FileName, 'PlainText')
        }
        Write-RtfInfo -Rtb $rtfBox -Msg (T 'InfoLogfileSaved' -f $dlg.FileName)
    }
})

# Toolbar: Reset AG-Name und Listener-Name
$tsBtnReset.Add_Click({
    if (-not $script:agConfig -or -not $script:rawClusterInfo) { return }
    $script:agConfig.AGName       = $script:rawClusterInfo['AGName']
    $script:agConfig.ListenerName = $script:rawClusterInfo['ListenerName']
    $propGrid.Refresh()
    Write-RtfInfo -Rtb $rtfBox -Msg (T 'InfoResetDone')
})

# PropertyGrid: Änderung verfolgen (Konto-Warnung + IP-Check)
$propGrid.Add_PropertyValueChanged({
    param($sender, $e)
    if ($e.ChangedItem.PropertyDescriptor.Name -eq 'ServiceAccount') {
        $statusLabel.Text = T 'StatusServiceAccountChanged'
        Write-RtfWarn -Rtb $rtfBox -Msg (T 'WarnAccountValidationFailed' -f $script:agConfig.ServiceAccount)
    }
    if ($e.ChangedItem.PropertyDescriptor.Name -eq 'ListenerIP') {
        $ip = $script:agConfig.ListenerIP
        if ($ip) {
            try {
                $resolved = [System.Net.Dns]::GetHostEntry($ip)
                Write-RtfInfo -Rtb $rtfBox -Msg (T 'InfoIPCheckOK' -f $ip, $resolved.HostName)
            } catch {
                Write-RtfWarn -Rtb $rtfBox -Msg (T 'WarnIPCheckFail' -f $ip)
            }
        }
    }
})

# Form Shown: SplitterDistance beim ersten Anzeigen korrekt setzen (Fenster hat jetzt echte Breite)
$form.Add_Shown({
    $w = $split.Width
    if ($w -gt 0) {
        $target = [int]($w * 0.35)
        if ($target -gt $split.Panel1MinSize) {
            $split.SplitterDistance = $target
        }
    }
})

# Form Resize: SplitterDistance proportional halten (35 % linke Seite)
$form.Add_Resize({
    $w = $split.Width
    if ($w -gt 0) {
        $target = [int]($w * 0.35)
        if ($target -gt $split.Panel1MinSize -and ($w - $target) -gt $split.Panel2MinSize) {
            $split.SplitterDistance = $target
        }
    }
})

# Form Load: Modul-Status melden, ggf. Neustart fordern, dann Daten einlesen
$form.Add_Load({
    Write-RtfSection -Rtb $rtfBox -Msg (T 'SectionModuleReqs')

    # Modul-Fehler anzeigen
    if ($script:moduleErrors.Count -gt 0) {
        foreach ($err in $script:moduleErrors) {
            Write-RtfError -Rtb $rtfBox -Msg $err
        }
        $btnOK.Enabled = $false
        $statusLabel.Text = T 'StatusModuleError'
        [System.Windows.Forms.MessageBox]::Show(
            ($script:moduleErrors -join "`n`n"),
            (T 'MsgTitleModuleInstallFailed'), 'OK', 'Error') | Out-Null
        return
    }

    # Module vorhanden – Status protokollieren
    $fcVer  = (Get-Module -Name FailoverClusters -ErrorAction SilentlyContinue).Version
    $dbaVer = (Get-Module -Name dbatools         -ErrorAction SilentlyContinue).Version
    Write-RtfSuccess -Rtb $rtfBox -Msg (T 'InfoModuleVersion' -f 'FailoverClusters', $fcVer)
    Write-RtfSuccess -Rtb $rtfBox -Msg (T 'InfoModuleVersion' -f 'dbaTools', $dbaVer)

    # Neustart der Session erforderlich?
    if ($script:restartRequired) {
        $msg = T 'WarnModuleRestartNeeded'
        Write-RtfWarn -Rtb $rtfBox -Msg $msg
        $statusLabel.Text = T 'StatusRestartRequired'
        [System.Windows.Forms.MessageBox]::Show(
            $msg, (T 'MsgTitleRestartRequired'), 'OK', 'Warning') | Out-Null
        $btnOK.Enabled = $false
        return
    }

    # Alles bereit – Cluster-Daten einlesen
    Invoke-LoadData
})

# ---------------------------------------------------------------------------
# Anwendung starten
# ---------------------------------------------------------------------------
Write-RtfSection -Rtb $rtfBox -Msg (T 'AppVersion' -f $script:Version)
[System.Windows.Forms.Application]::Run($form)