# AlwaysOnSetup — Changelog

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
