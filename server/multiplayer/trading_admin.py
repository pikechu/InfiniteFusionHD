"""Offline operator controls. Never expose grants or pause controls over HTTP."""
import argparse
import json
from pathlib import Path
import sqlite3

from service import Store, database_instance_lock
from production_data import SCHEMA_VERSION


def migrate(database, backup):
    """Offline schema migration with a complete backup before any recovery/write."""
    from production_ops import snapshot
    database, backup = Path(database).resolve(), Path(backup).resolve()
    if not database.is_file() or backup.exists() or database == backup:
        raise RuntimeError('Migration requires an existing database and a new backup path')
    with database_instance_lock(database):
        connection = sqlite3.connect(database)
        try:
            tables = {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            production = 'deployment_meta' in tables
            if production:
                version = dict(connection.execute('SELECT name,value FROM deployment_meta')).get('schema_version')
                if version not in tuple(str(value) for value in range(1, SCHEMA_VERSION+1)):
                    raise RuntimeError('Unsupported deployment schema')
        finally:
            connection.close()
        # Snapshot is made before Store can add tables or perform recovery.
        snapshot(database, backup)
        store = Store(database, synchronous='FULL', create=False)
        try:
            with store.lock, store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                migrated_assets, unresolved_assets = 0, 0
                current_catalog = None
                for row in db.execute('SELECT id,document FROM hosted_assets').fetchall():
                    asset = json.loads(row['document'])
                    if 'asset_rules_hash' in asset:
                        continue
                    if current_catalog is None:
                        current_catalog = store.catalog()
                    origin = store.asset_origin_catalog(asset,current_catalog)
                    if origin is None:
                        unresolved_assets += 1
                        continue
                    asset['asset_rules_hash'] = store.asset_contract(origin)
                    db.execute('UPDATE hosted_assets SET document=? WHERE id=?',(json.dumps(asset,ensure_ascii=False),row['id']))
                    migrated_assets += 1
                result = store.economy_audit(db)
                if not result['ok']:
                    raise RuntimeError('Migration found inconsistent currency state')
                if production:
                    db.execute("UPDATE deployment_meta SET value=? WHERE name='schema_version'",(str(SCHEMA_VERSION),))
            return {'ok': True, 'backup': str(backup), 'schema_version': SCHEMA_VERSION if production else None, 'economy_schema': 1, 'migrated_assets':migrated_assets, 'unresolved_assets':unresolved_assets}
        finally:
            store.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', required=True, type=Path)
    commands = parser.add_subparsers(dest='action', required=True)
    grant = commands.add_parser('grant', help='Issue a unique, audited closed-beta grant')
    grant.add_argument('--username', required=True)
    grant.add_argument('--event-id', required=True)
    grant.add_argument('--coins', type=int, default=0)
    grant.add_argument('--catalog-slots', type=int, nargs='*', default=[])
    grant.add_argument('--items', nargs='*', default=[], help='Approved item quantities, e.g. POTION=10')
    commands.add_parser('audit')
    commands.add_parser('pause')
    commands.add_parser('resume')
    migration = commands.add_parser('migrate')
    migration.add_argument('--backup', required=True, type=Path)
    args = parser.parse_args()
    if not args.database.is_file():
        parser.error('Database must exist. Stop its service before operator commands.')
    if args.action == 'migrate':
        print(json.dumps(migrate(args.database, args.backup), ensure_ascii=False, indent=2))
        return
    with database_instance_lock(args.database):
        store = Store(args.database, synchronous='FULL', create=False)
        try:
            with store.lock, store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                if args.action == 'grant':
                    row = db.execute('SELECT owner FROM accounts WHERE username=?', (args.username.lower(),)).fetchone()
                    if row is None:
                        parser.error('Registered username does not exist')
                    items = {}
                    for value in args.items:
                        item_id, separator, quantity = value.partition('=')
                        if separator != '=' or not quantity.isdecimal() or item_id in items:
                            parser.error('Use one ITEM_ID=positive_integer entry per item')
                        items[item_id] = int(quantity)
                    result = store.trading_grant(db, row[0], args.coins, args.catalog_slots, args.event_id, items)
                elif args.action == 'audit':
                    result = store.economy_audit(db)
                else:
                    enabled = args.action == 'resume'
                    db.execute("UPDATE economy_meta SET value=? WHERE name='enabled'", ('true' if enabled else 'false',))
                    result = {'enabled': enabled}
            print(json.dumps(result, ensure_ascii=False, indent=2))
        finally:
            store.close()


if __name__ == '__main__':
    main()
