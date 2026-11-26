# Plan: streamlined native Odoo setup for Windows 10/11

Audience: small Egyptian businesses running Odoo Community on a single
Windows 10/11 PC with 4 GB or 8 GB of RAM. The PC is assumed to be a fresh
Windows install with nothing on it.

## 1. Goals (from the request)

| # | Requirement | How the plan meets it |
|---|-------------|-----------------------|
| 1 | Performance first, no Docker | Native Windows services for PostgreSQL and Odoo; RAM-aware tuning; Defender exclusions; no virtualization layer. |
| 2 | As few dependencies as possible | Only what Odoo strictly needs: Python, PostgreSQL, wkhtmltopdf, VC++ runtime, plus one small service wrapper (WinSW). No Git, no Chocolatey, no winget, no Node. Downloads use `curl.exe`/`tar.exe`, which ship with Windows 10 1803+. |
| 3 | Interactive and colorful | PowerShell 5.1 (built into every Windows 10/11, no install). Colored banner, numbered menus, defaults in `[brackets]`, step counters, OK/WARN/FAIL tags. |
| 4 | Community apps to fill gaps | Curated OCA bundles: financial reports, MIS P&L/balance sheet, bank reconciliation, assets, payroll, responsive backend UI. |
| 5 | Egyptian market | `l10n_eg` chart of accounts, Arabic (`ar_001`) loaded, `Africa/Cairo` timezone, EGP currency, optional ETA e-invoicing module (`l10n_eg_edi_eta`). |
| 6 | 4 GB and 8 GB targets | RAM is auto-detected and mapped to a tuning profile (4 GB / 8 GB / 16 GB+), overridable. |
| 7 | Install Chrome if missing | Detected via known install paths; installed silently from Google's enterprise MSI. Also creates an "Odoo" desktop shortcut that opens Chrome in app mode. |
| 8 | Fresh Windows assumed | Installs VC++ runtime, Python, PostgreSQL, wkhtmltopdf from scratch. Nothing pre-installed is required besides Windows itself. |
| 9 | Choose backup partition | Lists fixed drives with free space, recommends a non-system drive. |
| 10 | Optional backups for production | Daily scheduled task (runs at next boot if the PC was off), retention, Odoo-compatible ZIP format. |
| 11 | Development vs production | Two modes with different defaults (see section 4). |
| 12 | Lean GitHub CI | Linux runner only (cheapest minutes), path filters, concurrency cancel, docs-only changes skip CI, Windows end-to-end test only on manual dispatch with cached downloads. |

## 2. Key technical decisions

* **Odoo version:** selectable 18.0 / 19.0 / 20.0, default **19.0**. 20.0 is
  out, but several OCA modules (e.g. `account_financial_report`,
  `account_reconcile_oca`) are not yet ported to 20.0; 19.0 has full coverage.
  Missing modules are skipped with a warning, never a hard failure.
* **Windows runs Odoo in threaded mode.** Odoo's multi-process `workers`
  and `limit_memory_*` options are POSIX-only (verified in
  `odoo/tools/config.py`, `_PosixOnlyOption`), so tuning focuses on
  PostgreSQL, `db_maxconn`, cron threads and the OS (Defender, power plan).
* **Python 3.12** (supported by 18.0, 19.0 and 20.0; Windows wheels exist for
  every pinned requirement, e.g. `psycopg2==2.9.9 cp312 win_amd64`). Installed
  privately to `C:\Odoo\python`, not on PATH, with a venv on top so repair
  can rebuild it.
* **PostgreSQL 17 from the EDB binaries ZIP**, not the EDB installer: no
  StackBuilder, no pgAdmin, fully scripted `initdb`, our own service name,
  listening on localhost only with `scram-sha-256`.
* **Odoo source from GitHub branch ZIP** extracted with `tar.exe` (no Git).
* **Windows service via WinSW** (single self-contained exe, sha256-pinned),
  with crash auto-restart and size-rolled logs. Both services run as
  `NT AUTHORITY\NetworkService`, not LocalSystem.
* **Pinned, checksummed downloads** in `config/components.psd1`; resumable
  with `curl -C -`; cached in `C:\Odoo\downloads` so repair/reinstall is
  offline-friendly.

## 3. Install layout

```
C:\Odoo\
  python\        private Python 3.12
  venv\          Odoo virtualenv
  pgsql\         PostgreSQL binaries
  pgdata\        PostgreSQL cluster
  wkhtmltopdf\
  src\odoo\      Odoo source (one version)
  addons\oca\    OCA repositories
  addons\custom\ your own modules (already in addons_path)
  data\          Odoo data_dir (filestore, sessions)
  conf\          odoo.conf, settings.json, CREDENTIALS.txt (admin-only ACL)
  logs\          setup transcripts + service logs
  tools\         winsw, backup.ps1, odoo-ctl.ps1
  downloads\     installer cache
  state.json     completed steps (resume support)
```

## 4. Development vs production

| Setting | Development | Production |
|---|---|---|
| Listen on | 127.0.0.1 | 0.0.0.0 (LAN) |
| Firewall rule | none | TCP 8069 inbound, Private/Domain profiles only |
| Database manager (`list_db`) | on | off |
| Demo data | optional | never |
| Log level | debug | warn |
| `--dev` reload | on (watchdog) | off |
| Environment ribbon (OCA) | yes ("DEV") | no |
| Windows service | installed, manual start | automatic (delayed) start, auto-restart on crash |
| Sleep on AC power | unchanged | disabled (optional) |
| Backups | not offered | optional daily backups to chosen partition |

## 5. RAM profiles

Windows itself plus a browser typically need ~2 GB, so the profiles are
deliberately conservative.

