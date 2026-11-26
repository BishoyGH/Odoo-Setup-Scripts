{
    "name": "Egypt - Payroll Rules (OCA Payroll)",
    "summary": "Egyptian social insurance, salary income tax and Martyrs Fund rules "
    "for OCA Payroll",
    "version": "1.0.0",
    "category": "Payroll/Localizations",
    "license": "LGPL-3",
    "author": "Odoo-Setup-Scripts",
    "website": "https://github.com/BishoyGH/Odoo-Setup-Scripts",
    "countries": ["eg"],
    "depends": ["payroll"],
    "data": [
        "data/hr_salary_rule_category_data.xml",
        "data/hr_salary_rule_data.xml",
        "data/hr_payroll_structure_data.xml",
    ],
    "installable": True,
}
