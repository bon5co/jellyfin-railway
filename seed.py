#!/usr/bin/env python3
"""Offline helpers for the Railway Jellyfin wrapper.

`rotate` re-applies the deploy's admin credential straight to jellyfin.db.
Jellyfin exposes no non-interactive way to set a password (the dashboard needs
the current one and the reset flow needs a media client on the LAN), so a
redeploy would otherwise never be able to recover an instance.
"""
import hashlib
import os
import sqlite3
import sys

ITERATIONS = 120000


def pbkdf2(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, ITERATIONS, 64)
    return "$PBKDF2-SHA512$iterations=%d$%s$%s" % (
        ITERATIONS,
        salt.hex().upper(),
        digest.hex().upper(),
    )


def rotate(db_path: str, username: str, password: str) -> int:
    if not os.path.exists(db_path):
        return 1
    conn = sqlite3.connect(db_path)
    try:
        row = conn.execute(
            "SELECT Id, Username FROM Users ORDER BY InternalId LIMIT 1"
        ).fetchone()
        if row is None:
            return 1
        conn.execute(
            "UPDATE Users SET Username = ?, Password = ?, "
            "InvalidLoginAttemptCount = 0, MustUpdatePassword = 0 WHERE Id = ?",
            (username, pbkdf2(password), row[0]),
        )
        conn.commit()
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "rotate":
        sys.exit(rotate(sys.argv[2], sys.argv[3], os.environ["JELLYFIN_ADMIN_PASSWORD"]))
    sys.exit(2)
