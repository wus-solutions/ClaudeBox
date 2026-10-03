#!/usr/bin/env python3
"""Erzeugt aus agents/<name>.md je einen supervisord-Prozess.

Aufruf: render-agents.py <name> [<name> ...]

Jede Agentendatei besteht aus Frontmatter und Systemprompt:

    ---
    enabled: true
    model: opus
    respond_to: owner-only
    max_turn_duration: 3600
    ---

    Du bist ...

Jeder Frontmatter-Schluessel wird zu der gleichnamigen Umgebungsvariablen von
buzz-acp: max_turn_duration -> BUZZ_ACP_MAX_TURN_DURATION. Fast jedes Flag von
buzz-acp hat eine solche Variable, deshalb muss hier nichts angepasst werden,
wenn buzz-acp eine neue Option bekommt - der Schluessel wandert einfach ins
Frontmatter.

Geheimnisse stehen nie in den erzeugten Dateien: der private Schluessel wird
als %(ENV_BUZZ_AGENT_KEY_<NAME>)s referenziert und vom Entrypoint exportiert.
"""
import os
import re
import sys
from pathlib import Path

AGENTS_DIR = Path(os.environ.get("AGENTS_DIR", "/opt/agents"))
CONF_DIR = Path(os.environ.get("SUPERVISOR_CONF_DIR", "/etc/supervisor/conf.d"))
PROMPT_DIR = Path(os.environ.get("AGENT_PROMPT_DIR", "/run/agents"))

# Grob gemessen: buzz-acp ~25 MB + claude-agent-acp ~130 MB + claude ~480 MB.
MB_PER_WORKER = 640

# Diese Schluessel steuern den Renderer und werden nicht durchgereicht.
RESERVED = {"enabled", "name", "description"}

warnings: list[str] = []


def warn(msg: str) -> None:
    warnings.append(msg)
    print(f"WARNUNG: {msg}", file=sys.stderr)


def parse(path: Path) -> tuple[dict[str, str], str]:
    """Trennt Frontmatter von Prompt. Bewusst nur key: value, kein YAML."""
    text = path.read_text(encoding="utf-8")
    meta: dict[str, str] = {}
    body = text
    m = re.match(r"\A---\s*\n(.*?)\n---\s*\n?(.*)\Z", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if ":" not in line:
                warn(f"{path.name}: Zeile ohne ':' im Frontmatter ignoriert: {line!r}")
                continue
            k, _, v = line.partition(":")
            meta[k.strip().lower()] = v.strip()
        body = m.group(2)
    else:
        warn(f"{path.name}: kein Frontmatter gefunden - alle Defaults gelten")
    return meta, body.strip()


def env_name(key: str) -> str:
    return "BUZZ_ACP_" + re.sub(r"[^A-Z0-9_]", "_", key.upper())


def key_var(name: str) -> str:
    return "BUZZ_AGENT_KEY_" + re.sub(r"[^A-Z0-9_]", "_", name.upper())


def sig_var(name: str) -> str:
    return "BUZZ_AUTH_SIG_" + re.sub(r"[^A-Z0-9_]", "_", name.upper())


def render(name: str) -> int:
    """Schreibt die Konfiguration eines Agenten. Gibt die Worker-Zahl zurueck."""
    path = AGENTS_DIR / f"{name}.md"
    if not path.is_file():
        warn(f"Agent '{name}': keine Datei {path} - laeuft ohne Systemprompt")
        meta, body = {}, ""
    else:
        meta, body = parse(path)

    if meta.get("enabled", "true").lower() in {"false", "0", "no"}:
        print(f"  {name}: uebersprungen (enabled: false)", file=sys.stderr)
        return 0

    env = [
        'HOME="/home/dev"',
        f'BUZZ_PRIVATE_KEY="%(ENV_{key_var(name)})s"',
        'BUZZ_RELAY_URL="%(ENV_BUZZ_RELAY_URL)s"',
        'BUZZ_ACP_AGENT_OWNER="%(ENV_BUZZ_ACP_AGENT_OWNER)s"',
        # Nur der NAME der Variablen, nicht ihr Wert. Zwei Gruende:
        # supervisord trennt diese Liste an Kommas (das Tag ist JSON, hat also
        # welche), und eine fehlende %(ENV_...)s-Referenz laesst supervisord das
        # Programm gar nicht starten. Den Wert holt buzz-acp-launch selbst.
        f'BUZZ_AUTH_SIG_VAR="{sig_var(name)}"',
        'GITHUB_TOKENS="%(ENV_GITHUB_TOKENS)s"',
        'GITHUB_TOKEN="%(ENV_GITHUB_TOKEN)s"',
    ]

    if body:
        PROMPT_DIR.mkdir(parents=True, exist_ok=True)
        prompt_file = PROMPT_DIR / f"{name}.prompt"
        prompt_file.write_text(body + "\n", encoding="utf-8")
        env.append(f'BUZZ_ACP_SYSTEM_PROMPT_FILE="{prompt_file}"')
    else:
        warn(f"Agent '{name}': leerer Systemprompt")

    for k, v in sorted(meta.items()):
        if k in RESERVED or v == "":
            continue
        env.append(f'{env_name(k)}="{v}"')

    workers = 1
    if meta.get("parallelism"):
        try:
            workers = max(1, int(meta["parallelism"]))
        except ValueError:
            warn(f"Agent '{name}': parallelism ist keine Zahl: {meta['parallelism']!r}")

    CONF_DIR.mkdir(parents=True, exist_ok=True)
    (CONF_DIR / f"agent-{name}.conf").write_text(
        f"""; Erzeugt von render-agents.py aus {path.name}. Nicht von Hand aendern.
[program:buzz-acp-{name}]
command=/usr/local/bin/buzz-acp-launch --agent-command claude-agent-acp --agent-args ""
user=dev
directory=/workspace
environment={",\n    ".join(env)}
autostart=true
autorestart=true
startsecs=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
""",
        encoding="utf-8",
    )
    detail = ", ".join(f"{k}={v}" for k, v in sorted(meta.items()) if k not in RESERVED and v)
    print(f"  {name}: aktiv ({detail or 'nur Defaults'})", file=sys.stderr)
    return workers


def available_mb() -> int | None:
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) // 1024
    except OSError:
        pass
    return None


def main(names: list[str]) -> int:
    for stale in CONF_DIR.glob("agent-*.conf"):
        stale.unlink()

    if not names:
        print("Keine Agenten konfiguriert (BUZZ_AGENTS ist leer).", file=sys.stderr)
        return 0

    print(f"Agenten aus {AGENTS_DIR}:", file=sys.stderr)
    total = sum(render(n) for n in names)

    if total:
        need = total * MB_PER_WORKER
        have = available_mb()
        msg = f"{total} Worker, geschaetzt {need} MB"
        if have:
            msg += f" von {have} MB im Container verfuegbar"
            if need > have * 0.8:
                warn(
                    f"Der Speicher wird knapp: {msg}. Der OOM-Killer trifft "
                    "sonst mitten in einem Turn. parallelism senken oder "
                    "Agenten mit 'enabled: false' parken."
                )
        print(f"Summe: {msg}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
