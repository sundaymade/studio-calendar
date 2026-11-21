#!/usr/bin/env python3
"""Read-only search over Apple Mail on this Mac (every account Mail.app has: iCloud, Gmail, Exchange …).

The planner calls it to find things like flight times, booking confirmations or tickets.
It only reads Mail's own index and message files; it never changes, moves or sends anything.

  python3 mail.py search lufthansa boarding      words must all appear (subject, sender, preview)
  python3 mail.py search "START Hack" --days 30  only the last 30 days (default 365)
  python3 mail.py read 66736                     the whole message: headers, text, attachment names

Needs Full Disk Access for the app that starts it (System Settings > Privacy & Security).
"""
import argparse
import datetime as dt
import email
import email.policy
import glob
import html
import os
import re
import sqlite3
import sys
import urllib.parse

MAIL = os.path.expanduser("~/Library/Mail")


def store():
    versions = sorted(glob.glob(os.path.join(MAIL, "V[0-9]*")), key=lambda p: int(os.path.basename(p)[1:]))
    if not versions:
        sys.exit("Apple Mail data not found (or no Full Disk Access).")
    return versions[-1]


def connect(root):
    path = os.path.join(root, "MailData", "Envelope Index")
    try:
        db = sqlite3.connect(f"file:{urllib.parse.quote(path)}?mode=ro", uri=True)
        db.execute("select 1 from messages limit 1")
        return db
    except sqlite3.Error as e:
        sys.exit(f"Cannot read Apple Mail ({e}). The app needs Full Disk Access.")


def local(ts):
    return dt.datetime.fromtimestamp(ts).strftime("%a %d.%m.%Y %H:%M") if ts else "?"


def mailbox_name(url):
    path = urllib.parse.unquote(url.split("://", 1)[-1].split("/", 1)[-1])
    return path.replace("[Gmail]/", "")


def search(args):
    root = store()
    db = connect(root)
    since = (dt.datetime.now() - dt.timedelta(days=args.days)).timestamp()
    where, params = ["m.deleted = 0", "m.date_received >= ?"], [since]
    for word in args.words:
        like = f"%{word}%"
        where.append("(s.subject LIKE ? OR a.address LIKE ? OR a.comment LIKE ? OR su.summary LIKE ?)")
        params += [like] * 4
    rows = db.execute(f"""
        SELECT m.ROWID, m.date_received, a.comment, a.address, s.subject, su.summary, b.url, m.conversation_id
        FROM messages m
        JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN summaries su ON su.ROWID = m.summary
        LEFT JOIN mailboxes b ON b.ROWID = m.mailbox
        WHERE {' AND '.join(where)}
        ORDER BY m.date_received DESC
        LIMIT ?""", params + [args.limit * 3]).fetchall()
    seen, shown = set(), 0
    for rid, ts, name, addr, subject, summary, url, conv in rows:
        key = (subject, ts // 60 if ts else 0, addr)   # the same mail in Inbox and All Mail
        if key in seen:
            continue
        seen.add(key)
        sender = f"{name} <{addr}>" if name else (addr or "?")
        preview = re.sub(r"\s+", " ", summary or "").strip()[:220]
        print(f"#{rid} · {local(ts)} · {sender} · [{mailbox_name(url or '')}]")
        print(f"  {subject}")
        if preview:
            print(f"  {preview}")
        shown += 1
        if shown >= args.limit:
            break
    if not shown:
        print("No mail found. Try fewer or other words (sender name, airline, booking code), or more --days.")


def find_file(root, rid, url):
    pattern = f"**/Messages/{rid}*.emlx"
    if url and "://" in url:
        account, _, path = url.split("://", 1)[1].partition("/")
        parts = [p + ".mbox" for p in urllib.parse.unquote(path).split("/") if p]
        base = os.path.join(root, account, *parts)
        hits = glob.glob(os.path.join(glob.escape(base), pattern), recursive=True)
        if hits:
            return hits[0]
    hits = glob.glob(os.path.join(glob.escape(root), pattern), recursive=True)
    return hits[0] if hits else None


def text_of(msg):
    plain, markup, files = [], [], []
    for part in msg.walk():
        if part.is_multipart():
            continue
        name = part.get_filename()
        kind = part.get_content_type()
        if name or part.get_content_disposition() == "attachment":
            files.append(f"{name or 'unnamed'} ({kind})")
            continue
        try:
            body = part.get_content()
        except Exception:
            payload = part.get_payload(decode=True) or b""
            body = payload.decode("utf-8", "replace")
        if not isinstance(body, str):
            continue
        (plain if kind == "text/plain" else markup if kind == "text/html" else []).append(body)
    if plain:
        text = "\n".join(plain)
    else:
        text = "\n".join(markup)
        text = re.sub(r"(?is)<(script|style|head)[^>]*>.*?</\1>", " ", text)
        text = re.sub(r"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6])>", "\n", text)
        text = html.unescape(re.sub(r"<[^>]+>", " ", text))
    text = re.sub(r"[ \t ]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text).strip()
    return text, files


def read(args):
    root = store()
    db = connect(root)
    row = db.execute("""
        SELECT m.date_received, s.subject, b.url FROM messages m
        JOIN subjects s ON s.ROWID = m.subject LEFT JOIN mailboxes b ON b.ROWID = m.mailbox
        WHERE m.ROWID = ?""", (args.id,)).fetchone()
    if not row:
        sys.exit(f"No mail #{args.id}.")
    ts, subject, url = row
    path = find_file(root, args.id, url)
    if not path:
        print(f"#{args.id} · {local(ts)} · {subject}")
        sys.exit("The message body is not downloaded on this Mac (only the preview from search is available).")
    with open(path, "rb") as f:
        f.readline()                      # .emlx starts with the byte count
        msg = email.message_from_binary_file(f, policy=email.policy.default)
    for h in ("From", "To", "Cc", "Date", "Subject"):
        if msg[h]:
            print(f"{h}: {msg[h]}")
    print(f"Mailbox: {mailbox_name(url or '')}")
    body, files = text_of(msg)
    if files:
        print("Attachments: " + ", ".join(files))
    print()
    print(body[: args.max] + ("\n[… cut]" if len(body) > args.max else ""))


def main():
    p = argparse.ArgumentParser(description="Read-only Apple Mail search")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search")
    s.add_argument("words", nargs="+")
    s.add_argument("--days", type=int, default=365)
    s.add_argument("--limit", type=int, default=15)
    s.set_defaults(fn=search)
    r = sub.add_parser("read")
    r.add_argument("id", type=lambda v: int(v.lstrip("#")))
    r.add_argument("--max", type=int, default=12000)
    r.set_defaults(fn=read)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
