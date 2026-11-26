# Tasks

Progress tracker for the plan in [docs/PLAN.md](docs/PLAN.md).

## Phase 0: Planning
- [x] Inspect repository (empty) and verify Odoo/OCA facts for 18.0, 19.0, 20.0
- [x] Write plan with enhancements (docs/PLAN.md)
- [x] Create this task list

## Phase 1: Foundation
- [ ] `install.cmd` double-click launcher with self-elevation
- [ ] `bootstrap.ps1` one-line web installer
- [ ] UI module: banner, colors, menus, prompts, step counter
- [ ] Core module: logging/transcript, state file, resumable downloads with sha256, process runner, secrets, admin/OS checks
- [ ] Pinned component manifest (`config/components.psd1`)

## Phase 2: Tuning and configuration
- [ ] RAM detection and 4/8/16 GB profiles
- [ ] SSD/HDD detection for `random_page_cost`
- [ ] PostgreSQL tuning file renderer
- [ ] `odoo.conf` renderer (dev vs prod)
- [ ] Port conflict detection

## Phase 3: Install steps (idempotent)
- [ ] Pre-flight: Windows version, admin, disk space, internet, `curl.exe`/`tar.exe`
- [ ] Google Chrome (skip if present)
- [ ] VC++ 2015-2022 runtime
- [ ] Python 3.12 (private) + venv
- [ ] PostgreSQL 17: initdb, tuning, service, roles
- [ ] wkhtmltopdf
- [ ] Odoo source download + pip requirements
- [ ] OCA repositories + requirements
- [ ] Write `odoo.conf`, ACLs, credentials file
- [ ] Odoo Windows service (WinSW, NetworkService, auto-restart)
- [ ] Firewall rule (production only)
- [ ] Defender exclusions and power plan (opt-in)
- [ ] Desktop shortcut (Chrome app mode)

## Phase 4: Egyptian business setup
- [ ] Create database with Arabic loaded
- [ ] Company: Egypt, EGP, Africa/Cairo; admin user login/password/language
- [ ] App selection menu (Accounting, Sales, Purchase, Inventory, POS, CRM, HR)
- [ ] OCA bundles (UX, financial reports, MIS, reconciliation, assets, payroll, dev ribbon)
- [ ] Optional ETA e-invoicing module

## Phase 5: Operations
- [ ] Backup script (Odoo-compatible ZIP, retention, integrity check)
- [ ] Backup drive selection + scheduled task with missed-run catch-up
- [ ] Restore from backup
- [ ] Repair mode
- [ ] Uninstall mode (data kept unless confirmed)
- [ ] `odoo-ctl.ps1` helper
- [ ] Unattended mode (`-ConfigFile`)

## Phase 6: Quality and CI
- [ ] Pester unit tests for pure logic (tuning, config rendering, retention)
- [ ] PSScriptAnalyzer settings
- [ ] CI: Linux-only lint + tests, path filters, concurrency, timeouts
- [ ] Manual Windows end-to-end workflow with download cache
- [ ] README (quick start, modes, backups, troubleshooting)
