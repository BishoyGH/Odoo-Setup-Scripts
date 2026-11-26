# Executed inside "odoo-bin shell" after apps are installed. `env` is provided by Odoo.
# Ensures the Egyptian chart of accounts is loaded for the main company.
# pylint: disable=undefined-variable
company = env.ref("base.main_company")
if "chart_template" in company._fields and not company.chart_template:
    try:
        env["account.chart.template"].try_loading("eg", company)
        print("Loaded Egyptian chart of accounts")
    except Exception as exc:  # noqa: BLE001 - report and continue, user can load it from Settings
        print("WARNING: could not load the Egyptian chart of accounts: %s" % exc)
else:
    print("Chart of accounts already set: %s" % getattr(company, "chart_template", "?"))
env.cr.commit()
print("OSS_SETUP_OK")
