#!/usr/bin/env python3
"""Veroeffentlicht die Owner-Policy (kind:30177) fuer einen Agenten.

Aufruf:
  publish-agent-policy.py --owner <nsec|hex> --agent <npub|hex> --name "Tuatara" \
      --relay https://buzz.example [--respond-to allowlist --allow <pubkey>] [--dry-run]
  publish-agent-policy.py --owner-stdin --agent <npub|hex> --name "Tuatara" ...
  publish-agent-policy.py --selftest

--owner-stdin liest den Schluessel von der Standardeingabe, statt ihn als
Argument zu nehmen. Argumente stehen waehrend des Laufs in der Prozessliste und
koennen in der Shell-History landen; im Buzz-Repo ist genau das ein eigenes
Thema (Issue #4032). An einem Terminal fragt das Skript verdeckt nach, sonst
liest es die erste Zeile:

  grep -E '^BUZZ_OWNER_KEY=' .env | cut -d= -f2- | \
    publish-agent-policy.py --owner-stdin --agent <npub> --name "Tuatara"

Warum das noetig ist
--------------------
Die NIP-OA-Attestierung im kind:0 macht den Agenten fuer die Desktop-App zu
einem Agenten (`is_agent = owner_pubkey.is_some()`, nostr_convert/user_search.rs).
Sie macht ihn aber NICHT auffindbar: das Agentenverzeichnis wird aus
owner-signierten kind:30177-Koordinaten und relay-signierten kind:39002-Mitglieder-
listen aufgebaut (commands/agent_discovery/relay_directory.rs). Fehlt die 30177,
ist der Agent markiert aber nicht zugelassen - und jeder Picker filtert ihn
heraus, als Agent wie als Teilnehmer.

Diese Koordinate kann nur der OWNER signieren. Buzz Desktop legt sie beim
Anlegen eines managed Agents an; fuer einen extern betriebenen Agenten gibt es
keinen CLI-Weg (buzz agents draft-create schickt nur einen Entwurf zur
Freigabe und legt einen NEUEN Schluessel an). Deshalb dieses Skript.

Es laeuft auf dem Host, nie im Container: der Owner-Schluessel bleibt hier.
Die Krypto kommt aus mint-auth-tag.py im selben Verzeichnis - eine
Implementierung, ein Selftest.

Reines Python ab 3.9, keine Abhaengigkeiten.
"""
import argparse
import base64
import getpass
import hashlib
import importlib.util
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import List, Optional

if sys.version_info < (3, 9):
    raise SystemExit("Dieses Skript braucht Python 3.9 oder neuer.")


def load_mint_module():
    """Laedt mint-auth-tag.py als Modul (Bindestrich verhindert ein import).

    Ohne dont_write_bytecode legt der Import ein __pycache__ neben das Skript -
    ein Artefakt im Repo, das niemand bestellt hat.
    """
    here = Path(__file__).resolve().parent
    for candidate in (here / "mint-auth-tag.py", here / "tools" / "mint-auth-tag.py"):
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location("mint_auth_tag", candidate)
            assert spec and spec.loader
            module = importlib.util.module_from_spec(spec)
            previous = sys.dont_write_bytecode
            sys.dont_write_bytecode = True
            try:
                spec.loader.exec_module(module)
            finally:
                sys.dont_write_bytecode = previous
            return module
    raise SystemExit(
        "FEHLER: mint-auth-tag.py nicht gefunden. Dieses Skript gehoert daneben\n"
        "       (tools/), damit Signieren und Schluesselparsen nur einmal existieren."
    )


mint = load_mint_module()

RESPOND_TO_MODES = ("owner-only", "allowlist", "anyone")
KIND_MANAGED_AGENT = 30177
KIND_HTTP_AUTH = 27235


