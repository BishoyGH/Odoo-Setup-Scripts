# Tasks

Progress tracker for the plan in [docs/PLAN.md](docs/PLAN.md).

## Phase 0: Planning
- [x] Inspect repository (empty) and verify Odoo/OCA facts for 18.0, 19.0, 20.0
- [x] Write plan with enhancements (docs/PLAN.md)
- [x] Create this task list

## Phase 1: Foundation
- [x] `install.cmd` double-click launcher with self-elevation
- [x] `bootstrap.ps1` one-line web installer
- [x] UI module: banner, colors, menus, prompts, step counter
- [x] Core module: logging/transcript, state file, resumable downloads with sha256, process runner, secrets, admin/OS checks
- [x] Pinned component manifest (`config/components.psd1`)

## Phase 2: Tuning and configuration
- [x] RAM detection and 4/8/16 GB profiles
- [x] SSD/HDD detection for `random_page_cost`
- [x] PostgreSQL tuning file renderer
- [x] `odoo.conf` renderer (dev vs prod)
- [x] Port conflict detection

## Phase 3: Install steps (idempotent)
- [x] Pre-flight: Windows version, admin, disk space, internet, `curl.exe`/`tar.exe`
- [x] Google Chrome (skip if present)
- [x] VC++ 2015-2022 runtime
- [x] Python 3.12 (private) + venv
- [x] PostgreSQL 17: initdb, tuning, service, roles
- [x] wkhtmltopdf
- [x] Odoo source download + pip requirements
- [x] OCA repositories + requirements
- [x] Write `odoo.conf`, ACLs, credentials file
- [x] Odoo Windows service (WinSW, NetworkService, auto-restart)
- [x] Firewall rule (production only)
- [x] Defender exclusions and power plan (opt-in)
- [x] Desktop shortcut (Chrome app mode)

## Phase 4: Egyptian business setup
- [x] Create database with Arabic loaded
- [x] Company: Egypt, EGP, Africa/Cairo; admin user login/password/language
- [x] App selection menu (Accounting, Sales, Purchase, Inventory, POS, CRM, HR)
- [x] OCA bundles (UX, financial reports, MIS, reconciliation, assets, payroll, dev ribbon)
- [x] Optional ETA e-invoicing module

## Phase 5: Operations
- [x] Backup script (Odoo-compatible ZIP, retention, integrity check)
- [x] Backup drive selection + scheduled task with missed-run catch-up
- [x] Restore from backup
- [x] Repair mode
- [x] Uninstall mode (data kept unless confirmed)
- [x] `odoo-ctl.ps1` helper
- [x] Unattended mode (`-ConfigFile`)

## Phase 6: Quality and CI
- [x] Pester unit tests for pure logic (tuning, config rendering, retention)
- [x] PSScriptAnalyzer settings
- [x] CI: Linux-only lint + tests, path filters, concurrency, timeouts
- [x] Manual Windows end-to-end workflow with download cache
- [x] README (quick start, modes, backups, troubleshooting)

## Phase 7: Verification on real Windows
- [ ] Run the manual "Windows end-to-end" workflow for 19.0 (Actions tab) and fix anything it finds
- [ ] Try an interactive install on a 4 GB Windows 10 PC
- [ ] Pin sha256 for the Python and PostgreSQL downloads after first verified run

## Phase 8: Bug fixes from code review
- [x] Service account can no longer read secrets.json / CREDENTIALS.txt
- [x] Detect and rebuild a half-created database after an interrupted run
- [x] Company setup as its own resumable step
- [x] Load the Egyptian chart of accounts explicitly after apps install
- [x] Restore works as a non-superuser and verifies the result
- [x] initdb restricted-token access to pgdata
- [x] icacls usage (single /grant:r, no per-file /T)
- [x] Native stderr cannot abort psql/python checks
- [x] Remove invalid `-w` from `pg_ctl register`
- [x] `odoo-ctl logs` follows the error log

> Phase 9 in docs/PLAN.md is the Windows verification in Phase 7 above. Do it first.

## Phase 10: Logic updates
- [x] "Update Odoo" action: backup, refresh source, `-u all`, roll back on failure
- [ ] Second backup copy (USB or network share)
- [ ] Weekly automatic test-restore of the latest backup
- [ ] Free-space check before backup
- [ ] Status warns when the last good backup is older than 2 days
- [ ] Windows notification on backup failure
- [ ] "Restore as test copy" with `odoo-bin neutralize`
- [ ] Development: optional auto-start, Start/Stop shortcuts, module scaffold
- [ ] Enable Windows long paths before extracting sources
- [ ] Detect pending reboot after VC++ runtime install

## Phase 10b: Client-ready deployment (from "does the client need to run anything?")
- [x] Production service starts at boot without delay (was "delayed start", about 2 minutes later)
- [ ] Measure boot-to-login-page time on a 4 GB HDD and an 8 GB SSD PC, document it
- [ ] Set Windows Update active hours to business hours so updates never reboot mid-day
- [ ] Optional reseller package: one ZIP + answers file, runs with no questions
- [ ] Health check task: if Odoo stops answering, restart the service and log it

## Phase 11: Egyptian market depth
- [ ] Bilingual (Arabic/English) installer prompts
- [ ] Arabic PDF fonts for invoices
- [ ] Verify VAT 14% and withholding tax defaults after `l10n_eg`
- [ ] ETA setup guide and USB token middleware check
- [ ] Egyptian payroll rules module on top of OCA payroll

## Phase 12: Refactoring
- [ ] Single install context object
- [ ] Steps as a data table with one runner loop
- [ ] Split `OdooSetup.Steps.psm1` into focused modules with explicit exports
- [ ] Validate answers files (`Test-SetupSettings`)
- [x] Wrap native calls so install steps can be unit-tested with mocks (`Invoke-Tool`)

## Phase 13: CI and releases
- [x] Pester mock tests for install steps (Linux runner, `tests/Steps.Tests.ps1`)
- [ ] Tag-only release workflow publishing a zip; bootstrap uses releases
- [ ] Dependabot for GitHub Actions (monthly)
