AlwaysOnSetup
PowerShell WinForms tool for fully automated configuration of SQL Server AlwaysOn Availability Groups — developed by dtcSoftware (Uwe Janke).

Overview
AlwaysOnSetup.ps1 is a graphical PowerShell application (WinForms) that automatically reads an existing Windows Server Failover Cluster (WSFC) and fully configures AlwaysOn Availability Groups — up to 3 nodes.

Tested on: Windows Server 2022 / SQL Server 2022

Features
Automatic Cluster Discovery: Reads cluster and SQL Server information automatically and displays it in the PropertyGrid
Kerberos/SQL Auth Fallback: Uses Windows authentication only when the remote nodes authenticate over Kerberos; with NTLM only (missing SPNs) or `Setup-Authentifizierung = SQL-Login` it creates a temporary SQL login itself and runs the setup with it
Temporary Login Management: Creates random SQL login, displays T-SQL block for manual execution, automatically removes login after completion
WSFC Cleanup: Removes orphaned WSFC group entries
SPN Validation: Generates AD team request file with required setspn commands
Cluster Settings Backup: Backs up cluster settings before each change
Backup Preference: Configurable (Primary / Secondary / PreferSecondary / None)
AG Sync Job: Creates the SQL Agent job "AG Sync - Logins, Jobs, LinkedServer" on every node (daily 02:00, runs only on the current primary)
Password Masking: The temporary login's password never reaches a saved log file (masked as ********)
Minimal dbaTools Usage: Configuration via Invoke-DbaQuery and Connect-DbaInstance; the AG sync job uses Copy-DbaLogin, Copy-DbaAgentJob and Copy-DbaLinkedServer
Prerequisites
Requirement	Minimum Version
Windows Server	2022
SQL Server	2022 (Enterprise or Standard)
PowerShell	5.1
Windows Server Failover Cluster	must already exist
Modules (automatically loaded/installed):

FailoverClusters (RSAT-Clustering-PowerShell)
dbaTools >= 2.0
Usage
# Run as local Administrator on a cluster node
.\AlwaysOnSetup.ps1
# or double-click Start-AlwaysOnSetup.cmd (elevates automatically)
Recommendation: Set SPNs before setup — this saves the manual confirmation step.
The script displays the required setspn commands in Step 10 (SPN validation).

Process
Script automatically detects WSFC cluster
SQL Server instances on all nodes are identified
Adjust configuration parameters in the PropertyGrid
Kerberos connection to all nodes is tested — NTLM only: temporary SQL login created automatically; node not reachable at all: T-SQL block for manual execution
After confirmation: fully automated AG configuration
Temporary login is removed
Files
File	Contents
AlwaysOnSetup.ps1	Main script (WinForms GUI + automation logic)
AlwaysOn_Doku.html	Technical documentation
AlwaysOn_Handbuch.docx	User manual
Version
1.3.4 — 2026-10-23 — see CHANGELOG.md for all releases
More Information
Documentation: www.powershelldba.de/alwaysonsetup/
Website: www.powershelldba.de
PowerShell Gallery: powershellgallery.com/profiles/JankeUwe
All Projects: github.com/JankeUwe
Developer: Uwe Janke, Senior SQL Server DBA | dtcSoftware
