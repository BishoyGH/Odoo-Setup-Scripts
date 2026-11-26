"""Unit tests for the Egyptian payroll rules (no Odoo needed).

Run from the repository root:  python -m unittest discover -s tests/python
"""
import importlib.util
import pathlib
import unittest

_PATH = (pathlib.Path(__file__).resolve().parents[2]
         / "addons" / "l10n_eg_payroll_oss" / "models" / "eg_rules.py")
_spec = importlib.util.spec_from_file_location("eg_rules", _PATH)
eg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eg)


class SocialInsuranceTest(unittest.TestCase):
    def test_rates_inside_limits(self):
        self.assertEqual(eg.employee_social_insurance(10000, 2026), 1100.0)
        self.assertEqual(eg.employer_social_insurance(10000, 2026), 1875.0)

    def test_clamped_to_2026_limits(self):
        self.assertEqual(eg.insurable_wage(1000, 2026), 2700.0)
        self.assertEqual(eg.insurable_wage(50000, 2026), 16700.0)
        self.assertEqual(eg.employee_social_insurance(50000, 2026), 1837.0)
        self.assertEqual(eg.employer_social_insurance(50000, 2026), 3131.25)

    def test_2025_limits_and_unknown_years(self):
        self.assertEqual(eg.insurable_wage(50000, 2025), 14500.0)
        self.assertEqual(eg.insurable_wage(50000, 2030), 16700.0)  # latest known year
        self.assertEqual(eg.insurable_wage(50000, 2010), 14500.0)  # earliest known year

    def test_no_wage_no_insurance(self):
        self.assertEqual(eg.employee_social_insurance(0, 2026), 0.0)


class SalaryTaxTest(unittest.TestCase):
    def test_zero_band(self):
        self.assertEqual(eg.annual_salary_tax(40000), 0.0)
        self.assertEqual(eg.annual_salary_tax(-5), 0.0)

    def test_full_table(self):
        # 1,500 + 2,250 + 26,000 + 45,000 + 25% of 160,860 = 114,965
        # (a published worked example: EGP 600,000 gross, taxable 560,860).
        self.assertEqual(eg.annual_salary_tax(560860), 114965.0)

    def test_first_band_dropped_above_600k(self):
        # 10% on 0-55k, 15% on 55-70k, 20% on 70-200k, 22.5% on 200-400k, 25% above.
        expected = 5500 + 2250 + 26000 + 45000 + 0.25 * 250000
        self.assertEqual(eg.annual_salary_tax(650000), expected)

    def test_only_two_bands_above_1_2m(self):
        expected = 0.25 * 1200000 + 0.275 * 300000
        self.assertEqual(eg.annual_salary_tax(1500000), expected)

    def test_monthly_withholding(self):
        # 15,000 gross, 1,100 insurance: (13,900 x 12) - 20,000 = 146,800 taxable
        # = 1,500 + 2,250 + 20% of 76,800 = 19,110 a year.
        self.assertEqual(eg.monthly_salary_tax(15000, 1100), round(19110 / 12, 2))

    def test_martyrs_fund(self):
        self.assertEqual(eg.martyrs_fund(10000), 5.0)


class HelperObjectTest(unittest.TestCase):
    def test_year_is_applied(self):
        self.assertEqual(eg.EgyptPayroll(2025).insurable_wage(50000), 14500.0)
        self.assertEqual(eg.EgyptPayroll(2026).insurable_wage(50000), 16700.0)


if __name__ == "__main__":
    unittest.main()
