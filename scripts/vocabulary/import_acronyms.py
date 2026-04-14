#!/usr/bin/env python3
"""
Import a JSON list of acronyms into MacParakeet's custom_words SQLite table.

Usage:
    python3 import_acronyms.py [path/to/words.json]

If no path is given, defaults to ./bcbsma_acronyms.json next to this script.

Each entry must have at least `{"word": "..."}`. Optional fields:
    "replacement": "..."  — what to substitute if ASR transcribes it differently.
                            Defaults to the word itself (same case as JSON entry),
                            so the effect is "preserve this exact casing if ASR
                            produces any case variant".
    "category":    "..."  — ignored by the DB, just for your source JSON's
                            organization.

The custom_words table has a UNIQUE INDEX on `word COLLATE NOCASE`, so the
script uses `INSERT OR IGNORE` — already-present words are skipped, not
overwritten. Existing custom words you added by hand in the Vocabulary
settings are preserved.

Targets:
    ~/Library/Application Support/MacParakeet/macparakeet.db

Both the release and dev builds of MacParakeet share this path, so running the
script once populates vocabulary for both. The app reads custom_words fresh on
every transcription — no restart required.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_DB = Path.home() / "Library/Application Support/MacParakeet/macparakeet.db"
DEFAULT_JSON = Path(__file__).with_name("bcbsma_acronyms.json")


def iso_now() -> str:
    # GRDB stores Swift `Date` as ISO8601 with fractional seconds + Z.
    # Example that round-trips: "2026-04-13T21:45:12.123Z"
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        f"{datetime.now(timezone.utc).microsecond // 1000:03d}Z"


def load_entries(path: Path) -> list[dict]:
    with path.open() as f:
        data = json.load(f)
    if not isinstance(data, list):
        sys.exit(f"{path} must contain a JSON array at top level")
    return data


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("json_path", nargs="?", default=str(DEFAULT_JSON),
                   help="Path to JSON file of acronyms (default: %(default)s)")
    p.add_argument("--db", default=str(DEFAULT_DB),
                   help="Path to macparakeet.db (default: %(default)s)")
    p.add_argument("--dry-run", action="store_true",
                   help="Show what would be inserted, don't write.")
    args = p.parse_args()

    json_path = Path(args.json_path).expanduser()
    db_path = Path(args.db).expanduser()

    if not json_path.exists():
        sys.exit(f"JSON file not found: {json_path}")
    if not db_path.exists():
        sys.exit(
            f"MacParakeet database not found at {db_path}\n"
            f"Make sure MacParakeet (or MacParakeet-Dev) has launched at least once."
        )

    entries = load_entries(json_path)
    print(f"Loaded {len(entries)} entries from {json_path}")
    print(f"Target: {db_path}")
    if args.dry_run:
        print("DRY RUN — no writes will happen")

    # Connect + verify schema
    conn = sqlite3.connect(str(db_path))
    cur = conn.cursor()
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='custom_words'")
    if not cur.fetchone():
        sys.exit("custom_words table not found — the app may not have run migrations yet. Launch MacParakeet once, then re-run.")

    added = 0
    skipped = 0
    errors = 0

    for entry in entries:
        word = entry.get("word")
        if not word or not isinstance(word, str):
            print(f"  skip (no word): {entry}")
            errors += 1
            continue

        # replacement defaults to the canonical word itself so ASR variants
        # get normalized to this exact case.
        replacement = entry.get("replacement", word)

        if args.dry_run:
            print(f"  would insert: {word!r} -> {replacement!r}")
            continue

        wid = str(uuid.uuid4()).upper()  # GRDB normalizes to uppercase
        now = iso_now()
        try:
            cur.execute(
                """
                INSERT OR IGNORE INTO custom_words
                    (id, word, replacement, source, isEnabled, createdAt, updatedAt)
                VALUES (?, ?, ?, 'manual', 1, ?, ?)
                """,
                (wid, word, replacement, now, now),
            )
            if cur.rowcount == 1:
                added += 1
            else:
                skipped += 1
        except sqlite3.Error as e:
            print(f"  ERROR on {word!r}: {e}")
            errors += 1

    if not args.dry_run:
        conn.commit()
    conn.close()

    print(f"\nAdded: {added}  Skipped (already present): {skipped}  Errors: {errors}")
    print("Custom words take effect on the next dictation — no app restart needed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
