<div align="center">

# claude-box

**Claude Code in einem abgeschotteten Container — erreichbar ausschließlich über Tailscale, angebunden an ein Buzz-Relay als Agent.**

[![Tests](https://github.com/wus-solutions/ClaudeBox/actions/workflows/tests.yml/badge.svg)](https://github.com/wus-solutions/ClaudeBox/actions/workflows/tests.yml)
![Docker Compose v2](https://img.shields.io/badge/Docker-Compose%20v2-2496ED?logo=docker&logoColor=white)
![Netzwerk: nur Tailscale](https://img.shields.io/badge/Netzwerk-nur%20Tailscale-1F1F1F?logo=tailscale&logoColor=white)
![Veröffentlichte Ports: keine](https://img.shields.io/badge/ver%C3%B6ffentlichte%20Ports-keine-3FB950)
[![Lizenz: MIT](https://img.shields.io/badge/Lizenz-MIT-blue)](LICENSE)

[**Interaktives Architekturdiagramm**](https://wus-solutions.github.io/ClaudeBox/architecture.de.html) · [English version](README.md)

</div>

---

Vom öffentlichen Internet aus existiert dieser Dienst nicht. Kein
veröffentlichter Port, keine Domain, kein Reverse-Proxy-Eintrag. Zwei Dinge
erreichen den Container: ein Gerät in deinem Tailnet und eine WebSocket-Verbindung,
die der Container selbst nach außen aufgebaut hat.

Das ist der ganze Gedanke. Ein Agent, der ohne Rückfrage schreibt, hat nichts
hinter einem Passwort auf einer öffentlichen Adresse zu suchen.

## Inhalt

- [Aufbau](#aufbau)
- [Voraussetzungen](#voraussetzungen)
- [Einrichtung](#einrichtung)
- [Zugriff](#zugriff)
- [Sicherheit](#sicherheit)
- [Deployment auf Coolify](#deployment-auf-coolify)
- [Tests](#tests)
- [Betrieb](#betrieb)
- [Fallstricke](#fallstricke)
- [Lizenz](#lizenz)

## Aufbau

Zwei Services in einem Compose-Stack:

```
┌─ tailscale ───────────────────────────────────────────┐
│  ghcr.io/tailscale/tailscale                          │
│  besitzt den Netzwerk-Namespace, terminiert HTTPS     │
└───────────────────────────────────────────────────────┘
          ▲ network_mode: "service:tailscale"
┌─ claude ──────────────────────────────────────────────┐
│  ttyd -i lo :7681 → tmux → claude                     │
│  buzz-acp ──WSS ausgehend──→ Relay                    │
│      └─ stdio ─→ claude-agent-acp                     │
└───────────────────────────────────────────────────────┘
```

> **[Interaktives Diagramm öffnen →](https://wus-solutions.github.io/ClaudeBox/architecture.de.html)**
> Mit Schwenken, geführten Ansichten, Hell/Dunkel sowie SVG- und PNG-Export. Es
> ist eine einzelne, in sich geschlossene HTML-Datei in [`docs/`](docs/) — lokal
> zu öffnen, falls GitHub Pages für dieses Repository nicht aktiviert ist.

Der `claude`-Container hat **keinen eigenen Netzwerk-Stack**. Er kann deshalb
strukturell nichts am Tailnet vorbei exponieren — die Isolation hängt an der
Topologie, nicht an korrekt gesetzten Flags. `ttyd` bindet zusätzlich nur an
`lo`, als zweite Verteidigungslinie.

`buzz-acp` baut die Verbindung zum Relay **ausgehend** auf und braucht deshalb
keinen eingehenden Port.


## Voraussetzungen

- Docker mit Compose v2
- Ein Tailnet mit aktivierten **HTTPS-Zertifikaten**
  (Admin-Konsole → DNS → HTTPS Certificates → Enable). Ohne das kann der Node
  kein TLS-Zertifikat ausstellen und `tailscale serve` verweigert die
  Konfiguration.
- Ein erreichbares Buzz-Relay
- Ein Claude-Abo (Pro/Max)

## Einrichtung

### 1. Tailscale-Tag und Auth-Key

In der ACL (`https://login.tailscale.com/admin/acls/file`):

```json
{ "tagOwners": { "tag:claude-box": ["autogroup:admin"] } }
```

Dann unter *Settings → Keys* einen Auth-Key erzeugen:

| Option | Wert |
|---|---|
| Reusable | **aus** — einmal benutzt, ist er verbrannt |
| Ephemeral | **aus** — ephemere Nodes verschwinden beim Offline-Gehen und entwerten den State im Volume |
| Pre-approved | **an** |
| Tags | `tag:claude-box` |

Der Tag hält den Node außerdem von der 180-Tage-Key-Expiry frei.

Der Key wird nur bei der ersten Anmeldung gebraucht: `TS_AUTH_ONCE=true` im
Compose-File sorgt dafür, dass `containerboot` ihn nicht bei jedem Start erneut
vorlegt. Die Identität liegt danach im Volume `tailscale-state`. Einen neuen Key
brauchst du erst, wenn dieses Volume verloren geht oder der Node in der
Admin-Konsole gelöscht wird.

**Nach der ersten Anmeldung `TS_AUTHKEY` leeren** — in Coolify die Variable
entfernen. Coolify reicht jede Variable per `env_file` auch in den
`claude`-Container, und dort arbeitet der Agent ohne Rückfrage. Die
Compose-Datei verlangt den Key deshalb nicht.

### 2. Buzz-Identität

Am Relay:

```bash
buzz-admin generate-key
buzz-admin add-member --pubkey <agent public key>
```

Das Secret kommt nach `BUZZ_PRIVATE_KEY`, der eigene Pubkey nach
`BUZZ_ACP_AGENT_OWNER` — letzterer ist das `owner-only`-Gate.

### 3. Konfiguration

```bash
cp .env.example .env
```

Werte eintragen, dann starten:

```bash
docker compose up -d
```

### 4. Anmeldung

Einmalig im Web-Terminal (siehe *Zugriff*):

```bash
claude
```

Dem OAuth-Ablauf folgen. Die Credentials landen in
`/home/dev/.claude/.credentials.json` im Volume `claude-home` und überleben
Redeploys. Dasselbe gilt für die globale Config `.claude.json` (Konto,
Onboarding-Status): `CLAUDE_CONFIG_DIR=/home/dev/.claude` legt sie ins Volume
statt nach `~/.claude.json`. Sie versorgen **beide** Konsumenten — das Terminal
und den Buzz-Agenten. Ein `ANTHROPIC_API_KEY` wird nicht gebraucht; `buzz-acp`
meldet im Log `apiType=native`.

### 5. Agent-Profil

Ohne Profil zeigt Buzz einen aus dem Pubkey abgeleiteten Namen:

```bash
docker compose exec claude buzz users set-profile \
  --name "Tuatara" --about "…"
```

Das ist ein Einmal-Schritt pro Identität und liegt bewusst nicht im Image.

### 6. GitHub-Zugriff (optional)

Der Agent klont und pusht über HTTPS mit einem **Fine-grained Token**, nicht
über SSH. Ein Token deckt mehrere Repositories ab und lässt sich nachträglich
erweitern; Deploy Keys gelten je Repo und sind nicht erweiterbar.

Token erstellen unter *Settings → Developer settings → Personal access tokens →
Fine-grained*, dann in die Umgebung:

```
GITHUB_TOKEN=github_pat_...
GIT_USER_NAME=Tuatara
GIT_USER_EMAIL=...
```

Der Token wird **nie auf die Platte geschrieben**. Ein Credential-Helper
(`git-credential-github-token`) liefert ihn aus der Prozessumgebung; weder
`.gitconfig` noch `.git-credentials` enthalten ihn. Der Test belegt das.

Fehlt die Variable, schweigt der Helper und der Container startet normal.

#### Repos unter mehreren Ownern

Ein Fine-grained Token gilt immer nur für **einen** Resource Owner — privat
*oder* Organisation, nie beides. Wer an Repos unter mehreren Ownern arbeitet,
braucht mehrere Tokens und ordnet sie in **einer** Variablen zu:

```
GITHUB_TOKENS=alice=github_pat_xxx,BeispielOrg=github_pat_yyy
GITHUB_TOKEN=                 # optionaler Fallback für alles Übrige
```

Der Owner ist der erste Pfadteil der Repo-URL; Groß- und Kleinschreibung
spielt keine Rolle.

Eine einzelne Variable statt `GITHUB_TOKEN_<OWNER>`, weil Compose und die
Coolify-UI jede Variable **namentlich** durchreichen müssen — ein weiterer
Owner wäre sonst eine Änderung am Compose-File statt an der Konfiguration.

Damit die Zuordnung greift, ist `credential.useHttpPath` gesetzt: Git reicht
dem Helper dann den Pfad mit durch, nicht nur den Host. Ohne das sähe er bei
jeder Anfrage nur `github.com`.

### 7. Agenten

Welche Agenten laufen, steht in [`agents/`](agents/) — eine Markdown-Datei je
Agent, mit Frontmatter für die Konfiguration und dem Systemprompt darunter. Die
privaten Schlüssel stehen getrennt davon in der Umgebung:

```
BUZZ_AGENTS=tuatara=<privkey>,gecko=<privkey>
```

[`agents/AGENT_NAME.md`](agents/AGENT_NAME.md) ist die **Vorlage**, kein
laufender Agent. Kopiere sie nach `agents/<name>.md`, ersetze die Platzhalter
`{{AGENT_NAME}}` und `{{BUZZ_RELAY_IDENTIFIER}}` und trag den Namen in
`BUZZ_AGENTS` ein. Der Renderer liest ausschließlich die Namen aus dieser
Variablen — eine Datei, die dort nicht steht, wird nie zu einem Prozess. Die
Vorlage bleibt deshalb folgenlos liegen.

Ein weiterer Agent ist damit eine Datei plus ein Eintrag — keine Änderung an
`docker-compose.yml` oder `supervisord.conf`. Jeder Frontmatter-Schlüssel wird
zur gleichnamigen `BUZZ_ACP_*`-Variablen, sodass auch künftige Optionen von
`buzz-acp` ohne Codeänderung nutzbar sind.

**Ein Worker kostet rund 640 MB.** `parallelism` multipliziert das. Der
Entrypoint rechnet beim Start zusammen und warnt, bevor der Speicher knapp
wird.

Details in [`agents/README.md`](agents/README.md).

### 8. Skills

Drei Wege, und sie schließen sich nicht aus:

| Weg | Wo | Wann |
|---|---|---|
| Projekt-Skill | `.claude/skills/` im geklonten Repo | repo-spezifisch, kommt automatisch mit |
| Container-Skill | `skills/` in diesem Repo | gilt für alle Agenten, versioniert |
| Laufzeit-Skill | `~/.claude/skills/` im Web-Terminal | zum Ausprobieren |

Der Entrypoint spiegelt `skills/` beim Start ins Volume. Er **kopiert nur
hinein und löscht nichts** — ein zur Laufzeit angelegter Skill bleibt also
erhalten; bei Namensgleichheit gewinnt das Repo.

Nur im Volume zu arbeiten reicht nicht: Ein Redeploy mit frischem Volume nimmt
solche Skills **still** mit. Der Agent meldet nichts, er verhält sich ab dann
anders. Zum Erproben gern im Volume, alles Bleibende ins Repo.

Details in [`skills/README.md`](skills/README.md).

**Plugins** stehen in `plugins.txt`, eine Zeile je Plugin mit der Quelle seines
Marketplace:

```
superpowers@claude-plugins-official  anthropics/claude-plugins-official
```

Der Entrypoint installiert sie bei jedem Start als `dev` ins Volume, und zwar
im Hintergrund — Terminal und Agent warten nicht auf das Netz. Ein schon
installiertes Plugin wird nur bestätigt; nur der allererste Start braucht ein
paar Sekunden, bis es da ist. Superpowers gehört bewusst hierher und
nicht nach `skills/`: Es bringt einen SessionStart-Hook mit, und seine Skills
rufen einander als `superpowers:<skill>` auf — beides fehlt, wenn nur die
Skill-Dateien kopiert werden. Updates zieht Claude Code aus dem Marketplace.

Schlägt eine Installation fehl, etwa ohne Netz, meldet der Start eine
`WARNUNG: Plugin …` und läuft weiter. Eine gestrichene Zeile deinstalliert
nichts: dafür `claude plugin uninstall <plugin>@<marketplace>` im Terminal.

### 9. SSH für die IDE (optional)

Damit eine IDE `/workspace` bearbeiten kann, läuft ein `sshd` im Container —
gebunden an `127.0.0.1`, ins Tailnet gereicht über den TCP-Forwarder in
`docker/serve.json`. **Es wird dabei kein Port auf dem Host geöffnet**; die
Zusicherung ist dieselbe wie beim Web-Terminal, nur ein zweiter Dienst hinter
derselben Grenze.

```
SSH_AUTHORIZED_KEYS=ssh-ed25519 AAAA...;ssh-ed25519 AAAA...
```

Mehrere Keys durch `;` trennen. Ist die Variable leer, bleibt `sshd` aus und
nur das Web-Terminal läuft — eine vergessene Variable kostet nicht den
gesamten Zugang.

```bash
ssh dev@<TS_HOSTNAME>.<tailnet>.ts.net
```

In **VS Code**: *Remote-SSH: Connect to Host* mit derselben Adresse.

In **Zed**: `ctrl-cmd-shift-o` → *Connect New Server*, oder direkt in
`~/.config/zed/settings.json`:

```json
{
  "ssh_connections": [
    {
      "host": "claude-box-dev.<tailnet>.ts.net",
      "username": "dev",
      "args": ["-i", "~/.ssh/claude-box"],
      "nickname": "claude-box",
      "projects": [{ "paths": ["/workspace"] }]
    }
  ]
}
```

In **Antigravity**: *Remote Explorer* → `claude-box-dev`.

Der Öffnen-Dialog startet im Home. Dort liegen nur versteckte Verzeichnisse,
der Container wirkt also leer — deshalb legt der Entrypoint `~/workspace` als
Symlink auf `/workspace` an.

Alle drei installieren eine Serverkomponente im Container
(`~/.vscode-server`, `~/.zed_server`, `~/.antigravity-ide-server`). Dafür gibt
es je ein Volume, sonst lädt sie nach jedem Redeploy neu.

**`wget` muss im Image bleiben.** Antigravitys Installer lädt seinen Server
ausschließlich damit und bricht sonst mit `Error need wget to download server
binary` ab — eine Meldung, die nach einem Netzwerkproblem aussieht, aber keins
ist.

Nur Schlüssel-Authentifizierung, kein Passwort, kein Root, nur der Benutzer
`dev`. Die Host-Schlüssel liegen im Volume `ssh-hostkeys` — ohne das erzeugte
jedes Redeploy neue, und der Client warnte jedes Mal vor einem gewechselten
Host-Key. Eine solche Warnung nutzt sich ab, bis man eine echte ignoriert.

### 10. Pakete und cron

Welche apt-Pakete zusätzlich im Container liegen, steht in `packages.txt` —
eine Zeile je Paket, Kommentare und Leerzeilen erlaubt. Drin sind derzeit:

| Gruppe | Pakete |
|---|---|
| Dienste | `cron`, `tzdata` |
| Werkzeuge | `jq`, `unzip`, `rsync`, `git-lfs`, `sqlite3` |
| Netzwerk-Diagnose | `iputils-ping`, `dnsutils` (`dig`), `netcat-openbsd` (`nc`) |
| Toolchains | `php-cli`, `composer`, `python3-pip`, `python3-venv`, `imagemagick`, `ffmpeg` |

`ffmpeg` ist das größte davon und macht den Löwenanteil der Imagegröße aus.
Wer es nicht braucht, streicht die Zeile.

`gh` und `uv` gehen **nicht** über diese Liste: Das eine braucht eine eigene
apt-Quelle, das andere ein Installer-Skript. Beides wäre eine Zeile im
Dockerfile.

Das Dockerfile installiert sie in seiner **letzten** Schicht. Eine Änderung an
der Liste baut deshalb nur diesen Schritt neu, nicht `npm install` darüber. Was
der Container selbst braucht (`tmux`, `supervisor`, `openssh-server`, `git`,
`ripgrep`, `wget`), steht weiter im Dockerfile — das ist keine Auswahl, sondern
Voraussetzung.

`test/image.sh` prüft jede Zeile der Liste am fertigen Image: Steht ein Paket
drin, muss sein Programm da sein.

**`cron` ist ein Sonderfall.** Steht es in der Liste, startet der Entrypoint
zusätzlich den Dienst — ein Crontab ohne laufenden `cron` feuert nie, und das
fällt lange nicht auf. Crontabs legt man als `dev` an:

```bash
crontab -e
crontab -l
```

Sie liegen im Volume `cron-spool` und überleben Redeploys. Ohne dieses Volume
wären sie nach jedem Deployment still weg. Die Ausgabe eines Jobs landet im
Container-Log, weil `cron` im Vordergrund läuft.

**Die Zeitzone gehört dazu.** `TZ` steht in `docker-compose.yml` auf
`Europe/Berlin` und ist über die Umgebung überschreibbar. Ohne `tzdata` **und**
ohne `TZ` liefe der Container in UTC — ein Crontab auf 8 Uhr feuerte im Sommer
um 10. `test/compose.sh` prüft, dass `TZ` gesetzt ist, `test/image.sh`, dass die
Zone im Image auflöst.

## Zugriff

```
https://<TS_HOSTNAME>.<tailnet>.ts.net
```

Ein `tmux` mit dem Namen `main` — der Tab darf geschlossen werden, die Session
läuft weiter. Es gibt **kein Passwort**: die Zugangskontrolle ist die
Tailnet-Mitgliedschaft plus die ACL.

## Sicherheit

**Was strukturell gilt:**

- Kein `ports:`-Block. Nichts ist auf dem Host veröffentlicht.
- Kein `/var/run/docker.sock`. Der Socket wäre effektiv Root auf dem Host und
  gäbe an unauffälliger Stelle genau die Isolation auf, für die dieser Stack
  gebaut ist. Projekt-Toolchains gehören ins Image, Dienste als Services
  daneben.
- Prozesse laufen als `dev` (uid 1000), nicht als root.

**Was du selbst setzen musst:**

- **Tailscale-ACL** auf die eigenen Geräte einschränken. Tailnet-Mitgliedschaft
  allein ist keine Grenze, sobald das Tailnet geteilt wird.
- **`--max-turn-duration`** in `docker/supervisord.conf`. Der Default von
  7200 Sekunden ist für einen unbeaufsichtigten Agenten großzügig und die
  einzige Bremse gegen einen Agenten, der sich festfrisst.

**Was du wissen solltest:**

`buzz-acp` startet den Agenten mit `permission_mode=bypassPermissions` — das
ist der Default des Harness. Der Agent fragt nicht nach, bevor er schreibt. In
diesem Container ist das vertretbar, aber es ist eine Eigenschaft, keine
Nebensache.

`--respond-to owner-only` ist gesetzt. Nur der in `BUZZ_ACP_AGENT_OWNER`
hinterlegte Pubkey kann den Agenten auslösen.

## Deployment auf Coolify

Resource-Typ **Docker Compose**, auf dieses Repository zeigend.

`.github/workflows/tests.yml` führt bei jedem Push und jedem Pull Request
`test/compose.sh` und `test/image.sh` aus. Ausgerollt wird dabei **bewusst
nicht** — dieses Repository kommt ohne Deployment-Schritt, damit ein Fork nicht
das Deploy-Ziel eines Fremden mitschleppt.

Wer die Tests vor den eigenen Rollout hängen will, ergänzt einen Job, der nach
`tests` läuft und den eigenen Coolify-Deploy-Webhook aufruft. Dann in Coolify
**Automatic Deployment aus**: Coolify sieht die Testläufe nicht und rollte sonst
beim Push selbst aus, ohne auf sie zu warten.

**Keine Domain zuweisen und keine Ports freigeben** — sonst legt der
Coolify-Proxy einen öffentlichen Eintrag an und der ganze Zweck ist dahin.

Die Variablen kommen in die Coolify-UI, nicht als `.env` ins Repo. Drei davon
müssen sich vom lokalen Stack unterscheiden:

| Variable | Produktiv |
|---|---|
| `TS_HOSTNAME` | eigener Name, z. B. `claude-box` — sonst kollidiert der Node-State mit der lokalen Instanz |
| `TS_AUTHKEY` | ein **neuer** Key für die erste Anmeldung; danach leeren |
| `BUZZ_PRIVATE_KEY` | eigenes Keypair, sonst antworten zwei Agenten auf dasselbe `@mention` |

`BUZZ_RELAY_URL` und `BUZZ_ACP_AGENT_OWNER` bleiben gleich.

Auf einem amd64-Host baut das Image ohne Emulation und damit deutlich schneller
als lokal auf Apple Silicon.

Coolify übernimmt `network_mode: "service:tailscale"`: Sein Compose-Parser
lässt an einem solchen Service den `networks:`-Block weg, den er sonst
injiziert.

**Keine Bind-Mounts aus dem Repo.** Coolify legt für einen relativen Pfad wie
`./docker/serve.json` nicht die Datei aus dem Checkout ab, sondern ein leeres
**Verzeichnis** unter `/data/coolify/applications/<uuid>/`. Deshalb steckt
`serve.json` im Sidecar-Image (`docker/tailscale.Dockerfile`), und
`test/compose.sh` schlägt fehl, sobald wieder ein Bind-Mount auftaucht. Ein
früheres Deployment hinterlässt das Verzeichnis auf dem Host; es wird nicht
mehr benutzt und kann weg.

Das Symptom war unauffällig: `containerboot` liest die serve-Konfiguration erst
nach der Anmeldung, beendet sich am Verzeichnis und startet neu — und `claude`
bleibt im alten Namespace ohne Netz zurück (siehe *Den Tailscale-Container nie
allein neu starten*). `buzz-acp` meldet dann nur
`Temporary failure in name resolution`.

**Coolify reicht alle Variablen in jeden Container.** Es schreibt jedem Service
`env_file: .env` dazu. Für den Sidecar heißt das: `TS_HOSTNAME` steht immer in
seiner Umgebung, und `containerboot` macht daraus selbst `--hostname`. Ein
zweites `--hostname` in `TS_EXTRA_ARGS` lässt `tailscale up` mit
`flag provided multiple times` abbrechen. Deshalb wird der Name nur über
`TS_HOSTNAME` gesetzt. Coolify löscht Container nach mehreren Neustarts; im
Log-Tab steht dann nur noch `No such container`.

**Build-Argumente manuell verwalten.** Unter *Advanced → Build arguments*
„Managed manually in Dockerfile" wählen. Sonst schreibt Coolify vor jedem Build
für jede Variable eine `ARG`-Zeile in beide Dockerfiles — auch für
`TS_AUTHKEY`, `BUZZ_PRIVATE_KEY` und die GitHub-Tokens — und übergibt die Werte
per `--build-arg`. Keins der Images braucht Build-Argumente. Der
Umschreibschritt ist außerdem schon mit Exit-Code 255 ohne jede Meldung
abgebrochen und hat das Deployment mitgerissen.

## Tests

```bash
./test/compose.sh  # 11 Assertions gegen Compose-Datei und Sidecar-Image
./test/image.sh    # 122 Assertions gegen das Image
./test/stack.sh    # 17 Assertions gegen den laufenden Stack
```

`test/compose.sh` braucht weder `.env` noch Tailnet und belegt, dass kein
Service an einem Host-Pfad hängt.

`compose.sh` und `image.sh` laufen in der GitHub Action bei jedem Push.
`stack.sh` nicht: Es braucht einen Auth-Key und meldete bei jedem Lauf einen
neuen Node im Tailnet an.

**Maßgeblich ist der Lauf in der Action, nicht der auf dem Mac.** Docker Desktop
setzt Rechte und Besitz in eingehängten Host-Verzeichnissen nicht durch, Linux
schon. Beide Richtungen sind schon passiert: Ein Test war lokal grün und auf dem
Runner rot, weil ein Prozess als `dev` nicht in den Ordner schreiben konnte —
und die Assertion „wiederhergestellte Config gehört dev" ist umgekehrt lokal
rot (`600 root`) und auf dem Runner grün.

`test/stack.sh` belegt unter anderem, dass der `claude`-Container am
Netzwerk-Namespace von `tailscale` hängt, dass kein Port auf dem Host
veröffentlicht ist und dass `ttyd` vom Host aus nicht erreichbar ist.

## Betrieb

### Dem Agenten zusehen

Der Buzz-Agent läuft ohne Terminal: supervisord startet `buzz-acp`, und das
steuert `claude-agent-acp` im Hintergrund. In der tmux-Session des
Web-Terminals taucht er deshalb nicht auf. Mitlesen lässt er sich trotzdem —
in einem zweiten tmux-Fenster (`Strg+b c`, zurück mit `Strg+b n`):

```bash
agent-watch
```

```
=== Session 1ae3324a-….jsonl ===

[Eingang] <buzz-event type="@mention"> … Content: @Tuatara prüf bitte den Build …

[Claude] Ich schaue mir zuerst den letzten Lauf an.
  -> Bash: git log --oneline -5
     ok
```

`agent-watch` liest das Transkript, das jeder Turn unter
`~/.claude/projects/` hinterlässt. Es zeigt die letzten 40 Einträge der
neuesten Agenten-Session, folgt ihr live und wechselt, sobald der Agent in
einer anderen Session schreibt — etwa nach `idle_timeout` oder in einem
anderen Channel. Gibt es noch keine, wartet es. Die eigenen Terminal-Sitzungen
liegen im selben Verzeichnis und werden übergangen: Agenten-Sessions tragen
`"entrypoint": "sdk-ts"`.

Es liest nur. Eine Agenten-Session mit `claude --resume` zu öffnen, wäre
dagegen keine gute Idee — jede Eingabe dort landet in derselben Session, in der
der Agent gerade arbeitet.

### Den Tailscale-Container nie allein neu starten

Der `tailscale`-Service **besitzt den Netzwerk-Namespace**; `claude` tritt ihm
über `network_mode: "service:tailscale"` bei. Ein `docker compose restart
tailscale` erzeugt einen neuen Namespace, an dem `claude` nicht mehr hängt —
und zwar **ohne dass es auffällt**: Beide Container laufen weiter, `ttyd` und
`sshd` lauschen weiter, nur erreicht Tailscale sie nicht mehr. Von außen sieht
es aus, als sei der Dienst tot.

Richtig ist:

```bash
docker compose restart tailscale
docker compose restart claude     # muss folgen
```

Ein einfacher Neustart genügt — der Container tritt beim Start dem *aktuellen*
Namespace bei, ein `--force-recreate` ist nicht nötig.

`test/stack.sh` prüft das: Der Vergleich der Container-IDs allein reicht nicht,
denn die bleibt beim Neustart gleich. Geprüft wird stattdessen, ob der
`tailscale`-Container die Dienste von `claude` auf `127.0.0.1` tatsächlich
erreicht.

## Fallstricke

- **Der Tailscale-Sidecar darf nicht auf `linux/amd64` gepinnt werden.** Unter
  Rosetta scheitert die Anmeldung am Controlplane mit
  `chacha20poly1305: message authentication failed`. Nur unser eigenes Image
  braucht amd64, wegen der Buzz-Binaries.
- **`docker compose down -v` löscht die Tailscale-Identität** und den
  Claude-Login. Für Neustarts `down` ohne `-v` benutzen; sonst brauchst du
  einen neuen Auth-Key und einen neuen OAuth-Login.
- **Claude will nach jedem Redeploy neu eingerichtet werden**, obwohl die
  Credentials im Volume liegen: Dann fehlt `CLAUDE_CONFIG_DIR` in dieser
  Sitzung, und die Config landet wieder im flüchtigen `~/.claude.json`. Im
  Image ist sie gesetzt, für SSH per `SetEnv` in `docker/sshd_config`. Wer
  Claude über einen anderen Weg startet, muss sie selbst mitgeben. Fehlt beim
  Start die `.claude.json` im Volume, stellt der Entrypoint die neueste
  Sicherung mit Konto aus `~/.claude/backups` wieder her.
- **Die `buzz-cli`-Skill liegt unter `/opt/buzz-skills`**, nicht direkt unter
  `/home/dev/.buzz`. Dort hängt ein Volume, das Image-Inhalte verdecken würde;
  der Entrypoint spiegelt sie bei jedem Start hinein. `buzz-acp` rollt sie
  nicht selbst aus — das macht lokal die Desktop-App, die es hier nicht gibt.
- **Lokal auf Apple Silicon** läuft das Image unter Emulation. Für Rauchtests
  reicht das, der Build dauert aber spürbar länger.

## Lizenz

[MIT](LICENSE) — © 2026 Bastian Strauss, WUS Solutions.

Nutzen, ändern, kommerziell betreiben: alles erlaubt. Die einzige Bedingung ist,
dass der Copyright-Hinweis und der Lizenztext in jeder Kopie und in jedem
wesentlichen Teil des Codes mitgehen.
