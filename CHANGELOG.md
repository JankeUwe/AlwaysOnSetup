# AlwaysOnSetup — Changelog

## [1.3.5] — 2026-10-23

### SPN check without domain read access warns and lists all needed SPNs

Step 10 queries the service account's SPNs with `setspn -L`. Without domain read access (or
without `setspn.exe`) that query fails; because the script runs with
`$ErrorActionPreference = 'Stop'`, PowerShell 5.1 turned setspn's stderr into an exception and
the step ended in a red "SPN-Prüfung fehlgeschlagen" without any SPN list. Now a failed query
is a yellow warning with setspn's message, every needed SPN (per node short name and FQDN, plus
the listener) is listed as `BENÖTIGT`, and the AD-team file contains all `setspn -S` commands
with a note that the current state could not be checked (`setspn -S` only adds what is missing
and reports existing SPNs as duplicates). A query counts as successful only with exit code 0
and the "Registered ServicePrincipalNames" header, so a silent failure no longer looks like
"all SPNs missing".

## [1.3.4] — 2026-10-23

### Existing AG sync job is a note, not an error

If the AG sync job (step 8) already exists on a node, the log now shows a yellow note and leaves
the existing job unchanged. Before, the job was dropped and recreated, and a rerun ended in a
red error.

### Fixes

- **Schedule creation:** `New-DbaAgentSchedule` (dbatools 2.9) refuses to run without start/end
  date and end time and failed with "Please enter a start date or use -Force", so the job was
  created without its daily 02:00 schedule and the step reported an error. Start date, end date
  and end time are now passed explicitly.
- **Leftover schedule:** if a schedule with the job's schedule name already exists (from an
  earlier run), it is attached to the new job with `sp_attach_schedule`. Before,
  `Set-DbaAgentJobSchedule` looked for it on the new job, where it did not exist.

## [1.3.3] — 2026-10-23

### Temporary login password no longer ends up in saved log files

On the manual path the live log shows the setup-login T-SQL and the line `Login: … Passwort: …`
so the operator can run it on the node. Both contain the password, and the automatic
`AlwaysOn_Setup_<date>.log` written at the end of the run copied it to disk, as did the
"save log" button (RTF or text). Every saved log now has the password replaced by `********`;
the live window and the clipboard still show it while the session runs.

- Header and README corrected: SPN check is step 10, the AG sync job (step 8) uses
  `Copy-DbaLogin` / `Copy-DbaAgentJob` / `Copy-DbaLinkedServer`.

## [1.3.2] — 2026-10-22

### Leftover test database from a failed run is removed

Before the test database is created, every node is checked for a database with that name.
If it belongs to no availability group and is not ONLINE (typically a secondary left in
RESTORING by an aborted seeding or join), it is dropped, because it would block automatic
seeding or the new database. A database that belongs to an AG is left alone. An ONLINE database
outside an AG on a secondary is only reported, never dropped.

## [1.3.1] — 2026-10-22

### Autoseeding of the test database is checked

The status step now waits up to 3 minutes for the automatic seeding of the test database and
reports per secondary: distributed (SYNCHRONIZED/SYNCHRONIZING), seeding failed with the reason
from `sys.dm_hadr_automatic_seeding` (`failure_state_desc`, error code), or no seeding started,
which usually means no endpoint connection between the replicas. Before, the step took a single
status snapshot after 5 seconds and could only show `NOT_HEALTHY` without a reason.

## [1.3.0] — 2026-10-22

### Windows-auth-only instances are restored after the setup

On the SQL-login path, a node that allows Windows authentication only is switched to mixed mode
for the setup (service restart). Before, it stayed in mixed mode. Now the tool remembers which
nodes it switched and sets them back to Windows authentication only at the end, after the temporary
login is dropped. Secondaries restart first, the primary last; if the primary restart triggers an
automatic failover, the AG is failed back to the original primary once it is synchronized.

- **Named instances:** registry path (via `Instance Names\SQL`) and service name (`MSSQL$<name>`)
  are derived from the instance instead of being fixed to `MSSQLSERVER`. Dependent services
  (SQL Agent) are started again after the restart.
- **Clear abort:** if mixed mode cannot be enabled on a node, the setup stops with a message
  (set SPNs or enable mixed mode manually) instead of ending in a Continue loop whose SQL login
  can never connect. Nodes already switched are set back immediately.

## [1.2.2] — 2026-10-22

### Setup-login T-SQL goes straight to the clipboard

When the temporary setup login has to be created manually, the T-SQL block is now copied to the
clipboard as soon as it is shown, ready to paste into SSMS on the node (RDP passes the clipboard
through). A new button "Login-T-SQL kopieren" below the log copies it again for the next node;
it is shown together with "Weiter" and hidden once the setup continues.

## [1.2.1] — 2026-10-22

### Temporary setup login complies with the "New Login" password policy

