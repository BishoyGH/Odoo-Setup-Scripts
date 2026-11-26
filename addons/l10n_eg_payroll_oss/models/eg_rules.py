"""Egyptian payroll rules as plain Python (no Odoo imports, so they can be unit-tested alone).

Salary rules call these through ``tools.egypt`` (see hr_payslip.py).

Every rate and limit below is a legal value that changes over time. Check them with your
accountant every January and update ``SOCIAL_INSURANCE_LIMITS`` when NOSI publishes new limits.

Sources (checked November 2026):
* Social insurance, Law 148/2019: employee 11 %, employer 18.75 % of the insurable wage,
  clamped between a monthly minimum and maximum that rise every January.
  2026: EGP 2,700 - 16,700 (NOSI announcement of 30 Nov 2025). 2025: EGP 2,300 - 14,500.
* Salary income tax, Law 91/2005 as amended by Law 175/2023 and Law 7/2024: annual personal
  exemption EGP 20,000 and the bracket table below. Above EGP 600,000 a year the lower
  brackets are withdrawn step by step (ELIMINATION).
* Martyrs Fund, Law 4/2021: 0.05 % of the gross wage, deducted from the employee.
"""

SI_EMPLOYEE_RATE = 0.11
SI_EMPLOYER_RATE = 0.1875
MARTYRS_FUND_RATE = 0.0005
PERSONAL_EXEMPTION = 20000.0

# Monthly insurable wage limits by calendar year: (minimum, maximum).
SOCIAL_INSURANCE_LIMITS = {
    2025: (2300.0, 14500.0),
    2026: (2700.0, 16700.0),
}

# Annual taxable income bands: (upper limit or None for no limit, rate).
TAX_BRACKETS = (
    (40000.0, 0.0),
    (55000.0, 0.10),
    (70000.0, 0.15),
    (200000.0, 0.20),
    (400000.0, 0.225),
    (1200000.0, 0.25),
    (None, 0.275),
)

# Higher incomes lose the lowest bands: (annual taxable income up to, bands dropped).
# When bands are dropped, the first remaining band starts from zero.
ELIMINATION = (
    (600000.0, 0),
    (700000.0, 1),
    (800000.0, 2),
    (900000.0, 3),
    (1200000.0, 4),
    (None, 5),
)


def _round(amount):
    return round(amount + 0.0, 2)


def social_insurance_limits(year=None):
    """Monthly (minimum, maximum) insurable wage for a year; the latest known year if newer."""
    known = sorted(SOCIAL_INSURANCE_LIMITS)
    if year is None or year > known[-1]:
        year = known[-1]
    elif year < known[0]:
        year = known[0]
    return SOCIAL_INSURANCE_LIMITS[year]


def insurable_wage(monthly_wage, year=None):
    """Clamps the monthly wage to the insurable range. Zero stays zero (no salary, no insurance)."""
    if not monthly_wage or monthly_wage <= 0:
        return 0.0
    low, high = social_insurance_limits(year)
    return float(min(max(monthly_wage, low), high))


def employee_social_insurance(monthly_wage, year=None):
    return _round(insurable_wage(monthly_wage, year) * SI_EMPLOYEE_RATE)


def employer_social_insurance(monthly_wage, year=None):
    return _round(insurable_wage(monthly_wage, year) * SI_EMPLOYER_RATE)


def martyrs_fund(monthly_gross):
    if not monthly_gross or monthly_gross <= 0:
        return 0.0
    return _round(monthly_gross * MARTYRS_FUND_RATE)


def _bands_for(taxable):
    dropped = 0
    for limit, count in ELIMINATION:
        if limit is None or taxable <= limit:
            dropped = count
            break
    return TAX_BRACKETS[dropped:]


def annual_salary_tax(annual_taxable):
    """Tax on annual taxable income (already net of social insurance and the personal exemption)."""
    if not annual_taxable or annual_taxable <= 0:
        return 0.0
    tax = 0.0
    lower = 0.0
    for upper, rate in _bands_for(annual_taxable):
        top = annual_taxable if upper is None else min(annual_taxable, upper)
        if top > lower:
            tax += (top - lower) * rate
        if upper is None or annual_taxable <= upper:
            break
        lower = upper
    return _round(tax)


def monthly_salary_tax(monthly_gross, monthly_social_insurance=0.0, exemption=PERSONAL_EXEMPTION):
    """Monthly withholding: the month is annualised, taxed, and divided by 12."""
    annual_taxable = (monthly_gross - monthly_social_insurance) * 12.0 - exemption
    return _round(annual_salary_tax(annual_taxable) / 12.0)


class EgyptPayroll:
    """Year-bound helpers handed to salary rule code as ``tools.egypt``."""

    def __init__(self, year=None):
        self.year = year

    def insurable_wage(self, monthly_wage):
        return insurable_wage(monthly_wage, self.year)

    def employee_social_insurance(self, monthly_wage):
        return employee_social_insurance(monthly_wage, self.year)

    def employer_social_insurance(self, monthly_wage):
        return employer_social_insurance(monthly_wage, self.year)

    def martyrs_fund(self, monthly_gross):
        return martyrs_fund(monthly_gross)

    def monthly_salary_tax(self, monthly_gross, monthly_social_insurance=0.0):
        return monthly_salary_tax(monthly_gross, monthly_social_insurance)

    def annual_salary_tax(self, annual_taxable):
        return annual_salary_tax(annual_taxable)
