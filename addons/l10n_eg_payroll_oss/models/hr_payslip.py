from odoo import models

from . import eg_rules


class HrPayslip(models.Model):
    _inherit = "hr.payslip"

    def _get_tools_dict(self):
        """Expose the Egyptian rules to salary rule code as ``tools.egypt``."""
        res = super()._get_tools_dict()
        year = self.date_to.year if self.date_to else None
        res["egypt"] = eg_rules.EgyptPayroll(year)
        return res
