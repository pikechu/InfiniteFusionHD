"""Local administrator bootstrap. Passwords are read interactively, never flags.

Run the upgraded service once to create the schema, then use this command on the
server. This opens SQLite directly and never constructs a second game Store.
"""
import argparse
import getpass
import json
from pathlib import Path
import sqlite3
import time
from urllib.parse import quote

from admin_data import ROLES, create_administrator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--username", required=True)
    parser.add_argument("--role", choices=tuple(ROLES), default="admin")
    parser.add_argument("--disable", action="store_true")
    args = parser.parse_args()
    if not args.database.is_file() or args.database.is_symlink():
        raise SystemExit("Use an existing, upgraded game database")
    password = None
    if not args.disable:
        password = getpass.getpass("Administrator password (12+ characters): ")
        if password != getpass.getpass("Repeat password: "):
            raise SystemExit("Passwords differ")
    with sqlite3.connect(args.database, timeout=10) as db:
        db.execute("PRAGMA synchronous=FULL")
        db.execute("BEGIN IMMEDIATE")
        if args.disable:
            if not db.execute("SELECT 1 FROM admin_users WHERE username=?", (args.username.lower(),)).fetchone():
                raise SystemExit("Administrator does not exist")
            db.execute("UPDATE admin_users SET enabled=0 WHERE username=?", (args.username.lower(),))
            db.execute("DELETE FROM admin_sessions WHERE username=?", (args.username.lower(),))
            secret = None
        else:
            secret = create_administrator(db, args.username, password, args.role)
        db.execute("INSERT INTO admin_audit(actor,action,target,reason,document,created) VALUES(?,?,?,?,?,?)",
                   ("local-cli", "disable_admin" if args.disable else "create_admin", args.username.lower(),
                    "Local administrator provisioning", json.dumps({"role": args.role}), time.time()))
    if secret:
        print("Add this account to an authenticator; the secret is shown only here. Keep this terminal private.")
        print("otpauth://totp/" + quote("KIF:" + args.username.lower()) + "?secret=" + secret + "&issuer=KIF&digits=6&period=30")
    else:
        print("Administrator disabled; all administrator sessions revoked.")


if __name__ == "__main__":
    main()
