# Executed inside "odoo-bin shell" by the installer (stdin). `env` is provided by Odoo.
# Values come from environment variables so non-ASCII (Arabic) names survive intact.
# pylint: disable=undefined-variable
import os

get = os.environ.get
tz = get("OSS_TZ", "Africa/Cairo")
lang = get("OSS_LANG", "en_US")

egypt = env.ref("base.eg")
egp = env.ref("base.EGP")
if not egp.active:
    egp.active = True

company = env.ref("base.main_company")
vals = {"country_id": egypt.id, "currency_id": egp.id}
if get("OSS_COMPANY_NAME"):
    vals["name"] = get("OSS_COMPANY_NAME")
# Arabic companies print with Tajawal, Odoo's bundled report font that covers Arabic and Latin
# (Odoo 16+). The default Lato has no Arabic letters, so invoices fall back to a system font.
font_field = company._fields.get("font")
if lang.startswith("ar") and font_field and "Tajawal" in dict(font_field.selection):
    vals["font"] = "Tajawal"
company.write(vals)
company.partner_id.write({"tz": tz, "lang": lang, "country_id": egypt.id})

langs = env["res.lang"].with_context(active_test=False).search([("code", "=", lang)])
if langs and not langs.active:
    langs.active = True

admin = env.ref("base.user_admin")
admin_vals = {"tz": tz, "lang": lang}
if get("OSS_ADMIN_LOGIN"):
    admin_vals["login"] = get("OSS_ADMIN_LOGIN")
    if "@" in get("OSS_ADMIN_LOGIN"):
        admin_vals["email"] = get("OSS_ADMIN_LOGIN")
if get("OSS_ADMIN_PASSWORD"):
    admin_vals["password"] = get("OSS_ADMIN_PASSWORD")
admin.write(admin_vals)

# Defaults for users and contacts created later.
env["ir.default"].set("res.partner", "tz", tz)
env["ir.default"].set("res.partner", "lang", lang)

env.cr.commit()
print("OSS_SETUP_OK")
