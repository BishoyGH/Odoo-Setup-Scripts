# ETA e-invoicing setup (Egyptian Tax Authority)

This guide takes a company from a fresh install to signed invoices accepted by
the ETA, using Odoo's `l10n_eg_edi_eta` module ("Egypt E-Invoicing"). Field
and menu names are from Odoo 19.0; 18.0 and 20.0 are the same or very close.

Do everything in the **pre-production** (test) environment first, then switch
to production.

## What you need before you start

| Item | Where it comes from |
|---|---|
| Tax registration number (9 digits) and an account on the ETA e-invoicing portal | ETA |
| A USB token (e-seal) with the company's signing certificate, and its PIN | An ETA-accredited certificate provider |
| The token driver (**ePass2003**) installed on the PC that signs | Your certificate provider |
| ERP **Client ID** and **Client Secret**, one pair for pre-production and one for production | ETA portal, after you register your ERP system |
| ETA item codes (EGS or GS1) for the products you sell | ETA portal (code registration) |
| Your activity code and branch details | Your ETA taxpayer profile |

Portals:

* Pre-production: https://preprod.invoicing.eta.gov.eg/
* Production: https://invoicing.eta.gov.eg/

## 1. Install the token driver

Plug in the token and install the driver your provider gave you. Odoo's signer
on Windows loads exactly this file:

```
C:\Windows\System32\eps2003csp11.dll
```

If that file is missing, signing fails with a "missing_dll" error. The
installer checks for it when you select the ETA app and prints a warning (it
does not stop the install). Only **one** token may be plugged in while signing.

## 2. Install the app

* New install: pick **Egyptian e-Invoicing (ETA)** in the app list.
* Existing install: Apps, search "Egypt E-Invoicing", Install.

## 3. API credentials

Accounting > Configuration > Settings > **ETA E-Invoicing Settings**:

* **ETA Client ID** and **ETA Secret**: from the portal.
* **In Production Environment**: leave unticked while testing (Odoo then talks
  to `api.preprod.invoicing.eta.gov.eg`). Tick it and enter the production pair
  when you go live.
* **Invoicing Threshold**: the invoice amount above which the customer's tax
  number becomes mandatory. Use the value your accountant confirms for this year.

## 4. Company and addresses

Settings > Companies > your company:

* **Tax ID** (VAT): the 9-digit registration number.
* Full address: country Egypt, governorate (state), city, street and
  **Building No.** (the module adds this field to addresses).

## 5. Sales journal (branch and activity)

Accounting > Configuration > Journals > Customer Invoices, ETA settings:

* **Branch**: the address record of the branch that issues the invoices.
* **ETA Branch ID**: the branch number from your ETA profile (`0` for the main branch).
* **ETA Activity Code**: your registered activity.

Use one sales journal per branch if you invoice from several branches.

## 6. Products, units and taxes

* **Products**: set the **ETA Item code** on every product you invoice
  (Odoo falls back to the barcode when the code is empty). The code must be
  registered and active on the portal.
* **Units of measure**: each unit used on invoices needs its ETA unit code
  (the module fills the common ones).
* **Taxes**: the Egyptian taxes from `l10n_eg` already carry their ETA tax code
  (for example VAT 14%). If you create your own taxes, set the ETA code on them;
  Odoo refuses to send an invoice line whose taxes have no code.

## 7. Customers

For businesses: tax number, country and full address with building number.
For individuals above the threshold: national ID in the tax ID field.
Foreign customers need their country set.

## 8. Signing with the USB token

Odoo signs in the browser through a small local signing service that talks to
the token. Two settings tie it together:

1. **Signing host**: Settings > Technical > System Parameters,
   `l10n_eg_eta.sign.host`. Default `http://localhost:8069`. It must be on
   `localhost` (or a valid `https` address), otherwise the browser blocks it.
2. **Thumb drive record**: Accounting > Configuration > ETA > Thumb Drive.
   Create one per user: **ETA USB Pin** and an **access token** (the same
   secret that the signing service has as `proxy_access_token`). Press
   **Get certificate** once; Odoo reads the certificate from the token.

The signing service is Odoo's IoT driver for the ETA token
(`iot_drivers`, routes `/hw_l10n_eg_eta/certificate` and `/hw_l10n_eg_eta/sign`).
It is **not** set up by this installer. Run it on the PC where the token is
plugged in, from Odoo's own Windows IoT software, and point
`l10n_eg_eta.sign.host` at it. If that PC also runs this Odoo server, the
signer must use a different port than Odoo (8069 by default), because the
default host value would otherwise point at Odoo itself.

> Automating the signing service is a later step on the roadmap. Until then,
> test signing in pre-production with your certificate provider's help.

## 9. Daily use

1. Confirm the invoice.
2. **Sign** it (Odoo asks the local signer, which needs the token and PIN).
3. **Send** it to the ETA. The invoice shows the ETA UUID and status, and the
   PDF prints the ETA QR code.
4. Rejected? Read the ETA error on the invoice, fix the product code, address
   or tax, reset to draft and repeat.

## Troubleshooting

| Message | Cause |
|---|---|
| `missing_dll` | ePass2003 driver not installed (see step 1). |
| `no_drive` | Token not plugged in, or Windows has not finished loading its driver. |
| `multiple_drive` | More than one token plugged in. Keep only one. |
| `unauthorized` | The thumb drive's access token does not match the signer's `proxy_access_token`. |
| Signing never starts | `l10n_eg_eta.sign.host` is wrong, or the browser blocked a non-localhost `http` address. |
| Invoice rejected for item code | Code missing on the product, or not yet active on the portal. |

## Go-live checklist

- [ ] At least one invoice and one credit note accepted in pre-production
- [ ] Production Client ID / Secret entered, **In Production Environment** ticked
- [ ] Every sold product has an active ETA item code
- [ ] Each sales journal has branch, branch ID and activity code
- [ ] Each invoicing user has a thumb drive record with the certificate loaded
