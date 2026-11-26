# Odoo Setup Scripts for Windows

Interactive, colorful, **native** (no Docker) Odoo Community installer for
Windows 10 and 11, built for small businesses in Egypt and tuned for PCs with
**4 GB or 8 GB of RAM**.

It takes a fresh Windows PC to a working Odoo with the Egyptian chart of
accounts, Arabic, EGP and Cairo time, running as a Windows service, with
optional daily backups to the drive you choose.

## Quick start

1. Download this repository as a ZIP and extract it (or clone it).
2. Double-click **`install.cmd`** and accept the Administrator prompt.
3. Answer the questions (Enter accepts the default shown in `[brackets]`).

Or, in an Administrator PowerShell window:

```powershell
irm https://raw.githubusercontent.com/BishoyGH/Odoo-Setup-Scripts/main/bootstrap.ps1 | iex
```

Running setup again opens a menu: **Install, Status, Back up now, Restore,
Repair, Uninstall**.

## What gets installed

| Component | Version | Where |
|---|---|---|
| Odoo Community | 18.0 / **19.0** (default) / 20.0 | `C:\Odoo\src\odoo` |
| Python (private, not on PATH) | 3.12 | `C:\Odoo\python` + `C:\Odoo\venv` |
| PostgreSQL (localhost only) | 17 | `C:\Odoo\pgsql`, data in `C:\Odoo\pgdata` |
| wkhtmltopdf (PDF reports) | 0.12.6 | `C:\Odoo\wkhtmltopdf` |
| WinSW service wrapper | 2.12 | `C:\Odoo\tools` |
| Visual C++ runtime | 2015-2022 | system |
| Google Chrome | latest | only if missing |

Nothing else: no Git, Docker, Chocolatey, winget or Node. Downloads use the
`curl.exe` and `tar.exe` built into Windows, resume after interruptions, and
are cached in `C:\Odoo\downloads`.

## Production vs development

| | Production | Development |
|---|---|---|
| Who can open it | Every PC on the office network | This PC only |
| Starts with Windows | Yes, restarts itself after a crash | Manual start |
| Database manager page | Hidden | Visible |
| Demo data | Never | Optional |
| Auto-reload on code change | No | Yes (`--dev=reload,xml`) |
| Daily backups | Optional | No |
| No update restarts in business hours | Yes (08:00-23:00 by default) | No |
| Health check every 5 minutes | Yes | No |

## Egyptian setup

* Company country **Egypt**, currency **EGP**, timezone **Africa/Cairo**.
* `l10n_eg` Egyptian chart of accounts and taxes.
* **Arabic** and English installed; the administrator's language is your choice.
* Optional **ETA e-invoicing** (`l10n_eg_edi_eta`). Signing invoices needs the
  company's USB token and ETA portal credentials, which you configure in
  Accounting settings after install.

## Apps and community add-ons

You pick from a checklist. Defaults are marked with `*`.

Odoo apps: Invoicing & Accounting*, Sales*, Purchase*, Inventory*, Point of
Sale, CRM, Employees/Time Off/Attendance, Project & Timesheets, ETA e-invoicing.

OCA add-ons that fill gaps in Community:

| Bundle | What you get |
|---|---|
| Better UI* | Responsive app menu, resizable dialogs, refresh button, no Enterprise upsell |
| Financial reports* | General Ledger, Trial Balance, Aged Partner Balance, VAT report |
| MIS Builder* | Profit & Loss and Balance Sheet templates |
| Bank reconciliation* | Bank statements and the reconciliation screen |
| Fixed assets | Assets and depreciation |
| Payroll | Generic payroll engine (add Egyptian rules yourself) |
| Environment ribbon | "DEV" banner (development only) |

If an add-on is not yet available for the chosen Odoo version it is skipped
with a warning (20.0 is still missing a few).

## Performance tuning

RAM is detected and you can override the profile.

| | 4 GB | 8 GB | 16 GB+ |
|---|---|---|---|
| PostgreSQL shared_buffers | 384 MB | 1 GB | 2 GB |
| effective_cache_size | 1 GB | 3 GB | 8 GB |
| work_mem | 8 MB | 16 MB | 32 MB |
| Odoo DB connections | 24 | 48 | 64 |
| Odoo cron threads | 1 | 2 | 2 |
| Suggested users | ~5 | ~15 | ~25 |

Also: SSD/HDD detection, JIT off, Windows Defender exclusions for the
database and attachments, and (production) no sleep on AC power.

Odoo's multi-process `workers` mode does not exist on Windows, so Odoo runs
threaded; the tuning focuses on PostgreSQL and the OS. For more than about
25 concurrent users, use a Linux server.

