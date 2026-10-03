# Host-Werkzeuge

*English version: [README.md](README.md)*

Zwei Skripte, die auf dem **Host** laufen, nie im Container: beide brauchen den
privaten Schlüssel des Owners, und der gehört nicht in ein Image und nicht in
eine Container-Umgebung. Reines Python ab 3.9 (das System-Python von macOS
reicht), keine Abhängigkeiten, kein Docker, kein Netz — außer beim
Veröffentlichen.

| Skript | Wofür |
|---|---|
| **`enroll-agent.py`** | **der übliche Weg:** Attestierung, Profil und Policy in einem Lauf |
| `mint-auth-tag.py` | nur die Attestierung signieren → `BUZZ_AUTH_TAGS` |
| `publish-agent-policy.py` | nur die Owner-Policy `kind:30177` veröffentlichen |

Die unteren beiden sind die Bausteine und bleiben einzeln nützlich — etwa zum
Umbenennen, ohne das Profil anzufassen. `enroll-agent.py` lädt sie als Module;
alle drei Dateien müssen nebeneinander liegen, damit Krypto, Schlüsselparsen
und Relay-Zugriff genau einmal existieren, jeweils mit eigenem Selbsttest.

---

## Warum es zwei Belege sind

Das war die Stelle, an der dieses Setup lange hing. „Agent" ist in Buzz kein
Kontotyp, sondern eine Belegkette aus mehreren Events. Für die Desktop-App
zählen zwei davon:

**1. `kind:0` mit NIP-OA-`auth`-Tag** — signiert vom Owner, veröffentlicht vom
Agenten. Das ist die *Markierung*: ab hier gilt die Identität als Agent.
Im Buzz-Quelltext ist das wörtlich eine Zeile
(`desktop/src-tauri/src/nostr_convert/user_search.rs`):

```rust
is_agent: owner_pubkey.is_some(),   // owner_pubkey == gültiges auth-Tag im kind:0
```

**2. `kind:30177`, signiert vom Owner, `d`-Tag = Agent-Pubkey** — die
*Zulassung*. Das Agentenverzeichnis der Desktop-App wird aus owner-signierten
30177-Koordinaten und relay-signierten `kind:39002`-Mitgliederlisten gebaut
(`desktop/src-tauri/src/commands/agent_discovery/relay_directory.rs`).

Nur Schritt 1 ist die schlechteste aller Zustände: die Identität ist als Agent
markiert, steht aber in keinem Verzeichnis — und **jeder** Picker der
Desktop-App filtert markierte Agents, die nicht zugelassen sind. Weder als
Agent noch als gewöhnlicher Teilnehmer auswählbar:

- Mitglied hinzufügen → `desktop/src/features/channels/ui/MembersSidebar.tsx`
- `@`-Mention → `desktop/src/features/messages/lib/buildMentionCandidates.ts`
- Neue Nachricht / DM → `desktop/src/features/messages/ui/useNewMessageRecipients.ts`

Steht die 30177 da, greift im Verzeichnis `retain` auf *owner == ich* — der
Agent wird gefunden, **auch ohne** Channel-Mitgliedschaft, und die App bietet
den Invite-Dialog an, der ihn selbst als Bot-Member einträgt.

**Warum ein eigenes Skript.** Für die 30177 gibt es kein `buzz`-Kommando.
`buzz agents draft-create` schickt nur einen Entwurf an das Desktop-Formular
und legt dort einen *neuen* Schlüssel an; einen bestehenden Container-Key
adoptiert die App nicht. Sonst schreibt diese Koordinate ausschließlich Buzz
Desktop beim Anlegen eines eigenen managed Agents.

---

## Ablauf für einen neuen Agenten

Vorausgesetzt: Identität erzeugt, am Relay als Member eingetragen, Eintrag in
`BUZZ_AGENTS`, `agents/<name>.md` vorhanden, Container läuft (siehe
[README.de.md](../README.de.md), Abschnitte 2–5). Der eigene private Schlüssel
steht als `BUZZ_OWNER_KEY` in der `.env` — er wird nie in den Container
gereicht.

### 1. Einrichten — ein Aufruf

```bash
tools/enroll-agent.py --agent-name <name> --dry-run    # erst ansehen
tools/enroll-agent.py --agent-name <name> --write-env  # dann senden
```

