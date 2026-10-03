#!/usr/bin/env python3
"""Richtet einen Agenten in Buzz ein - Attestierung, Profil und Policy in einem Lauf.

Aufruf:
  enroll-agent.py                      # einziger Agent aus BUZZ_AGENTS
  enroll-agent.py --agent-name tuatara # bei mehreren
  enroll-agent.py --dry-run            # Events zeigen, nichts senden
  enroll-agent.py --selftest           # ohne Netz

Was hier passiert und warum es drei Events sind
-----------------------------------------------
"Agent" ist in Buzz kein Kontotyp, sondern eine Belegkette. Die Desktop-App
verlangt zwei owner-gedeckte Beweise, und die Reihenfolge ist nicht beliebig:

1. **kind:0 mit NIP-OA-auth-Tag** - die *Markierung*. Signiert wird das Profil
   vom Agenten, das Tag darin vom Owner. Ab hier gilt die Identitaet als Agent
   (`is_agent = owner_pubkey.is_some()`, nostr_convert/user_search.rs).
2. **kind:30177, d-Tag = Agent-Pubkey** - die *Zulassung*, signiert vom Owner.
   Nur damit entsteht ein Verzeichniseintrag. Die App akzeptiert die Koordinate
   ausschliesslich, wenn ihr Autor der im kind:0 attestierte Owner ist - das
   Profil muss also vorher stehen.

Nur Schritt 1 ist der schlechteste Zustand: markiert, aber in keinem
Verzeichnis - und dann filtert jeder Picker die Identitaet heraus, als Agent
wie als Person. Deshalb macht dieses Skript beides in einem Zug.

Warum vom Host und nicht aus dem Container
------------------------------------------
Frueher lief der Profilteil als `buzz users set-profile` im Container, mit
einem Redeploy davor, damit BUZZ_AUTH_TAG in der Umgebung steht. Das Skript
schreibt das Profil stattdessen selbst: es liest das vorhandene kind:0 vom
Relay, haengt das auth-Tag an und veroeffentlicht es mit dem Schluessel des
Agenten. Vorhandene Felder (about, picture, nip05) bleiben dabei erhalten -
von Hand ging genau das gern verloren.

Die .env braucht danach trotzdem BUZZ_AUTH_TAGS: das Tag muss auch an alle
*spaeteren* Events des laufenden Agenten. Das Skript gibt die Zeile aus und
traegt sie mit --write-env selbst ein.

respond_to kommt aus agents/<name>.md
-------------------------------------
Die Policy entscheidet, wer den Agenten *auswaehlen* darf, das Frontmatter,
wem er *antwortet*. Weichen beide ab, zeigt die UI ihn an und er bleibt stumm.
Deshalb liest das Skript respond_to, respond_to_allowlist und parallelism aus
der Agentendatei, statt sie noch einmal abzufragen.

Reines Python ab 3.9, keine Abhaengigkeiten. Laeuft auf dem Host, nie im
Container: hier liegen beide privaten Schluessel.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

if sys.version_info < (3, 9):
    raise SystemExit("Dieses Skript braucht Python 3.9 oder neuer.")


def load_sibling(name: str, attr_check: str):
    """Laedt ein Nachbarskript als Modul (Bindestriche verhindern ein import)."""
    import importlib.util

    here = Path(__file__).resolve().parent
    candidate = here / name
    if not candidate.is_file():
        raise SystemExit(
            f"FEHLER: {name} nicht gefunden. Dieses Skript gehoert nach tools/,\n"
            "       damit Krypto und Relay-Zugriff nur einmal existieren."
        )
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").replace(".py", ""), candidate)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not hasattr(module, attr_check):
        raise SystemExit(f"FEHLER: {name} hat kein {attr_check} - falsche Fassung?")
    return module


mint = load_sibling("mint-auth-tag.py", "schnorr_sign")
policy = load_sibling("publish-agent-policy.py", "build_event")

KIND_PROFILE = 0


# ── .env und Agentendatei ────────────────────────────────────────────────────


def read_env(path: Path) -> Dict[str, str]:
    """Liest KEY=wert-Zeilen. Kein dotenv: Anfuehrungszeichen aussen weg, Rest roh."""
    if not path.is_file():
        raise SystemExit(f"FEHLER: {path} nicht gefunden. Mit --env einen anderen Pfad angeben.")
    values: Dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def pick_agent(agents_value: str, wanted: Optional[str]) -> Tuple[str, str]:
    """Sucht (name, privkey) aus BUZZ_AGENTS=name=key,name=key."""
    entries = []
    for entry in agents_value.split(","):
        entry = entry.strip()
        name, sep, key = entry.partition("=")
        if sep and name.strip() and key.strip():
            entries.append((name.strip(), key.strip()))
    if not entries:
        raise SystemExit("FEHLER: BUZZ_AGENTS ist leer oder hat kein 'name=key'.")
    if wanted:
        for name, key in entries:
            if name == wanted:
                return name, key
        known = ", ".join(name for name, _ in entries)
        raise SystemExit(f"FEHLER: Agent {wanted!r} steht nicht in BUZZ_AGENTS. Bekannt: {known}")
    if len(entries) > 1:
        known = ", ".join(name for name, _ in entries)
        raise SystemExit(f"FEHLER: mehrere Agenten - mit --agent-name waehlen. Bekannt: {known}")
    return entries[0]


def read_frontmatter(path: Path) -> Dict[str, str]:
    """Frontmatter aus agents/<name>.md. Bewusst nur key: value, wie render-agents.py."""
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\A---\s*\n(.*?)\n---\s*\n?", text, re.S)
    if not match:
        return {}
    meta: Dict[str, str] = {}
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, _, value = line.partition(":")
        meta[key.strip().lower()] = value.strip()
    return meta


def policy_from_frontmatter(meta: Dict[str, str]) -> Tuple[str, List[str], int]:
    """Uebersetzt das Frontmatter in die Felder der Policy.

    buzz-acp kennt owner-only, allowlist, anyone und nobody; die Policy nur die
    ersten drei. 'nobody' bekommt owner-only, sonst waere der Agent fuer die
    App gar nicht auswaehlbar - antworten tut er deshalb nicht mehr oder
    weniger, das entscheidet allein das Frontmatter.
    """
    respond_to = (meta.get("respond_to") or "owner-only").strip()
    allowlist: List[str] = []
    if respond_to == "allowlist":
        raw = meta.get("respond_to_allowlist", "")
        allowlist = [mint.parse_key("respond_to_allowlist", item, "npub")
                     for item in re.split(r"[,\s]+", raw) if item]
        if not allowlist:
            raise SystemExit(
                "FEHLER: respond_to ist 'allowlist', aber respond_to_allowlist ist leer.\n"
                "       Die Policy braucht mindestens einen Pubkey."
            )
    elif respond_to == "nobody":
        print("WARNUNG: respond_to 'nobody' kennt die Policy nicht - owner-only wird", file=sys.stderr)
        print("         veroeffentlicht. Antwortverhalten bleibt wie im Frontmatter.", file=sys.stderr)
        respond_to = "owner-only"
    elif respond_to not in policy.RESPOND_TO_MODES:
        raise SystemExit(f"FEHLER: respond_to {respond_to!r} ist unbekannt.")

    try:
        parallelism = max(1, int(meta.get("parallelism", "1")))
    except ValueError:
        parallelism = 1
    if respond_to == "owner-only" and not allowlist:
        allowlist = []
    return respond_to, allowlist, parallelism


# ── Profil ───────────────────────────────────────────────────────────────────


def fetch_profile(base: str, seckey: int, agent_pub: str) -> Optional[dict]:
    """Holt das neueste kind:0 des Agenten. None, wenn es keines gibt."""
    events = policy.query_relay(base, seckey, {"authors": [agent_pub], "kinds": [KIND_PROFILE], "limit": 1})
    return events[0] if events else None


def profile_content(existing: Optional[dict], name: Optional[str], about: Optional[str]) -> str:
    """Vorhandenes Profil uebernehmen, nur gezielt ueberschreiben.

    Von Hand ging hier regelmaessig der about-Text verloren, weil
    `buzz users set-profile --name X` ohne --about das Feld leert.
    """
    content: dict = {}
    if existing:
        try:
            parsed = json.loads(existing.get("content") or "{}")
            if isinstance(parsed, dict):
                content = parsed
        except ValueError:
            print("WARNUNG: vorhandenes Profil ist kein gueltiges JSON - es wird ersetzt.", file=sys.stderr)
    if name:
        content["name"] = name
        content.setdefault("display_name", name)
    if about is not None:
        content["about"] = about
    if not _name_in(content):
        raise SystemExit(
            "FEHLER: kein Anzeigename. Entweder steht einer im vorhandenen Profil,\n"
            "       oder --name angeben."
        )
    return json.dumps(content, separators=(",", ":"), ensure_ascii=False)


def _name_in(content: dict) -> Optional[str]:
    """Buzz schreibt den Anzeigenamen als display_name, aelteres als name.

    Die Desktop-App liest beide (nostr_convert.rs: display_name zuerst, dann
    name), deshalb gilt hier dasselbe - sonst haelt das Skript ein Profil fuer
    namenlos, das in der App einen Namen zeigt.
    """
    for key in ("display_name", "name"):
        value = content.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def effective_name(content_json: str) -> str:
    name = _name_in(json.loads(content_json))
    if not name:
        raise SystemExit("FEHLER: Profil ohne Anzeigename - die Policy braucht einen.")
    return name


def profile_tags(existing: Optional[dict], auth_tag: List[str]) -> List[list]:
    """Tags des alten Profils uebernehmen, aber genau ein auth-Tag setzen.

    Zwei auth-Tags sind schlimmer als keines: NIP-OA verwirft dann beide.
    """
    tags = [tag for tag in (existing or {}).get("tags", []) if not (tag and tag[0] == "auth")]
    tags.append(auth_tag)
    return tags


# ── .env-Zeile ───────────────────────────────────────────────────────────────


def upsert_auth_tags(env_text: str, agent_name: str, signature: str) -> str:
    """Traegt name=signatur in BUZZ_AUTH_TAGS ein; vorhandener Eintrag gewinnt nicht."""
    entry = f"{agent_name}={signature}"
    lines = env_text.splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("BUZZ_AUTH_TAGS="):
            continue
        current = line[len("BUZZ_AUTH_TAGS=") :].strip().strip("\"'")
        kept = [part.strip() for part in current.split(",")
                if part.strip() and not part.strip().startswith(f"{agent_name}=")]
        kept.append(entry)
        lines[index] = "BUZZ_AUTH_TAGS=" + ",".join(kept)
        return "\n".join(lines) + ("\n" if env_text.endswith("\n") else "")
    lines.append("BUZZ_AUTH_TAGS=" + entry)
    return "\n".join(lines) + "\n"


# ── Selbsttest ───────────────────────────────────────────────────────────────


def selftest() -> int:
    failures = 0

    name, key = pick_agent("tuatara=aa11,gecko=bb22", "gecko")
    if (name, key) == ("gecko", "bb22"):
        print("  Agent aus BUZZ_AGENTS gewaehlt: ok", file=sys.stderr)
    else:
        print(f"FEHLER: pick_agent ergab {(name, key)}", file=sys.stderr)
        failures += 1

    owner = "fa" * 32
    meta = {"respond_to": "allowlist", "respond_to_allowlist": owner, "parallelism": "2"}
    respond_to, allowlist, parallelism = policy_from_frontmatter(meta)
    if (respond_to, allowlist, parallelism) == ("allowlist", [owner], 2):
        print("  Policy aus dem Frontmatter: ok", file=sys.stderr)
    else:
        print(f"FEHLER: Frontmatter ergab {(respond_to, allowlist, parallelism)}", file=sys.stderr)
        failures += 1

    # Ein zweites auth-Tag waere fatal - NIP-OA verwirft dann beide.
    existing = {"tags": [["auth", "alt", "", "alt"], ["client", "buzz"]]}
    tags = profile_tags(existing, ["auth", owner, "", "ff" * 64])
    auth_count = sum(1 for tag in tags if tag and tag[0] == "auth")
    if auth_count == 1 and ["client", "buzz"] in tags and tags[-1][1] == owner:
        print("  genau ein auth-Tag, andere Tags bleiben: ok", file=sys.stderr)
    else:
        print(f"FEHLER: Tags ergaben {tags}", file=sys.stderr)
        failures += 1

    # about darf beim Umbenennen nicht verlorengehen.
    merged = json.loads(profile_content({"content": '{"name":"Alt","about":"Text","picture":"u"}'},
                                        "Neu", None))
    if merged == {"name": "Neu", "about": "Text", "picture": "u", "display_name": "Neu"}:
        print("  vorhandenes Profil bleibt erhalten: ok", file=sys.stderr)
    else:
        print(f"FEHLER: Profil ergab {merged}", file=sys.stderr)
        failures += 1

    env = upsert_auth_tags("BUZZ_AGENTS=x\nBUZZ_AUTH_TAGS=gecko=11,tuatara=alt\n", "tuatara", "neu")
    if "tuatara=neu" in env and "gecko=11" in env and "tuatara=alt" not in env:
        print("  BUZZ_AUTH_TAGS ersetzt nur den eigenen Eintrag: ok", file=sys.stderr)
    else:
        print(f"FEHLER: .env ergab {env!r}", file=sys.stderr)
        failures += 1

    if failures:
        print(f"{failures} Pruefung(en) fehlgeschlagen.", file=sys.stderr)
        return 1
    print("Alle Pruefungen bestanden.", file=sys.stderr)
    return 0


# ── Ablauf ───────────────────────────────────────────────────────────────────


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Attestierung, Profil und Owner-Policy fuer einen Agenten in einem Lauf.",
        epilog="Beide privaten Schluessel bleiben auf diesem Rechner; gesendet werden nur signierte Events.",
    )
    parser.add_argument("--agent-name", help="Name aus BUZZ_AGENTS (bei mehreren Agenten noetig)")
    parser.add_argument("--env", default=".env", help="Pfad zur .env (Standard: .env)")
    parser.add_argument("--agents-dir", default="agents", help="Verzeichnis mit <name>.md (Standard: agents)")
    parser.add_argument("--name", help="Anzeigename; ohne Angabe bleibt der vorhandene")
    parser.add_argument("--about", help="Profiltext; ohne Angabe bleibt der vorhandene")
    parser.add_argument("--relay", help="Relay-URL; Standard ist BUZZ_RELAY_URL aus der .env")
    parser.add_argument("--write-env", action="store_true", help="BUZZ_AUTH_TAGS in der .env eintragen")
    parser.add_argument("--dry-run", action="store_true", help="Events zeigen, nichts senden")
    parser.add_argument("--selftest", action="store_true", help="Selbsttest, kein Netz")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()

    env_path = Path(args.env)
    env = read_env(env_path)

    owner_raw = env.get("BUZZ_OWNER_KEY", "")
    if not owner_raw:
        raise SystemExit(
            "FEHLER: BUZZ_OWNER_KEY fehlt in der .env. Das ist dein eigener privater\n"
            "       Schluessel (Buzz Desktop: Settings -> Private key -> Reveal)."
        )
    owner_seckey = int(mint.parse_key("BUZZ_OWNER_KEY", owner_raw, "nsec"), 16)
    owner_pub = mint.pubkey_of(owner_seckey).hex()

    declared = env.get("BUZZ_ACP_AGENT_OWNER", "")
    if declared and declared.lower() != owner_pub:
        raise SystemExit(
            f"FEHLER: BUZZ_OWNER_KEY gehoert zu {owner_pub},\n"
            f"       BUZZ_ACP_AGENT_OWNER nennt aber {declared}.\n"
            "       Die Policy waere nicht zuordenbar - erst klaeren, welcher stimmt."
        )

    agent_name, agent_raw = pick_agent(env.get("BUZZ_AGENTS", ""), args.agent_name)
    agent_seckey = int(mint.parse_key("Agentenschluessel", agent_raw, "nsec"), 16)
    agent_pub = mint.pubkey_of(agent_seckey).hex()
    if agent_pub == owner_pub:
        raise SystemExit("FEHLER: Agent und Owner sind derselbe Schluessel - NIP-OA verwirft das.")

    meta = read_frontmatter(Path(args.agents_dir) / f"{agent_name}.md")
    if not meta:
        print(f"WARNUNG: kein Frontmatter in {args.agents_dir}/{agent_name}.md -", file=sys.stderr)
        print("         die Policy bekommt owner-only und parallelism 1.", file=sys.stderr)
    respond_to, allowlist, parallelism = policy_from_frontmatter(meta)

    base = policy.http_base(args.relay or env.get("BUZZ_RELAY_URL", ""))

    # 1. Attestierung
    signature = mint.schnorr_sign(mint.auth_message(agent_pub), owner_seckey, bytes(32)).hex()
    auth_tag = ["auth", owner_pub, "", signature]

    # 2. Profil: vorhandenes holen, Tag anhaengen, mit dem Agentenschluessel signieren
    # Auch im Trockenlauf geholt: sonst zeigt die Vorschau ein Profil, das
    # nicht das ist, was spaeter veroeffentlicht wuerde.
    existing = fetch_profile(base, agent_seckey, agent_pub)
    profile = policy.build_event(
        agent_seckey, KIND_PROFILE,
        profile_tags(existing, auth_tag),
        profile_content(existing, args.name, args.about),
    )

    # 3. Policy, signiert vom Owner
    coordinate = policy.build_event(
        owner_seckey, policy.KIND_MANAGED_AGENT, [["d", agent_pub]],
        policy.policy_content(effective_name(profile["content"]), respond_to, allowlist, parallelism),
    )

    print(f"Agent:         {agent_name}  ({agent_pub})", file=sys.stderr)
    print(f"Profil bisher: {'gefunden' if existing else 'keines am Relay'}", file=sys.stderr)
    print(f"Owner:         {owner_pub}", file=sys.stderr)
    print(f"Relay:         {base}", file=sys.stderr)
    print(f"Profil:        {profile['content']}", file=sys.stderr)
    print(f"Policy:        {coordinate['content']}", file=sys.stderr)
    print(f"Koordinate:    30177:{owner_pub}:{agent_pub}", file=sys.stderr)

    if args.dry_run:
        print(json.dumps({"profile": profile, "policy": coordinate}, indent=2, ensure_ascii=False))
        print("--dry-run: nichts gesendet.", file=sys.stderr)
        return 0

    # Reihenfolge ist Pflicht: die App nimmt die Koordinate nur an, wenn das
    # Profil den Owner schon attestiert.
    print(policy.post_event(base, agent_seckey, profile), file=sys.stderr)
    print(policy.post_event(base, owner_seckey, coordinate), file=sys.stderr)

    if args.write_env:
        env_path.write_text(upsert_auth_tags(env_path.read_text(encoding="utf-8"), agent_name, signature),
                            encoding="utf-8")
        print(f"{env_path}: BUZZ_AUTH_TAGS aktualisiert.", file=sys.stderr)
    else:
        print("", file=sys.stderr)
        print("Noch in die .env, damit auch spaetere Events das Tag tragen:", file=sys.stderr)
        print(f"  BUZZ_AUTH_TAGS={agent_name}={signature}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
