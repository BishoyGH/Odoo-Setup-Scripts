"""Starts odoo-bin without the PG* / ODOO_* environment variables.

Odoo 19 reads PGUSER, PGPASSWORD, PGHOST, PGPORT, PGDATABASE and a few more
from the environment, and they win over odoo.conf. A PC that has another
PostgreSQL (or a CI runner, which sets PGUSER=postgres) would then make Odoo
connect as the wrong user. odoo.conf is the single source of truth here.

Usage: python odoo-launch.py <path to odoo-bin> [odoo arguments...]
"""
import os
import runpy
import sys

OVERRIDES = (
    'PGDATABASE', 'PGUSER', 'PGPASSWORD', 'PGPATH', 'PGHOST', 'PGHOST_REPLICA',
    'PGPORT', 'PGPORT_REPLICA', 'PGSSLMODE', 'PGAPPNAME', 'PGDATABASE_TEMPLATE',
    'ODOO_RC', 'ODOO_DEV',
)

for name in OVERRIDES:
    os.environ.pop(name, None)

odoo_bin = os.path.abspath(sys.argv[1])
sys.argv = [odoo_bin] + sys.argv[2:]
sys.path.insert(0, os.path.dirname(odoo_bin))
runpy.run_path(odoo_bin, run_name='__main__')
