# AlwaysOnSetup — Changelog

## [1.3.9] — 2026-10-23

### Network names are never removed without confirmation

Removing a cluster network name resource makes Windows disable the listener's AD computer
object, and only the AD team can enable it again. The tool did that on its own when it cleaned
up a leftover WSFC role before creating the AG, and 1.3.8 also did it for leftover listener
resources. Now both places show a warning dialog first that names the AD computer objects
affected; the default button is **No**.

- **No** to the leftover WSFC role: nothing is removed and the AG step stops with a message.
- **No** to leftover listener resources: nothing is removed, the listener is not created, and
  the log shows the order of the manual steps (remove resources, AD team enables the object,
  `ADD LISTENER`).
- Leftover IP address resources without a network name are still removed without asking; that
  does not touch AD.

## [1.3.8] — 2026-10-23

### Fixes

- **HADR check and enabling were wrong since 1.0.0:** step 2 looked for `hadr enabled` in
  `sys.configurations`, which does not exist. The check therefore always said "off", the tool
  ran `sp_configure 'hadr enabled'` (fails: "The configuration option 'hadr enabled' does not
  exist") and then restarted the SQL Server service on every node in every run, even with HADR
  already on. Now the check uses `SERVERPROPERTY('IsHadrEnabled')`. If HADR is really off, the
  tool sets `HADR_Enabled` in the instance registry via `xp_instance_regwrite` (as SQL Server
  Configuration Manager does), restarts the service via the Service Control Manager (WinRM only
  as fallback) and checks `IsHadrEnabled` afterwards. The same wrong check in the cluster
  detection showed "AlwaysOn: AUS" for every node; fixed as well.
- **Temporary login was not dropped:** the cleanup ran `DROP LOGIN` while connected as that
  very login ("Could not drop login ... as the user is currently logged in"), then fell back to
  PowerShell remoting. Now it connects with Windows authentication first, ends all sessions of
  the login (`KILL`) and drops it; the temporary login and PowerShell remoting are only
  fallbacks. If everything fails, the log shows the `DROP LOGIN` statement to run by hand.
  The password policy is re-enabled before the drop, while the login can still connect.
- **Leftover listener resources:** a failed `ADD LISTENER` can leave its network name and IP
  resources in the AG's cluster role, so the next attempt fails with Msg 41057 "The WSFC
  resource with the specified name already exists". When SQL Server has no listener for the AG,
  the tool now removes these resources and does not create the listener in the same run.
- **Disabled AD computer object (0x533):** removing a cluster network name resource (leftover
  listener, or the leftover WSFC group the tool removes before creating the AG) makes the
  cluster disable the listener's AD computer object. A new listener with that name then fails
  with 0x533 "This user can't sign in because this account is currently disabled". The tool now
  says so whenever it removes such a resource, names the computer objects the AD team has to
  enable (or delete) and the cluster account that needs rights on them, and prints the
  `ADD LISTENER` statement to run once that is done. The open items are repeated at the end of
  the log.
- **`HadrAgNameToldMap` cleanup without WinRM:** the registry value is now removed via the
  remote registry; PowerShell remoting is only the fallback.
- **Errors no longer swallowed:** creating the endpoint and the test database, setting FULL
  recovery and the initial backup used `-ErrorAction Stop`, which `Invoke-DbaQuery` does not
  turn into an exception; a failure there was only a warning and the step reported success.
  They now use `-EnableException`.

## [1.3.7] — 2026-10-23

### Fixes

- **Automatic temporary login always fell back to the manual step:** the login test after
  creating `AGSetup_<random>` called `Connect-DbaInstance -EnableException`, a parameter
  `Connect-DbaInstance` does not have. The log showed "Automatisches Anlegen fehlgeschlagen – A
  parameter cannot be found that matches parameter name 'EnableException'" and the setup
  continued with the manual T-SQL step, although the login had already been created. Present
  since 1.2.0. All other cmdlet calls in the script were checked against dbatools 2.9.0 for
  parameters that do not exist; none found.

## [1.3.6] — 2026-10-23

### Mixed mode without WinRM

Switching a node to mixed mode (and back at the end) needed PowerShell remoting to the node.
Where WinRM is not available, for example with "The WinRM client sent a request to an HTTP
server and got a response saying the requested HTTP URL was not available" (no WinRM listener
for the node's IP), the setup stopped with "Mixed-Mode konnte nicht aktiviert werden".

- **LoginMode via T-SQL:** the tool now sets `LoginMode` with `xp_instance_regwrite` over the
  existing Windows-auth connection (NTLM is enough, sysadmin needed) and reads the value back,
  since the extended procedure does not always report failures.
- **Restart via the Service Control Manager:** the SQL Server service (and running dependent
  services such as SQL Agent) is restarted over RPC/SMB, the same path `sc.exe \\node` uses.
  No WinRM involved.
- **WinRM only as fallback:** PowerShell remoting is used only when the T-SQL or the restart
  path fails. If the restart fails both ways, the registry value is set back so no node is
  left with a pending login-mode change; the log shows both error messages.
- **Mixed-mode check per node via T-SQL in both paths:** a node that already runs in mixed mode
  (for example switched by hand in SSMS) is skipped, so the WinRM error no longer blocks it.
  A node whose registry already says mixed mode but still runs Windows-only gets the missing
  restart. When some nodes are not reachable with Windows auth at all, every node is now
  checked, not only the unreachable ones.
- **No abort any more:** if mixed mode cannot be enabled automatically, the setup continues
  with the manual login step and lists the nodes to switch by hand. **Weiter** then tests the
  SQL login on every node, as before. Nodes switched by hand are not set back by the tool.

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