def serialize_event(pubkey: str, created_at: int, kind: int, tags: list, content: str) -> bytes:
    """NIP-01-Serialisierung fuer die Event-ID: [0,pubkey,created_at,kind,tags,content]."""
    return json.dumps(
        [0, pubkey, created_at, kind, tags, content],
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def build_event(seckey: int, kind: int, tags: list, content: str, created_at: Optional[int] = None) -> dict:
    """Baut ein vollstaendiges, signiertes Nostr-Event und verifiziert es selbst."""
    pubkey = mint.pubkey_of(seckey).hex()
    created_at = int(time.time()) if created_at is None else created_at
    event_id = hashlib.sha256(serialize_event(pubkey, created_at, kind, tags, content)).hexdigest()
    sig = mint.schnorr_sign(bytes.fromhex(event_id), seckey, os.urandom(32))
    if not mint.schnorr_verify(bytes.fromhex(event_id), bytes.fromhex(pubkey), sig):
        raise SystemExit("FEHLER: eigene Signatur verifiziert nicht - nichts gesendet.")
    return {
        "id": event_id,
        "pubkey": pubkey,
        "created_at": created_at,
        "kind": kind,
        "tags": tags,
        "content": content,
        "sig": sig.hex(),
    }


def policy_content(name: str, respond_to: str, allowlist: List[str], parallelism: int) -> str:
    """Der Inhalt, den die Desktop-App als ManagedAgentEventContent liest.

    name, parallelism und respond_to sind Pflichtfelder (kein serde default) -
    fehlt eines, verwirft der Parser die Koordinate still und der Agent bleibt
    unsichtbar. respond_to_allowlist nur, wenn nicht leer (skip_serializing_if).
    """
    content = {"name": name, "parallelism": parallelism, "respond_to": respond_to}
    if allowlist:
        content["respond_to_allowlist"] = allowlist
    return json.dumps(content, separators=(",", ":"), ensure_ascii=False)


def nip98_header(seckey: int, method: str, url: str, body: bytes) -> str:
    """Authorization-Header fuer POST /events: 'Nostr <base64(kind-27235-Event)>'.

    Pflichtfelder laut buzz-auth/src/nip98.rs: genau ein u-Tag (normalisierter
    Vergleich gegen https://<host>/events), genau ein method-Tag, created_at
    innerhalb +/-60 s, payload = sha256(body) hex.
    """
    tags = [
        ["u", url],
        ["method", method],
        ["nonce", str(uuid.uuid4())],
        ["payload", hashlib.sha256(body).hexdigest()],
    ]
    event = build_event(seckey, KIND_HTTP_AUTH, tags, "")
    raw = json.dumps(event, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return "Nostr " + base64.b64encode(raw).decode("ascii")


def http_base(relay_url: str) -> str:
    """wss:// -> https://, ws:// -> http://, Schraegstrich am Ende weg."""
    url = relay_url.strip()
    if url.startswith("wss://"):
        url = "https://" + url[len("wss://") :]
    elif url.startswith("ws://"):
        url = "http://" + url[len("ws://") :]
    if not url.startswith(("http://", "https://")):
        raise SystemExit(f"FEHLER: --relay braucht ein Schema (https:// oder wss://), ist: {relay_url!r}")
    return url.rstrip("/")


def query_relay(base: str, seckey: int, filter_obj: dict) -> list:
    """POST /query mit einem Filter, wie es auch das buzz-CLI macht.

    Lesen braucht dieselbe NIP-98-Signatur wie Schreiben; das Relay laesst
    keine anonymen Abfragen zu. Gibt die Events als Liste zurueck, bei
    unerwarteter Antwort eine leere.
    """
    url = f"{base}/query"
    body = json.dumps([filter_obj], separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "content-type": "application/json",
            "authorization": nip98_header(seckey, "POST", url, body),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            parsed = json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise SystemExit(f"FEHLER: Relay antwortet auf die Abfrage {error.code}: {detail}")
    except urllib.error.URLError as error:
        raise SystemExit(f"FEHLER: Relay nicht erreichbar: {error.reason}")
    except ValueError as error:
        raise SystemExit(f"FEHLER: Relay-Antwort ist kein JSON: {error}")
    return parsed if isinstance(parsed, list) else []


def post_event(base: str, seckey: int, event: dict) -> str:
    url = f"{base}/events"
    body = json.dumps(event, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "content-type": "application/json",
            "authorization": nip98_header(seckey, "POST", url, body),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise SystemExit(f"FEHLER: Relay antwortet {error.code}: {detail}")
    except urllib.error.URLError as error:
        raise SystemExit(f"FEHLER: Relay nicht erreichbar: {error.reason}")


# Signiertes Beispiel-Event aus docs/nips/NIP-OA.md im Buzz-Repo. Prueft die
# Serialisierung der Event-ID gegen eine Quelle, die nicht dieses Skript ist.
NIP_OA_EXAMPLE = {
    "id": "d892a65e7677e0554ebb70ee16deeb6a0727dba46450fb4bc001291d7bff971b",
    "pubkey": "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
    "created_at": 1713956400,
    "kind": 1,
    "tags": [
        [
            "auth",
            "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            "kind=1&created_at<1713957000",
            "8b7df2575caf0a108374f8471722b233c53f9ff827a8b0f91861966c3b9dd5cb"
            "2e189eae9f49d72187674c2f5bd244145e10ff86c9f257ffe65a1ee5f108b369",
        ]
    ],
    "content": "owner-attested agent event",
    "sig": "7fd38992b70b5e9e113644e51b4c8ee2227f3bdd402b1855f8786c0600394ab3"
    "ec2621742a7bad0b0000b93d4d1ae6e39525f286a3c1029f43f46c3359a6c76f",
}


def selftest() -> int:
    failures = 0

    got = hashlib.sha256(
        serialize_event(
            NIP_OA_EXAMPLE["pubkey"],
            NIP_OA_EXAMPLE["created_at"],
            NIP_OA_EXAMPLE["kind"],
            NIP_OA_EXAMPLE["tags"],
            NIP_OA_EXAMPLE["content"],
        )
    ).hexdigest()
    if got == NIP_OA_EXAMPLE["id"]:
        print("  Event-ID gegen NIP-OA-Beispiel: ok", file=sys.stderr)
    else:
        print(f"FEHLER Event-ID: {got} statt {NIP_OA_EXAMPLE['id']}", file=sys.stderr)
        failures += 1

    if mint.schnorr_verify(
        bytes.fromhex(NIP_OA_EXAMPLE["id"]),
        bytes.fromhex(NIP_OA_EXAMPLE["pubkey"]),
        bytes.fromhex(NIP_OA_EXAMPLE["sig"]),
    ):
        print("  Signatur des Beispiel-Events: ok", file=sys.stderr)
    else:
        print("FEHLER: Signatur des NIP-OA-Beispiels verifiziert nicht", file=sys.stderr)
        failures += 1

    # Eigenes Event signieren und verifizieren, inklusive Umlaut im Namen:
    # ensure_ascii=False gehoert zur Serialisierung, sonst weicht die ID ab.
    seckey = int("0000000000000000000000000000000000000000000000000000000000000003", 16)
    agent = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    content = policy_content("Tuatara Groß", "allowlist", [agent], 1)
    event = build_event(seckey, KIND_MANAGED_AGENT, [["d", agent]], content)
    recomputed = hashlib.sha256(
        serialize_event(event["pubkey"], event["created_at"], event["kind"], event["tags"], event["content"])
    ).hexdigest()
    if recomputed == event["id"] and mint.schnorr_verify(
        bytes.fromhex(event["id"]), bytes.fromhex(event["pubkey"]), bytes.fromhex(event["sig"])
    ):
        print("  eigenes kind:30177 signiert und verifiziert: ok", file=sys.stderr)
    else:
        print("FEHLER: eigenes Event verifiziert nicht", file=sys.stderr)
        failures += 1

    if json.loads(content)["respond_to"] != "allowlist":
        print("FEHLER: Inhalt der Policy ist nicht lesbar", file=sys.stderr)
        failures += 1

    header = nip98_header(seckey, "POST", "https://buzz.example/events", b"{}")
    decoded = json.loads(base64.b64decode(header[len("Nostr ") :]))
    if decoded["kind"] != KIND_HTTP_AUTH or ["method", "POST"] not in decoded["tags"]:
        print("FEHLER: NIP-98-Header hat nicht die erwartete Form", file=sys.stderr)
        failures += 1
    elif abs(decoded["created_at"] - int(time.time())) > 5:
        print("FEHLER: NIP-98-Zeitstempel weicht ab", file=sys.stderr)
        failures += 1
    else:
        print("  NIP-98-Header: ok", file=sys.stderr)

    if failures:
        print(f"{failures} Pruefung(en) fehlgeschlagen.", file=sys.stderr)
        return 1
    print("Alle Pruefungen bestanden.", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Veroeffentlicht die Owner-Policy (kind:30177) fuer einen extern betriebenen Agenten.",
        epilog="Der Owner-Schluessel verlaesst diesen Rechner nicht; gesendet wird nur das signierte Event.",
    )
    parser.add_argument("--owner", help="Owner-Privkey (nsec oder 64 Hex) - derselbe wie bei mint-auth-tag.py")
    parser.add_argument("--owner-stdin", action="store_true",
                        help="Owner-Privkey von stdin lesen, statt ihn in die Prozessliste zu stellen")
    parser.add_argument("--agent", help="Agent-Pubkey (npub oder 64 Hex)")
    parser.add_argument("--name", help="Anzeigename im Agentenverzeichnis")
    parser.add_argument("--relay", help="Relay-URL, https:// oder wss:// (Standard: BUZZ_RELAY_URL)")
    parser.add_argument("--respond-to", default="owner-only", choices=RESPOND_TO_MODES,
                        help="Wen der Agent bedienen darf (Standard: owner-only)")
    parser.add_argument("--allow", default="", help="Kommagetrennte Pubkeys fuer --respond-to allowlist")
    parser.add_argument("--parallelism", type=int, default=1, help="Parallele Sessions (Standard: 1)")
    parser.add_argument("--dry-run", action="store_true", help="Event nur ausgeben, nichts senden")
    parser.add_argument("--selftest", action="store_true", help="Selbsttest, kein Netz")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    if args.owner_stdin:
        if args.owner:
            parser.error("--owner und --owner-stdin schliessen sich aus")
        # Am Terminal verdeckt nachfragen, sonst die erste Zeile der Pipe.
        # Nur die erste Zeile: ein angehaengtes Newline oder weitere Ausgabe
        # einer Pipe darf den Schluessel nicht verfaelschen.
        args.owner = (
            getpass.getpass("Owner-Privkey (wird nicht angezeigt): ")
            if sys.stdin.isatty()
            else sys.stdin.readline()
        ).strip()
        if not args.owner:
            raise SystemExit("FEHLER: --owner-stdin, aber nichts gelesen.")

    missing = [flag for flag, value in (("--owner", args.owner), ("--agent", args.agent), ("--name", args.name)) if not value]
    if missing:
        parser.error("fehlende Angaben: " + ", ".join(missing))

    owner_hex = mint.parse_key("Owner-Privkey", args.owner, "nsec")
    agent_hex = mint.parse_key("Agent-Pubkey", args.agent, "npub")
    seckey = int(owner_hex, 16)
    if not 1 <= seckey <= mint.N - 1:
        raise SystemExit("FEHLER: Owner-Privkey liegt ausserhalb von [1, n-1].")
    owner_pub = mint.pubkey_of(seckey).hex()
    if owner_pub == agent_hex:
        raise SystemExit(
            "FEHLER: Owner und Agent sind derselbe Schluessel. Die Koordinate muss\n"
            "       vom OWNER signiert sein und im d-Tag den AGENTEN nennen."
        )

    allowlist = [mint.parse_key("--allow", entry, "npub") for entry in args.allow.split(",") if entry.strip()]
    if args.respond_to == "allowlist" and not allowlist:
        raise SystemExit("FEHLER: --respond-to allowlist braucht mindestens einen --allow <pubkey>.")
    if args.respond_to != "allowlist" and allowlist:
        print("WARNUNG: --allow wird ohne --respond-to allowlist ignoriert.", file=sys.stderr)
        allowlist = []
    if args.parallelism < 1:
        raise SystemExit("FEHLER: --parallelism muss mindestens 1 sein.")

    content = policy_content(args.name, args.respond_to, allowlist, args.parallelism)
    event = build_event(seckey, KIND_MANAGED_AGENT, [["d", agent_hex]], content)

    print(f"Owner-Pubkey:  {owner_pub}", file=sys.stderr)
    print(f"Agent-Pubkey:  {agent_hex}", file=sys.stderr)
    print(f"Koordinate:    30177:{owner_pub}:{agent_hex}", file=sys.stderr)
    print(f"Inhalt:        {content}", file=sys.stderr)

    if args.dry_run:
        print(json.dumps(event, indent=2, ensure_ascii=False))
        print("--dry-run: nichts gesendet.", file=sys.stderr)
        return 0

    relay = args.relay or os.environ.get("BUZZ_RELAY_URL", "")
    if not relay:
        raise SystemExit("FEHLER: --relay fehlt und BUZZ_RELAY_URL ist leer.")
    base = http_base(relay)
    print(f"Ziel:          {base}/events", file=sys.stderr)
    print(post_event(base, seckey, event))
    print(
        "\nNaechster Schritt: den Agenten als Bot in die Kanaele holen -\n"
        "  buzz channels add-member --channel <uuid> --pubkey " + agent_hex + " --role bot",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