| | 4 GB | 8 GB | 16 GB+ |
|---|---|---|---|
| shared_buffers | 384MB | 1GB | 2GB |
| effective_cache_size | 1GB | 3GB | 8GB |
| work_mem | 8MB | 16MB | 32MB |
| maintenance_work_mem | 96MB | 256MB | 512MB |
| max_connections | 40 | 80 | 120 |
| max_wal_size | 1GB | 2GB | 4GB |
| Odoo db_maxconn | 24 | 48 | 64 |
| Odoo max_cron_threads | 1 | 2 | 2 |

Also: `random_page_cost` 1.1 on SSD / 4 on HDD (auto-detected),
`jit = off` (better for Odoo's short OLTP queries), `checkpoint_completion_target = 0.9`.
`effective_io_concurrency` is left unset because Windows lacks `posix_fadvise`.

## 6. My additions beyond the request

1. **Idempotent, resumable steps** with a state file; each step also verifies
   reality (file exists, service running), so re-running is always safe.
2. **Full logging**: every run writes a transcript to `C:\Odoo\logs`.
3. **Repair** (re-runs all checks, rebuilds venv, rewrites configs, restarts
   services) and **Uninstall** (keeps data and backups unless you type
   `DELETE`).
4. **Restore from backup**, from the menu, choosing a ZIP from the backup drive.
5. **Backups compatible with Odoo's own database manager** (`dump.sql` +
   `filestore/` + `manifest.json`), so they can also be restored through the
   web UI on any Odoo, Windows or Linux.
6. **Missed-backup catch-up**: the scheduled task uses "run as soon as possible
   after a missed start", important for office PCs switched off at night.
7. **Windows Defender exclusions** for the database and filestore (large,
   measurable I/O win), opt-in.
8. **Power plan**: disable sleep on AC for production servers, opt-in.
9. **Generated strong passwords** (PostgreSQL superuser, Odoo DB role, master
   password) stored in an admin-only credentials file.
10. **Port conflict detection** for 5432/8069, with automatic alternatives.
11. **Unattended mode** (`-ConfigFile answers.psd1`) for repeat deployments by
    resellers/IT, also used by the Windows CI test.
12. **One-line bootstrap** (`irm .../bootstrap.ps1 | iex`) and a double-click
    `install.cmd` that self-elevates.
13. **`odoo-ctl.ps1`** helper: start/stop/restart/status/logs/update modules.
14. **Chrome app-mode shortcut** so staff get a clean "Odoo" window.

## 7. Known limitations

* ETA e-invoicing signing needs the taxpayer's USB token. Odoo's
  `l10n_eg_edi_eta` signs through an IoT/token agent; the installer installs
  the module but token middleware and portal credentials remain a manual,
  per-company step (documented in README).
* Odoo on Windows cannot use multi-process workers; for more than ~25
  concurrent users a Linux server is the better choice.

## 8. Next steps (round 2)

Ordered by value. Phase numbers match [TASKS.md](../TASKS.md).

### Phase 8: Bug fixes from code review (done)
Ten issues fixed, most important: the Odoo service account could read the
PostgreSQL superuser password; an interrupted database creation was treated as
finished; restores failed as a non-superuser; the Egyptian chart of accounts
relied on auto-detection.

### Phase 9: Prove it on real Windows (highest priority)
Nothing replaces one real run. Run the manual Windows workflow for 19.0, then
18.0 and 20.0, then one interactive install on a 4 GB Windows 10 PC. Pin the
Python and PostgreSQL checksums once the downloads are confirmed.

### Phase 10: Logic updates
* **Safe updates**: a menu action "Update Odoo" that takes a backup, refreshes
  the source (bug fixes on the same version), runs `-u all` and rolls back to
  the backup if it fails. Major-version upgrades stay out of scope (they need
  OpenUpgrade and a test run).
* **Backups you can trust**: second copy to a USB drive or network share;
  weekly test-restore into a throwaway database; free-space check before each
  backup; Status warns when the last good backup is older than 2 days; a
  Windows notification when a backup fails.
* **Test copies**: "Restore as test copy" runs `odoo-bin neutralize` so a copy
  never sends emails or runs payment/ETA jobs.
* **Development comfort**: optional auto-start, Start/Stop desktop shortcuts,
  scaffold a module into `addons\custom`.
* **Windows hardening**: enable long paths before extracting sources; check
  for pending reboots after the VC++ runtime install.

### Phase 11: Egyptian market depth
* Arabic installer prompts (bilingual), which needs UTF-8 BOM source files and a test.
* Arabic PDF fonts (Cairo / Noto Kufi Arabic) so invoices print cleanly.
* Check VAT 14% and withholding tax defaults after `l10n_eg` loads.
* ETA setup guide plus a pre-flight check for the USB token middleware.
* A small custom module with Egyptian payroll rules (social insurance, income
  tax brackets) on top of OCA payroll.

### Phase 12: Refactoring
* One install context object instead of passing Paths/Settings/Secrets everywhere.
* Steps declared as a data table (Id, Title, Test, Run) driven by one loop,
  removing the reliance on PowerShell scriptblock scoping.
* Split `OdooSetup.Steps.psm1` (about 700 lines) into Python, PostgreSQL,
  Odoo, Service and OS modules, each with an explicit export list.
* Validate answers files (`Test-SetupSettings`) with clear messages.
* Thin wrappers around native calls (icacls, sc, psql) so the install steps
  get Pester tests with mocks on the cheap Linux runner.

### Phase 13: CI and releases
* Pester mock tests for the install steps (still Linux only).
* Release workflow on tags only: zip the scripts and attach to a GitHub release
  (bootstrap can then download a pinned release instead of `main`).
* Dependabot for GitHub Actions versions, monthly.
