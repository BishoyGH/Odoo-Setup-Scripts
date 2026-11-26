# Egyptian payroll (OCA Payroll + `l10n_eg_payroll_oss`)

Odoo Community has no payroll. The installer's **Payroll** add-on downloads
[OCA Payroll](https://github.com/OCA/payroll) and adds a small module from this
repository, `addons/l10n_eg_payroll_oss`, with Egyptian salary rules. No
maintained, openly licensed Egyptian rules module exists for OCA Payroll, so it
lives here.

If OCA Payroll is not available for the chosen Odoo version (for example a new
version it has not been ported to yet), the module is skipped with a warning
and nothing else is affected.

## What it adds

A salary structure **Egypt - Monthly Employee** (code `EG`) with these rules:

| Code | Rule | How it is computed |
|---|---|---|
| `BASIC` | Basic Salary | Contract wage |
| `GROSS` | Gross Salary | Basic + every rule in the *Allowance* category |
| `SI_EE` | Social Insurance (Employee 11%) | 11% of the insurable wage, deducted |
| `SI_ER` | Social Insurance (Company 18.75%) | 18.75% of the insurable wage, company cost (not deducted) |
| `MARTYRS` | Martyrs Fund (0.05%) | 0.05% of gross, deducted |
| `TAX` | Salary Income Tax | Monthly share of the annual tax, deducted |
| `NET` | Net Salary | Basic + allowances + deductions |

Rule and category names are translated to Arabic.

### Insurable wage

The insurable wage is this month's gross, clamped to the legal monthly range for
the payslip's year. If an employee is registered with NOSI at a fixed insurable
wage for the year, enter it in the payslip input **SI_WAGE** and that amount is
used instead.

| Year | Minimum | Maximum |
|---|---|---|
| 2025 | EGP 2,300 | EGP 14,500 |
| 2026 | EGP 2,700 | EGP 16,700 |

A year newer than the table uses the latest known limits, so **add the new row
every January** (see "Updating the rates").

### Salary income tax

Monthly tax = tax on `(gross - employee insurance) x 12 - 20,000`, divided by 12.

| Annual taxable income (EGP) | Rate |
|---|---|
| 0 - 40,000 | 0% |
| 40,000 - 55,000 | 10% |
| 55,000 - 70,000 | 15% |
| 70,000 - 200,000 | 20% |
| 200,000 - 400,000 | 22.5% |
| 400,000 - 1,200,000 | 25% |
| Above 1,200,000 | 27.5% |

Above EGP 600,000 a year the lower bands are withdrawn step by step: above
600k the 0% band goes (10% applies from the first pound up to 55k), above 700k
the 10% band too, then 15% above 800k, 20% above 900k, and above 1.2M only the
25% and 27.5% bands remain. The thresholds are applied to annual taxable income.

## Using it

1. Payroll > Configuration: check the structure **Egypt - Monthly Employee**.
2. On each employee's contract, set **Salary Structure** to it and the wage.
3. Add allowances (transport, housing, ...) as new salary rules in the
   *Allowance* category and add them to the structure.
4. Create payslips as usual. Payroll Accounting (`payroll_account`) can post
   them to the Egyptian chart of accounts once you set accounts on the rules.

Limits of this first version: monthly pay only; no annual tax settlement,
no exemptions beyond the personal exemption (for example disability or
private insurance premiums), and no end-of-service calculations.

## Updating the rates

All legal values live in one plain Python file,
`addons/l10n_eg_payroll_oss/models/eg_rules.py`: social insurance rates and
yearly limits, the personal exemption, the tax bands and the band withdrawal
thresholds. The salary rules only call these functions, so after editing the
file, restart Odoo and update the module (Apps > Egypt - Payroll Rules >
Upgrade). Rules you edited in Odoo are kept.

Run the tests after any change:

```
python -m unittest discover -s tests/python
```

> These values were checked in November 2026 against published guides
> (Andersen Egypt, Native Teams, AB Accountants). They are not legal advice:
> confirm them with your accountant, especially the band withdrawal rule and
> the Martyrs Fund, before running real payroll.