The usual PBM policy `New Login_Enforce Passwort Policy` (On Change: Prevent) rolls back
`CREATE LOGIN` with `CHECK_POLICY = OFF` and `CREATE LOGIN ... FROM WINDOWS`. The temporary
setup login is now created with `CHECK_POLICY = ON`, so it no longer depends on disabling the
policy. If `CREATE LOGIN` for the service account is still rolled back by a trigger, the log
now says so and lists the active server triggers and On-Change-Prevent policies, instead of
the misleading "DOMAIN\User nicht auflösbar".

## [1.2.0] — 2026-10-22

### Setup runs over a temporary SQL login when Kerberos is not available

Windows authentication to the remote nodes now has to use Kerberos
(`sys.dm_exec_connections.auth_scheme`). Before, an NTLM connection counted as OK, so a cluster
without SPNs ran over Windows auth and failed later. Without Kerberos, or with the new
PropertyGrid option `Setup-Authentifizierung = SQL-Login`, the tool now creates the temporary
sysadmin SQL login itself over the working Windows connection (mixed mode is enabled if needed,
the PBM password policy is disabled for the run) and runs every step with it. The manual T-SQL
block with the Continue button is only used when a node cannot be reached with Windows auth at all.

### Fixes from a failed run without SPNs

- **Listener detection:** the cluster core role (`Cluster Group`) and `Available Storage` are no
  longer taken as the listener. Before, when the AG role had been deleted, the cluster name and
  cluster IP were used as listener and AG name, and `ADD LISTENER` failed with WSFC error 5057.
  The OK check now rejects a listener name equal to the cluster name.
- **Endpoint login (step 4):** the PBM policy is also disabled around `CREATE LOGIN ... FROM WINDOWS`
  in the Kerberos path, where its trigger had rolled the statement back. The policy is only
  re-enabled on nodes where the tool disabled it.
- **Certificate fallback:** certificate files now go to `<instance default backup path>\HADR_Certs`
  instead of `C:\System\Certs`, which the SQL service account could not write (`xp_create_subdir`
  error 5). An old `.cer` file is removed first, and the setup runs once for all nodes instead of once per node.
- **MODIFY REPLICA:** split into one statement per option (`Incorrect syntax near ','` before);
  `AVAILABILITY_MODE` and `FAILOVER_MODE` are set in the order SQL Server requires.
- **AG sync job owner (step 8):** `sa` is found by SID `0x01` (works when renamed); the fallback
  skips Windows groups, which SQL Agent rejects as job owner.

## [1.1.0] — 2026-10-22

### Listener IP, port and subnet mask can be entered manually

If the cluster role was deleted beforehand, the GUI finds no listener settings. `Listener-IP`
and `Listener-Port` are now editable in the PropertyGrid (previously read-only), and a new
`Listener-Subnetzmaske` field replaces the hard-coded `255.255.255.0` (read from the cluster
IP resource when available). Before the start, the IP and subnet mask are checked for valid
IPv4 format and the port for 1–65535; the Reset button also restores the detected listener values.

## [Unreleased] — 2026-06-06

### Fix: SA-rename issue in endpoint and job creation

### Path convention change

Replaced `C:\Temp` paths with `C:\System` in certificate and backup handling.

## [Unreleased] — 2026-06-04

### Fix: manual entry when no cluster role is found

`ListenerName`/`AGName` must be entered manually if no cluster role can be detected.

### Added Reset button and IP validation

## [Unreleased] — 2026-06-02

### Added German/English bilingual support

## [Unreleased] — 2026-05-26

### Fix: secondary-replica failover mode

Now set explicitly via `MODIFY REPLICA` instead of relying on a default.

## [Unreleased] — 2026-05-22 to 2026-05-23

### Cross-domain login and certificate handling

Robust Step 4 cross-domain login with certificate fallback; UPN conversion now uses the target
domain's NetBIOS name; UPN fallback for cross-domain `CREATE LOGIN`; `hadr enabled` fix split into
two separate `sp_configure` calls (required for it to take effect reliably).

### Added Step 8 — AG-sync job on all nodes

### Added Start-AlwaysOnSetup.cmd + AlwaysOnSetup.ini

Fixed shortly after: the starter now copies itself locally before elevation, and the GUI's
`SplitterDistance` is set correctly on startup via `Add_Shown`.

### Docs

Updated `AlwaysOn_Handbuch.docx`; added documentation links to the README for SEO.

## [1.0.0] — 2026-05-18 to 2026-05-20

### Initial release

AlwaysOn Availability Group setup automation, MIT-licensed. Auto-enables Mixed Mode when SPNs are
missing; fixed the backup path to use a local path instead of UNC. Added a 15-slide bilingual
(DE/EN) Reveal.js presentation with a full WinForms GUI mockup matching the website, including
documentation of the endpoint-ownership problem.