## Backups

When enabled (production), setup lists your drives and recommends one that is
not the Windows drive. Every day at the chosen time a scheduled task writes
`<drive>:\OdooBackups\<database>\<database>_YYYY-MM-DD_HHmm.zip` and deletes
backups older than the retention period (the newest 3 are always kept). If the
PC was off at backup time, the backup runs as soon as it starts again.

Each ZIP contains `dump.sql`, `filestore/` and `manifest.json`, the same
format as Odoo's own database manager, so it can also be restored from
`/web/database/manager` on any Odoo server, Windows or Linux.

* Back up now: setup menu, or `C:\Odoo\tools\odoo-ctl.ps1 backup`
* Restore: setup menu, **Restore from a backup**
* Log: `C:\Odoo\logs\backup.log`

## Everyday commands

```powershell
C:\Odoo\tools\odoo-ctl.ps1 status          # services, URL, last backup
C:\Odoo\tools\odoo-ctl.ps1 restart
C:\Odoo\tools\odoo-ctl.ps1 logs            # follow the Odoo log
C:\Odoo\tools\odoo-ctl.ps1 update -Modules my_module   # after changing module code
C:\Odoo\tools\odoo-ctl.ps1 backup
```

Your own modules go in `C:\Odoo\addons\custom` (already on the addons path).

## Keeping it running

Production installs add two safeguards (both can be turned off in the questions):

* **Windows Update active hours.** You give the business day (08:00 to 23:00
  by default, at most 18 hours, a Windows limit). Windows will not restart the
  PC for updates inside those hours. This uses the documented Windows Update
  policy, so the setting cannot drift; Uninstall removes it.
* **Health check.** A scheduled task checks `http://127.0.0.1:8069/web/login`
  every 5 minutes. If Odoo fails to answer twice in a row, or its service has
  stopped, it restarts the service (and PostgreSQL if needed). It gives Odoo 5
  minutes after a start, stays out of the way during setup, restore and
  `odoo-ctl stop` / `update`, and stops after 3 restarts in an hour so a broken
  install is not restarted forever. Every action goes to
  `C:\Odoo\logs\health-check.log`; Status shows the last result.

`odoo-ctl stop` pauses the health check for up to 6 hours; `odoo-ctl start`
resumes it.

## Unattended install

```powershell
copy config\answers.example.psd1 my-answers.psd1   # edit it
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Action Install -ConfigFile .\my-answers.psd1
```

### Reseller package

For installing at clients: one ZIP that runs with no questions.

```powershell
copy config\answers.example.psd1 nile-answers.psd1      # fill in the client's details
powershell -ExecutionPolicy Bypass -File .\reseller\New-ResellerPackage.ps1 -AnswersFile .\nile-answers.psd1
```

The answers file is checked first (typos in setting names, Odoo version,
database name, apps, backup folder, business hours). The ZIP lands in `dist\`
and contains the installer, `answers.psd1`, `install-unattended.cmd` and a
short `READ-ME-FIRST.txt`. On the client PC: extract it and double-click
**`install-unattended.cmd`**. If it is interrupted, run it again and it resumes.
Leave `AdminPassword` empty so a password is generated on the client PC
instead of travelling inside the ZIP.

## Credentials and security

* Strong random passwords are generated for PostgreSQL, the Odoo database role
  and the Odoo master password, and saved with the admin login in
  `C:\Odoo\conf\CREDENTIALS.txt`, readable only by Administrators.
* PostgreSQL listens on localhost only. Odoo's database role is not a superuser.
* Both services run as `NetworkService`, not `LocalSystem`.
* The firewall rule opens Odoo's port on Private and Domain networks only.

## Troubleshooting

* **Setup stopped halfway.** Run it again; finished steps are skipped and
  downloads resume.
* **Other PCs cannot connect.** Make sure the network is *Private*
  (Settings > Network) and use the address printed at the end of setup.
* **Something is broken.** Run setup and choose **Repair**.
* Logs for every run are in `C:\Odoo\logs`.

## Development of this repository

* [docs/PLAN.md](docs/PLAN.md) explains the design; [TASKS.md](TASKS.md) tracks progress.
* All scripts target Windows PowerShell 5.1 and must stay ASCII-only.
* CI (`.github/workflows/ci.yml`) runs PSScriptAnalyzer and Pester on Linux,
  only when code changes, with cached modules. A full Windows install test
  (`windows-e2e.yml`) is available as a manual workflow.

Run the tests locally with `Invoke-Pester ./tests` and `./tests/Invoke-Lint.ps1`.
