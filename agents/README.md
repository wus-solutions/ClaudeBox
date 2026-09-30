# Agenten

Eine Datei je Agent: `agents/<name>.md`. Der Name verweist auf den Eintrag in
`BUZZ_AGENTS`:

```
BUZZ_AGENTS=tuatara=<privkey>,gecko=<privkey>
```

`AGENT_NAME.md` ist die **Vorlage**, kein laufender Agent. Kopiere sie nach
`agents/<name>.md`, ersetze die Platzhalter `{{AGENT_NAME}}` und
`{{BUZZ_RELAY_IDENTIFIER}}` und trag den Namen in `BUZZ_AGENTS` ein. Der
Renderer liest ausschliesslich die Namen aus dieser Variablen — eine Datei, die
dort nicht steht, wird nie zu einem Prozess. Die Vorlage selbst bleibt deshalb
folgenlos liegen.

Die Trennung ist Absicht: **Konfiguration im Repo, versioniert und reviewbar —
Schlüssel in der Umgebung, nie im Repo.** Ein weiterer Agent ist eine Datei
plus ein Eintrag. Kein Eingriff in `docker-compose.yml`, keiner in
`supervisord.conf`.

## Aufbau einer Agentendatei

```markdown
---
enabled: true
model: opus
respond_to: owner-only
parallelism: 1
max_turn_duration: 3600
---

Du bist ...
```

Frontmatter oben, Systemprompt darunter. Der Prompt wird ohne das Frontmatter
an `buzz-acp` übergeben.

## Wie die Schlüssel wirken

**Jeder Frontmatter-Schlüssel wird zur gleichnamigen `BUZZ_ACP_*`-Variablen:**
`max_turn_duration` → `BUZZ_ACP_MAX_TURN_DURATION`, `model` → `BUZZ_ACP_MODEL`.

Fast jedes Flag von `buzz-acp` hat eine solche Variable. Deshalb ist hier
nichts anzupassen, wenn `buzz-acp` eine neue Option bekommt — der Schlüssel
wandert einfach ins Frontmatter. Die vollständige Liste zeigt:

```bash
docker compose exec claude buzz-acp --help
```

Nur `enabled` wird vom Renderer selbst ausgewertet und nicht durchgereicht.

Häufig gebraucht:

| Schlüssel | Wirkung |
|---|---|
| `enabled` | `false` parkt den Agenten, ohne die Datei zu entfernen |
| `respond_to` | `owner-only` (Default), `allowlist`, `anyone`, `nobody` |
| `respond_to_allowlist` | 64-stellige Hex-Pubkeys, kommagetrennt. Der eigene ist immer implizit dabei |
| `model` | Modell-ID; leer = Default des Adapters |
| `permission_mode` | Default ist `bypass-permissions`. `plan` oder `accept-edits` zügeln den Agenten |
| `parallelism` | gleichzeitige Turns — **jeder kostet ~640 MB** |
| `max_turn_duration` | Sekunden je Turn. Die wichtigste Kostenbremse |
| `idle_timeout` | Sekunden Stille, bevor ein Turn abgebrochen wird |

## Speicher

Ein Worker braucht rund **640 MB** (`claude` ~480, `claude-agent-acp` ~130,
`buzz-acp` ~25). `parallelism: 10` bedeutet also 6,4 GB für **einen** Agenten —
deshalb ist der Default `1`.

Der Entrypoint rechnet die aktivierten Agenten beim Start zusammen und warnt,
bevor der OOM-Killer mitten in einem Turn zuschlägt. Die Schätzung steht in
den Logs:

```bash
docker compose logs claude | grep Summe:
```

## Eine neue Identität anlegen

Am Relay:

```bash
buzz-admin generate-key
buzz-admin add-member --pubkey <agent public key>
```

Secret nach `BUZZ_AGENTS`, `agents/<name>.md` schreiben, `docker compose up -d`.
Danach das Profil setzen, sonst zeigt Buzz einen aus dem Pubkey abgeleiteten
Namen:

```bash
docker compose exec claude buzz users set-profile --name "<Name>" --about "…"
```

Alle Agenten teilen sich `/workspace`, den Claude-Login und die
GitHub-Zugangsdaten. Unterschiedlich sind nur Identität und Auftrag.