Das Skript holt sich alles selbst: Owner-Schlüssel aus `BUZZ_OWNER_KEY`,
Agentenschlüssel aus `BUZZ_AGENTS`, Relay aus `BUZZ_RELAY_URL` sowie
`respond_to`, `respond_to_allowlist` und `parallelism` aus dem Frontmatter von
`agents/<name>.md`. Dann signiert es die Attestierung, holt das vorhandene
`kind:0` vom Relay, hängt das `auth`-Tag an, veröffentlicht es mit dem
Schlüssel des **Agenten** — und die Policy mit deinem.

Die Reihenfolge ist nicht kosmetisch: die Desktop-App nimmt die Koordinate nur
an, wenn das Profil den Owner schon attestiert.

Drei Fehler, die von Hand regelmäßig passierten, kann es so nicht mehr geben:

- **`about` und Bild bleiben erhalten.** `buzz users set-profile --name X` ohne
  `--about` leert das Feld.
- **Genau ein `auth`-Tag.** Zwei sind schlimmer als keines, NIP-OA verwirft
  dann beide.
- **`respond_to` kann nicht auseinanderlaufen**, weil Policy und Frontmatter
  aus derselben Quelle stammen.

`--write-env` trägt `BUZZ_AUTH_TAGS=<name>=<signatur>` gleich in die `.env`
ein und ersetzt dabei nur den Eintrag dieses Agenten; ohne die Option wird die
Zeile nur ausgegeben. Gebraucht wird sie, damit auch alle **späteren** Events
des laufenden Agenten das Tag tragen — dafür danach einmal
`docker compose up -d`.

Den Container braucht keiner dieser Schritte mehr. Früher lief der Profilteil
als `buzz users set-profile` darin, mit einem Redeploy davor, damit
`BUZZ_AUTH_TAG` in der Umgebung steht.

### 2. Nur die Policy erneuern — Umbenennen

`kind:30177` ist nach NIP-33 ersetzbar: dieselbe Koordinate noch einmal
veröffentlichen überschreibt die vorherige Fassung, ohne das Profil
anzufassen. `--respond-to` und `--allow` müssen dabei zum Frontmatter in
`agents/<name>.md` passen:

```bash
grep -E '^BUZZ_OWNER_KEY=' .env | cut -d= -f2- | \
tools/publish-agent-policy.py --owner-stdin \
  --agent <agent-pubkey> \
  --name "<Name>" \
  --respond-to allowlist --allow <owner-pubkey> \
  --relay "$BUZZ_RELAY_URL" \
  --dry-run
```

`--owner-stdin` statt `--owner <key>`: Argumente stehen während des Laufs in
der Prozessliste und landen leicht in der Shell-History. An einem Terminal
fragt das Skript verdeckt nach, in einer Pipe liest es die erste Zeile.
`mint-auth-tag.py` nimmt den Schlüssel bislang nur als Argument — dort gilt
derselbe Vorbehalt.

Ohne `--dry-run` wird das Event signiert und per `POST /events` mit
NIP-98-Header an das Relay geschickt. `--relay` nimmt `https://` oder `wss://`
und darf auch aus `BUZZ_RELAY_URL` kommen. `--selftest` prüft Signieren,
Event-ID und Header-Form ohne Netz — gegen das signierte Beispiel-Event aus
`docs/nips/NIP-OA.md` des Buzz-Repos, also gegen eine Quelle, die nicht dieses
Skript selbst ist.

### 3. Beides zusammen prüfen

Ein Kommando prüft Policy **und** Attestierung. Es läuft im Container, weil
`--owner me` dort über `BUZZ_AUTH_TAG` auf den Owner auflöst — ein `buzz` auf
dem Host ist nicht nötig:

```bash
docker compose exec claude buzz users get --name "<Name>" --owner me
```

Gesucht wird in den kind:30177-Events des Owners, der Name kommt aus deren
Inhalt. **Leeres Ergebnis heißt: die Policy aus Schritt 3 fehlt oder trägt
einen anderen Namen** — vorher ist dieser Befehl kein sinnvoller Test. Ist die
Policy da, sagt das Feld `verification`, wie es um das `kind:0` steht:

| Wert | Bedeutung |
|---|---|
| `verified` | passt — zusätzlich sollte `owned_by_me: true` dastehen |
| `missing_auth` | kein `auth`-Tag im `kind:0` → Schritt 2 wiederholen |
| `missing_profile` | gar kein `kind:0` zu diesem Schlüssel → Schritt 2 |
| `owner_mismatch` | mit dem falschen Schlüssel signiert (Agent statt Owner?) |
| `condition_mismatch` | Conditions im Tag passen nicht auf ein `kind:0` → leere Conditions verwenden, so wie `mint-auth-tag.py` sie erzeugt |
| `multiple_auth_tags` | zwei `auth`-Tags im Profil — eines ist immer falsch, Buzz verwirft beide |

### 4. In die Kanäle holen

Nach einem Neuladen der Desktop-App ist der Agent im Mitglieder-Picker und
unter den Agents wieder da; der Invite-Dialog trägt ihn selbst als Bot ein.
Alternativ mit dem Owner-Schlüssel per CLI:

```bash
buzz channels add-member --channel <uuid> --pubkey <agent-pubkey> --role bot
```

Die Rolle `bot` ist keine Kosmetik: das Verzeichnis prüft im `p`-Tag der
relay-signierten Mitgliederliste die vierte Stelle auf `bot`
(`desktop/src-tauri/src/nostr_convert/agent_directory.rs`). Der grüne Punkt
kommt danach von `buzz-acp` selbst (`kind:20001` Presence), dafür ist nichts
weiter zu tun.

---

## Fallstricke

**`respond_to` steht an zwei Stellen und muss übereinstimmen.** Das Frontmatter
in `agents/<name>.md` entscheidet, wem der Agent *antwortet* (es wird zu
`BUZZ_ACP_RESPOND_TO`). Die 30177 entscheidet, wer ihn *auswählen* kann.
Weichen sie ab, zeigt die UI ihn an und er bleibt stumm — oder umgekehrt.
`enroll-agent.py` liest beides aus dem Frontmatter und kann deshalb nicht
auseinanderlaufen; wer `publish-agent-policy.py` einzeln benutzt, muss selbst
daran denken.

**`nobody` lässt sich nicht abbilden.** Die Policy kennt nur `owner-only`,
`allowlist` und `anyone`. Ein Agent mit `respond_to: nobody` im Frontmatter
(Heartbeat-Betrieb) bekommt keine sinnvolle Policy; dann lieber `owner-only`
veröffentlichen oder die Policy weglassen.

**Pflichtfelder sind Pflicht.** `name`, `parallelism` und `respond_to` müssen
im Inhalt stehen; fehlt eines, verwirft die Desktop-App die Koordinate
**stillschweigend** und der Agent ist wieder unsichtbar. Das Skript schreibt
immer alle drei.

**Eine ungültige neueste Policy ist schlimmer als keine.** Die Koordinate
bleibt belegt und kann nicht auf einen älteren Zustand zurückfallen. Deshalb
`--dry-run` zuerst.

**Das Event ist weltlesbar.** Im Inhalt steht nur der Anzeigename, die
Parallelität und die Antwort-Policy — keine Prompts, keine Schlüssel, keine
Tokens. Dabei soll es bleiben.

**Erneutes Ausführen ist der Weg zur Änderung.** `kind:30177` ist ein
parametrisiert ersetzbares Event (NIP-33): dieselbe Koordinate
`(owner, 30177, agent)` noch einmal veröffentlichen überschreibt die vorherige
Version. Umbenennen heißt also: Skript mit neuem `--name` erneut laufen lassen.

**Der Owner-Schlüssel bleibt auf dem Host.** Beide Skripte laufen bewusst
außerhalb des Containers. Ein `nsec` im Repo blockiert ohnehin der
pre-commit-Hook — zu Recht.

---

## Quellen

Die Abschnitte oben verweisen auf Dateien im Buzz-Repository
(`github.com/block/buzz`). Die Spezifikationen dazu:

- `docs/nips/NIP-OA.md` — Owner Attestation, das `auth`-Tag
- `docs/nips/NIP-AP.md` — Agent Personas, `kind:30175`/`30177`
- `docs/owned-agent-discovery.md` — wie das Verzeichnis Ownership prüft
- `docs/agent-management-provenance.md` — warum extern betriebene Agents als
  „nicht auf diesem Gerät verwaltet" markiert werden
