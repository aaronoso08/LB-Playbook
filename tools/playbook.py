#!/usr/bin/env python3
"""Open (unscramble) and seal (scramble) the Latino Built Team Playbook page.

The Playbook's index.html holds the real page encrypted with a page key.
Staff get that key from Supabase (team_vault) after signing in. Nothing secret
lives in this file or in the repo; you pass the key in when you run it.

  Open the page to edit it:
    python3 tools/playbook.py open  --key "<page key>" --out playbook_source.html

  Seal it again with the SAME key (normal edits):
    python3 tools/playbook.py seal  --key "<page key>" --src playbook_source.html

  Seal it with a NEW key (someone left the team). Pass the current key too,
  so the private documents in docs/ get re-scrambled with the new one:
    python3 tools/playbook.py seal  --new-key --key "<current key>" --src playbook_source.html
    -> prints the SQL line to paste into Supabase so staff get the new key.

  Add or replace a private document (PDF etc.), stored scrambled in docs/:
    python3 tools/playbook.py doc   --key "<page key>" --id hhgp-faqs --file HHGP_FAQs.pdf

Never commit playbook_source.html. It is the unscrambled page.
Needs: pip install cryptography
"""
import argparse, base64, gzip, json, os, re, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "..", "index.html")


def _data_span(s):
    i = s.find("const D={")
    if i < 0:
        sys.exit("Couldn't find the encrypted data in index.html")
    i += len("const D=")
    j = s.find("};", i) + 1
    return i, j


def _read_data(s):
    i, j = _data_span(s)
    return json.loads(re.sub(r'([{,])(\w+):', r'\1"\2":', s[i:j]))


def _key_bytes(k):
    raw = base64.b64decode(k.strip(), validate=True)
    if len(raw) != 32:
        sys.exit("That doesn't look like a page key (should be 32 bytes).")
    return raw


DOCS = os.path.join(HERE, "..", "docs")


def _enc_doc(raw, data):
    iv = os.urandom(12)
    return iv + AESGCM(raw).encrypt(iv, data, None)


def _dec_doc(raw, blob):
    return AESGCM(raw).decrypt(blob[:12], blob[12:], None)


def cmd_doc(a):
    """Add or replace one private document (stored scrambled in docs/<id>.bin)."""
    raw = _key_bytes(a.key)
    s = open(INDEX, encoding="utf-8").read(); d = _read_data(s)
    try:
        AESGCM(raw).decrypt(base64.b64decode(d["iv"]), base64.b64decode(d["ct"]), None)
    except Exception:
        sys.exit("Wrong key: it doesn't unlock this page, so documents would not open either.")
    if not re.fullmatch(r"[a-z0-9-]{3,60}", a.id):
        sys.exit("Use a short id with lowercase letters, numbers and dashes.")
    os.makedirs(DOCS, exist_ok=True)
    out = os.path.join(DOCS, a.id + ".bin")
    open(out, "wb").write(_enc_doc(raw, open(a.file, "rb").read()))
    print(f"Saved docs/{a.id}.bin (scrambled). Add it to the DOCS list in the page if it's new.")


def cmd_open(a):
    s = open(INDEX, encoding="utf-8").read()
    d = _read_data(s)
    try:
        pt = AESGCM(_key_bytes(a.key)).decrypt(base64.b64decode(d["iv"]), base64.b64decode(d["ct"]), None)
    except Exception:
        sys.exit("Wrong key: it doesn't unlock this page.")
    if d.get("z"):
        pt = gzip.decompress(pt)
    open(a.out, "wb").write(pt)
    print(f"Opened -> {a.out} ({len(pt):,} bytes). Don't commit this file.")


def cmd_seal(a):
    if a.new_key:
        raw = os.urandom(32)
        bins = sorted(f for f in os.listdir(DOCS) if f.endswith(".bin")) if os.path.isdir(DOCS) else []
        if bins and not a.key:
            sys.exit("There are private documents in docs/. Pass the CURRENT key with --key so they can be re-scrambled with the new one.")
        for f in bins:
            pth = os.path.join(DOCS, f)
            open(pth, "wb").write(_enc_doc(raw, _dec_doc(_key_bytes(a.key), open(pth, "rb").read())))
        if bins:
            print(f"Re-scrambled {len(bins)} documents with the new key.")
    elif a.key:
        raw = _key_bytes(a.key)
    else:
        sys.exit("Pass --key (same key) or --new-key (change the key).")
    src = open(a.src, "rb").read()
    if b"<html" not in src[:2000].lower():
        sys.exit("The source file doesn't look like the Playbook page.")
    iv = os.urandom(12)
    ct = AESGCM(raw).encrypt(iv, gzip.compress(src, 9), None)
    b = lambda x: base64.b64encode(x).decode()
    data = {"salt": b(os.urandom(16)), "iv": b(iv), "ct": b(ct), "iter": 600000, "z": 1}
    s = open(INDEX, encoding="utf-8").read()
    i, j = _data_span(s)
    lit = "{" + ",".join(f'{k}:{json.dumps(v)}' for k, v in data.items()) + "}"
    open(INDEX, "w", encoding="utf-8").write(s[:i] + lit + s[j:])
    print(f"Sealed index.html ({len(src):,} bytes of page).")
    if a.new_key:
        key = b(raw)
        print("\nNEW KEY. Paste this into Supabase > SQL Editor > Run, right after pushing:\n")
        print(f"insert into public.team_vault(id, page_key) values (1, '{key}') "
              f"on conflict (id) do update set page_key = excluded.page_key;\n")
        print("Everyone will need to sign in again. Old saved keys stop working.")


p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
sp = p.add_subparsers(dest="cmd", required=True)
o = sp.add_parser("open"); o.add_argument("--key", required=True); o.add_argument("--out", default="playbook_source.html"); o.set_defaults(f=cmd_open)
dc = sp.add_parser("doc"); dc.add_argument("--key", required=True); dc.add_argument("--id", required=True); dc.add_argument("--file", required=True); dc.set_defaults(f=cmd_doc)
c = sp.add_parser("seal"); c.add_argument("--key"); c.add_argument("--new-key", action="store_true"); c.add_argument("--src", default="playbook_source.html"); c.set_defaults(f=cmd_seal)
a = p.parse_args(); a.f(a)
