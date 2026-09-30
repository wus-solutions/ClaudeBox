#!/usr/bin/env bash
# Assertions gegen das gebaute Image. Jede Task ergaenzt hier Pruefungen.
set -uo pipefail

PLATFORM="linux/amd64"
IMAGE="claude-box:test"
FAILED=0

# Jeder detached gestartete Container wird hier vermerkt und in jedem Fall
# wieder entfernt - auch wenn das Skript abbricht oder in ein Timeout laeuft.
# Ohne das bleiben Container stehen, die niemand mehr zuordnen kann.
CONTAINERS=()
cleanup() {
  if [[ ${#CONTAINERS[@]} -gt 0 ]]; then
    docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# Startet einen Container detached und merkt ihn sich fuer das Aufraeumen.
spawn() { local id; id=$(docker run -d "$@"); CONTAINERS+=("$id"); printf '%s' "$id"; }

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# check <beschreibung> <erwartetes-teilstring> <kommando...>
check() {
  local desc="$1" expect="$2"; shift 2
  local out
  out=$("$@" 2>&1)
  if [[ "$out" == *"$expect"* ]]; then pass "$desc"; else
    fail "$desc"
    printf '       erwartet: %s\n       erhalten: %s\n' "$expect" "${out:0:400}"
  fi
}

echo "== Stage: buzz-binaries =="
docker build --platform "$PLATFORM" --target buzz-binaries -t claude-box:buzz . >/dev/null 2>&1 \
  || { fail "Stage 'buzz-binaries' baut"; exit 1; }
pass "Stage 'buzz-binaries' baut"

for b in buzz buzz-acp buzz-agent git-credential-nostr; do
  check "Binary /out/$b vorhanden" "/out/$b" \
    docker run --rm --platform "$PLATFORM" claude-box:buzz ls "/out/$b"
done

check "buzz-acp ist lauffaehig" "ACP harness" \
  docker run --rm --platform "$PLATFORM" --entrypoint /out/buzz-acp claude-box:buzz --help

echo
echo "== Stage: runtime =="
docker build --platform "$PLATFORM" -t "$IMAGE" . >/dev/null 2>&1 \
  || { fail "Runtime-Image baut"; exit 1; }
pass "Runtime-Image baut"

# --entrypoint "" umgeht den supervisord-Entrypoint: hier wollen wir
# Einmal-Kommandos ausfuehren, keinen Langlaeufer starten.
run() { docker run --rm --platform "$PLATFORM" --entrypoint "" "$IMAGE" "$@"; }

check "glibc erfuellt die Buzz-Anforderung (>= 2.39)" "2.41" \
  run bash -c 'ldd --version | head -1'
check "Claude Code installiert"        "Claude Code"  run claude --version
check "ACP-Adapter im PATH"            "claude-agent-acp" run bash -c 'command -v claude-agent-acp'
check "Buzz-CLI lauffaehig"            "buzz"         run buzz --help
check "buzz-acp lauffaehig"            "ACP harness"  run buzz-acp --help
check "git-credential-nostr vorhanden" "git-credential-nostr" run bash -c 'command -v git-credential-nostr'
check "jq vorhanden"                   "jq-"          run jq --version
check "pdftotext vorhanden"            "pdftotext version" run pdftotext -v
check "Prozesse laufen als dev"        "uid=1000(dev)" run bash -c 'su dev -c id'
check "dev darf sudo ohne Passwort"    "uid=0(root)"   run bash -c 'su dev -c "sudo -n id"'
check "HOME zeigt auf /home/dev"       "/home/dev"    run bash -c 'echo $HOME'
check "Claude-Config liegt im Volume"  "CLAUDE_CONFIG_DIR=/home/dev/.claude" \
  run bash -c 'su dev -c "env" | grep CLAUDE_CONFIG_DIR'

for d in /workspace /home/dev/.claude /home/dev/.buzz /home/dev/.vscode-server /home/dev/.zed_server \
         /home/dev/.antigravity-ide-server; do
  check "Verzeichnis $d gehoert dev" "dev dev" \
    run stat -c '%U %G' "$d"
done

check "Autoupdater ist aus" "DISABLE_AUTOUPDATER=1" \
  run bash -c 'env | grep DISABLE_AUTOUPDATER'

# ss stammt aus iproute2 und wird in Task 3 gebraucht, um die Bindung von ttyd
# zu pruefen. Fehlt es, schlagen dort die wichtigsten Assertions still fehl.
check "ss verfuegbar (iproute2)" "/usr/bin/ss" \
  run bash -c 'command -v ss'

# Antigravitys Remote-Installer laedt seinen Server ausschliesslich mit wget
# und bricht sonst mit "Error need wget to download server binary" ab.
check "wget verfuegbar (Remote-IDE-Installer)" "/usr/bin/wget" \
  run bash -c 'command -v wget'

echo
echo "== Web-Terminal =="
CID=$(spawn --platform "$PLATFORM" "$IMAGE")
# supervisord und ttyd brauchen einen Moment bis der Socket steht.
for _ in $(seq 1 30); do
  docker exec "$CID" bash -c 'ss -ltn 2>/dev/null | grep -q 7681' && break
  sleep 1
done

# Zuerst: laeuft der Container ueberhaupt? Ohne diese Pruefung wuerde die
# Loopback-Assertion unten gruen werden, weil dann schlicht nichts lauscht.
if [[ "$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null)" == "true" ]]; then
  pass "Container laeuft"
else
  fail "Container laeuft nicht - alle folgenden Pruefungen sind bedeutungslos"
  docker logs "$CID" 2>&1 | tail -20 | sed 's/^/       /'
fi

LISTEN=$(docker exec "$CID" bash -c 'ss -ltn' 2>&1)

check "ttyd lauscht auf Port 7681" "7681" echo "$LISTEN"

# Der entscheidende Punkt: gebunden an Loopback, nicht an alle Interfaces.
# Positiv formuliert, damit ein toter Container nicht faelschlich besteht.
if grep -qE '127\.0\.0\.1:7681|\[::1\]:7681' <<<"$LISTEN" \
   && ! grep -qE '0\.0\.0\.0:7681|\*:7681|\[::\]:7681' <<<"$LISTEN"; then
  pass "ttyd bindet ausschliesslich an Loopback"
else
  fail "ttyd bindet nicht ausschliesslich an Loopback"
  sed 's/^/       /' <<<"$LISTEN"
fi

check "ttyd antwortet mit HTTP 200" "200" \
  docker exec "$CID" bash -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7681/'

check "ttyd startet tmux als Kommando" "start command: tmux new -A -s main" \
  docker logs "$CID"

check "tmux ist installiert" "tmux 3." \
  docker exec "$CID" tmux -V

check "supervisord fuehrt ttyd als running" "ttyd" \
  docker exec "$CID" supervisorctl status

# Der Oeffnen-Dialog der Editoren startet im Home. Ohne diesen Link liegen dort
# nur versteckte Verzeichnisse und der Container wirkt leer.
check "~/workspace zeigt auf /workspace" "/workspace" \
  docker exec "$CID" readlink /home/dev/workspace
check "und ist als dev benutzbar" "workspace" \
  docker exec --user dev "$CID" bash -c 'cd ~/workspace && basename "$(pwd -P)"'

# Ohne Agenten-Konfiguration muss der Container trotzdem hochkommen: ein
# Tippfehler in der Deployment-Konfiguration darf nicht das Terminal kosten,
# mit dem man ihn findet.
check "ohne BUZZ_AGENTS entsteht kein Agenten-Prozess" "no such process" \
  docker exec "$CID" supervisorctl status buzz-acp-default
check "und der Container sagt warum" "kein Agent konfiguriert" \
  docker logs "$CID"

docker rm -f "$CID" >/dev/null

echo
echo "== GitHub-Credentials =="
check "Credential-Helper ist systemweit registriert" "github-token" \
  run git config --system --get 'credential.https://github.com.helper'

# Ohne Token muss der Helper schweigen, statt git etwas Falsches zu liefern.
# Erwartet wird die Zahl 0 - ein leerer Erwartungswert waere vakuum-positiv,
# weil jeder String den Leerstring enthaelt.
check "ohne Token liefert der Helper keine password-Zeile" "TREFFER=0" \
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" \
    | git credential fill 2>/dev/null \
    | grep -c "^password=" | sed "s/^/TREFFER=/"'

# Mit Token: der richtige Wert kommt an ...
TOKEN="github_pat_TESTWERT_nur_fuer_den_test_4711"
check "mit Token liefert der Helper ihn aus" "$TOKEN" \
  docker run --rm --platform "$PLATFORM" --entrypoint "" -e GITHUB_TOKEN="$TOKEN" "$IMAGE" \
    bash -c 'printf "protocol=https\nhost=github.com\n\n" | git credential fill'

# ... und landet trotzdem in keiner Datei. Das ist der eigentliche Punkt:
# der Token existiert nur in der Prozessumgebung.
GID=$(spawn --platform "$PLATFORM" -e GITHUB_TOKEN="$TOKEN" \
        -e GIT_USER_NAME="Testagent" -e GIT_USER_EMAIL="test@example.invalid" "$IMAGE")
for _ in $(seq 1 30); do
  docker exec "$GID" bash -c 'test -f /home/dev/.gitconfig' 2>/dev/null && break
  sleep 1
done
HITS=$(docker exec "$GID" bash -c "grep -rl '$TOKEN' /home/dev /etc/gitconfig 2>/dev/null | head -5")
if [[ -z "$HITS" ]]; then
  pass "Token steht in keiner Datei unter /home/dev"
else
  fail "Token gefunden in: $HITS"
fi

check "Commit-Identitaet ist gesetzt" "Testagent" \
  docker exec --user dev "$GID" git config --global --get user.name

check "Commit funktioniert mit vollstaendiger Identitaet" "COMMIT_OK" \
  docker exec --user dev "$GID" bash -c \
    'mkdir -p /tmp/c && cd /tmp/c && git init -q -b main . && echo x > a && git add a \
     && git commit -qm t && git log -1 --pretty=%an >/dev/null && echo COMMIT_OK'

# Ohne E-Mail muss der Container warnen, statt den Fehler bis in einen
# Buzz-Turn zu verschleppen. Der Container laeuft hier MIT Entrypoint, also
# mit supervisord - er kehrt nie zurueck. Deshalb detached starten und die
# Logs lesen, statt auf ein Ende zu warten.
WID=$(spawn --platform "$PLATFORM" -e GIT_USER_NAME="X" "$IMAGE")
for _ in $(seq 1 20); do
  docker logs "$WID" 2>&1 | grep -q 'GIT_USER_EMAIL' && break
  sleep 1
done
check "warnt bei fehlender GIT_USER_EMAIL" "GIT_USER_EMAIL ist nicht gesetzt" \
  docker logs "$WID"
docker rm -f "$WID" >/dev/null

docker rm -f "$GID" >/dev/null

echo
echo "== SSH =="
# Ein Wegwerf-Schluesselpaar nur fuer diesen Test.
KDIR=$(mktemp -d); ssh-keygen -q -t ed25519 -N "" -f "$KDIR/id" -C "test@claude-box"
PUB=$(cat "$KDIR/id.pub")

SID=$(spawn --platform "$PLATFORM" -e SSH_AUTHORIZED_KEYS="$PUB" \
      -e GIT_USER_NAME=x -e GIT_USER_EMAIL=x@x "$IMAGE")
for _ in $(seq 1 30); do
  docker exec "$SID" bash -c 'ss -ltn 2>/dev/null | grep -q ":22 "' && break
  sleep 1
done

SLISTEN=$(docker exec "$SID" bash -c 'ss -ltn' 2>&1)
check "sshd lauscht auf Port 22" ":22" echo "$SLISTEN"

# Der entscheidende Punkt, wie beim Web-Terminal: nur Loopback.
if grep -qE '127\.0\.0\.1:22' <<<"$SLISTEN" \
   && ! grep -qE '0\.0\.0\.0:22|\*:22|\[::\]:22' <<<"$SLISTEN"; then
  pass "sshd bindet ausschliesslich an Loopback"
else
  fail "sshd bindet nicht ausschliesslich an Loopback"
  sed 's/^/       /' <<<"$SLISTEN"
fi

check "Passwort-Anmeldung ist aus" "passwordauthentication no" \
  docker exec "$SID" bash -c 'sshd -T 2>/dev/null | grep -i "^passwordauthentication"'
check "root darf sich nicht anmelden" "permitrootlogin no" \
  docker exec "$SID" bash -c 'sshd -T 2>/dev/null | grep -i "^permitrootlogin"'
check "nur der Benutzer dev ist zugelassen" "allowusers dev" \
  docker exec "$SID" bash -c 'sshd -T 2>/dev/null | grep -i "^allowusers"'
check "authorized_keys hat Mode 600" "600 dev" \
  docker exec "$SID" stat -c '%a %U' /home/dev/.ssh/authorized_keys

# Der eigentliche Beweis: eine echte Anmeldung mit dem Schluessel.
docker cp "$KDIR/id" "$SID:/tmp/testkey" >/dev/null 2>&1
docker exec "$SID" chmod 600 /tmp/testkey
check "Anmeldung mit dem Schluessel gelingt" "ANGEMELDET_ALS_dev" \
  docker exec "$SID" bash -c 'ssh -i /tmp/testkey -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes dev@127.0.0.1 \
    "echo ANGEMELDET_ALS_\$(whoami)" 2>&1'

# sshd reicht die ENV-Zeilen des Images nicht durch; ohne SetEnv schriebe
# claude per SSH wieder ins fluechtige ~/.claude.json.
check "SSH-Sitzung sieht CLAUDE_CONFIG_DIR" "CFG=/home/dev/.claude" \
  docker exec "$SID" bash -c 'ssh -i /tmp/testkey -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes dev@127.0.0.1 \
    "echo CFG=\$CLAUDE_CONFIG_DIR" 2>&1'

# Und die Gegenprobe: ein fremder Schluessel kommt nicht rein.
ssh-keygen -q -t ed25519 -N "" -f "$KDIR/fremd" -C "fremd"
docker cp "$KDIR/fremd" "$SID:/tmp/fremdkey" >/dev/null 2>&1
docker exec "$SID" chmod 600 /tmp/fremdkey
FREMD=$(docker exec "$SID" bash -c 'ssh -i /tmp/fremdkey -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes dev@127.0.0.1 "echo DRIN" 2>&1' || true)
if grep -q "DRIN" <<<"$FREMD"; then
  fail "ein nicht hinterlegter Schluessel kommt durch"
else
  pass "fremder Schluessel wird abgewiesen"
fi
docker rm -f "$SID" >/dev/null

# Ohne hinterlegte Keys darf sshd nicht laufen - und der Container muss trotzdem hochkommen.
NID=$(spawn --platform "$PLATFORM" -e GIT_USER_NAME=x -e GIT_USER_EMAIL=x@x "$IMAGE")
for _ in $(seq 1 20); do
  docker logs "$NID" 2>&1 | grep -q 'SSH_AUTHORIZED_KEYS' && break
  sleep 1
done
check "ohne Keys bleibt sshd aus" "sshd bleibt aus" docker logs "$NID"
NLISTEN=$(docker exec "$NID" bash -c 'ss -ltn' 2>&1)
if grep -qE ':22 ' <<<"$NLISTEN"; then
  fail "sshd lauscht, obwohl kein Schluessel hinterlegt ist"
else
  pass "ohne Keys lauscht nichts auf 22"
fi
check "das Web-Terminal laeuft trotzdem" "ttyd" docker exec "$NID" supervisorctl status
docker rm -f "$NID" >/dev/null
rm -rf "$KDIR"

echo
echo "== Skills =="
SDIR=$(mktemp -d); mkdir -p "$SDIR/src/aus-dem-repo" "$SDIR/src/kollision" "$SDIR/dest"
echo "# aus dem Repo" > "$SDIR/src/aus-dem-repo/SKILL.md"
echo "REPO-FASSUNG" > "$SDIR/src/kollision/SKILL.md"
# Zwei Skills, die es nur im Ziel gibt - sie stehen fuer Laufzeit-Anlagen.
mkdir -p "$SDIR/dest/nur-laufzeit" "$SDIR/dest/kollision"
echo "# zur Laufzeit angelegt" > "$SDIR/dest/nur-laufzeit/SKILL.md"
echo "LAUFZEIT-FASSUNG" > "$SDIR/dest/kollision/SKILL.md"

SOUT=$(docker run --rm --platform "$PLATFORM" \
  -v "$SDIR/src:/opt/testskills:ro" -v "$SDIR/dest:/dest" \
  -e SKILLS_SRC=/opt/testskills -e SKILLS_DEST=/dest \
  -e GIT_USER_NAME=x -e GIT_USER_EMAIL=x@x \
  --entrypoint bash "$IMAGE" -c '
    source /dev/stdin <<<"$(sed -n "/^mirror_skills()/,/^}/p" /usr/local/bin/entrypoint.sh)"
    mirror_skills /opt/testskills /dest "Claude-Skills" 2>&1
    echo "---"
    ls /dest
    echo "---"
    cat /dest/kollision/SKILL.md' 2>&1)

check "Skill aus dem Image landet im Ziel" "aus-dem-repo" echo "$SOUT"
check "Laufzeit-Skill wird nicht geloescht" "nur-laufzeit" echo "$SOUT"
check "bei Namensgleichheit gewinnt das Image" "REPO-FASSUNG" echo "$SOUT"
check "die Spiegelung meldet sich im Log" "Claude-Skills:" echo "$SOUT"
rm -rf "$SDIR"

# Ein leeres skills/ darf nichts kaputtmachen - so ist der Auslieferungszustand.
EDIR=$(mktemp -d); mkdir -p "$EDIR/leer" "$EDIR/dest"
check "leeres Skill-Verzeichnis stoert nicht" "OK" \
  docker run --rm --platform "$PLATFORM" -v "$EDIR/leer:/opt/testskills:ro" -v "$EDIR/dest:/dest" \
    -e SKILLS_SRC=/opt/testskills -e SKILLS_DEST=/dest --entrypoint bash "$IMAGE" -c '
      source /dev/stdin <<<"$(sed -n "/^mirror_skills()/,/^}/p" /usr/local/bin/entrypoint.sh)"
      mirror_skills /opt/testskills /dest "Claude-Skills" 2>/dev/null; echo OK'
rm -rf "$EDIR"

echo
echo "== Agenten-Rendering =="
# Der Renderer ist die Stelle, an der aus agents/<name>.md ein Prozess wird.
# Frontmatter-Schluessel muessen zu BUZZ_ACP_*-Variablen werden - das ist die
# Eigenschaft, die neue buzz-acp-Optionen ohne Codeaenderung nutzbar macht.
RDIR=$(mktemp -d)
mkdir -p "$RDIR/agents" "$RDIR/conf" "$RDIR/prompts" "$RDIR/probe" "$RDIR/out"
cat > "$RDIR/agents/probe.md" <<'AGENT'
---
enabled: true
model: opus
max_turn_duration: 1234
respond_to: allowlist
parallelism: 2
---
Du bist eine Testechse.
AGENT
cat > "$RDIR/agents/geparkt.md" <<'AGENT'
---
enabled: false
---
Nie aktiv.
AGENT

RENDER=$(docker run --rm --platform "$PLATFORM" --entrypoint "" \
  -v "$RDIR/agents:/opt/agents:ro" -v "$RDIR/conf:/conf" -v "$RDIR/prompts:/prompts" \
  -e AGENTS_DIR=/opt/agents -e SUPERVISOR_CONF_DIR=/conf -e AGENT_PROMPT_DIR=/prompts \
  "$IMAGE" /usr/local/bin/render-agents.py probe geparkt 2>&1)

check "aktiver Agent wird gerendert" "probe: aktiv" echo "$RENDER"
check "geparkter Agent wird uebersprungen" "geparkt: uebersprungen" echo "$RENDER"
check "parallelism geht in die Speicherschaetzung ein" "2 Worker" echo "$RENDER"

CONF=$(cat "$RDIR/conf/agent-probe.conf" 2>/dev/null)
check "Prozessname folgt dem Agentennamen" "[program:buzz-acp-probe]" echo "$CONF"
check "model wird zu BUZZ_ACP_MODEL"       'BUZZ_ACP_MODEL="opus"' echo "$CONF"
check "max_turn_duration wird durchgereicht" 'BUZZ_ACP_MAX_TURN_DURATION="1234"' echo "$CONF"
check "respond_to wird durchgereicht"      'BUZZ_ACP_RESPOND_TO="allowlist"' echo "$CONF"
check "Systemprompt liegt als Datei vor"   'BUZZ_ACP_SYSTEM_PROMPT_FILE="/prompts/probe.prompt"' echo "$CONF"

# Der Prompt darf kein Frontmatter mehr enthalten.
PROMPT=$(cat "$RDIR/prompts/probe.prompt" 2>/dev/null)
if [[ "$PROMPT" == *"Testechse"* && "$PROMPT" != *"enabled:"* ]]; then
  pass "Frontmatter ist aus dem Systemprompt entfernt"
else
  fail "Systemprompt enthaelt noch Frontmatter oder ist leer"
fi

# Der eigentliche Punkt: der Schluessel steht nur als Referenz in der Datei.
if grep -q 'BUZZ_PRIVATE_KEY="%(ENV_BUZZ_AGENT_KEY_PROBE)s"' <<<"$CONF"; then
  pass "privater Schluessel wird nur referenziert, nicht geschrieben"
else
  fail "Schluessel steht nicht als ENV-Referenz in der Konfiguration"
fi
[[ -f "$RDIR/conf/agent-geparkt.conf" ]] && fail "geparkter Agent hat trotzdem eine Konfiguration" \
  || pass "geparkter Agent erzeugt keine Konfiguration"

# Kommagetrennte Werte wie respond_to_allowlist sind heikel: supervisords
# environment=-Zeile ist selbst kommagetrennt. Wird der Wert dort zerrissen,
# faellt das erst auf, wenn ein Agent auf niemanden mehr reagiert.
PK1=2222222222222222222222222222222222222222222222222222222222222222
PK2=1111111111111111111111111111111111111111111111111111111111111111
printf -- '---\nrespond_to: allowlist\nrespond_to_allowlist: %s,%s\n---\nTest.\n' "$PK1" "$PK2" \
  > "$RDIR/agents/komma.md"
docker run --rm --platform "$PLATFORM" --entrypoint "" \
  -v "$RDIR/agents:/opt/agents:ro" -v "$RDIR/conf:/conf" -v "$RDIR/prompts:/prompts" \
  -e AGENTS_DIR=/opt/agents -e SUPERVISOR_CONF_DIR=/conf -e AGENT_PROMPT_DIR=/prompts \
  "$IMAGE" /usr/local/bin/render-agents.py komma >/dev/null 2>&1

# Der eigentliche Beweis: supervisord starten und die Kind-Umgebung auslesen.
mkdir -p "$RDIR/out"
# Der Prozess schreibt als dev (uid 1000). Auf einem Linux-Host gehoert das
# Verzeichnis dem aufrufenden Benutzer - auf dem GitHub-Runner uid 1001 - und
# dev koennte nicht hinein. Docker Desktop auf dem Mac setzt das nicht durch.
chmod 0777 "$RDIR/out"
sed 's|^command=.*|command=/bin/bash -c "env > /out/env.txt; sleep 30"|' \
    "$RDIR/conf/agent-komma.conf" > "$RDIR/probe/probe.conf" 2>/dev/null \
  || { mkdir -p "$RDIR/probe"; sed 's|^command=.*|command=/bin/bash -c "env > /out/env.txt; sleep 30"|' \
       "$RDIR/conf/agent-komma.conf" > "$RDIR/probe/probe.conf"; }
docker run --rm --platform "$PLATFORM" --entrypoint "" \
  -v "$RDIR/probe:/etc/supervisor/conf.d:ro" -v "$RDIR/out:/out" -v "$RDIR/prompts:/prompts" \
  -e BUZZ_AGENT_KEY_KOMMA=dummy -e BUZZ_RELAY_URL=wss://x -e BUZZ_ACP_AGENT_OWNER=owner \
  -e GITHUB_TOKENS= -e GITHUB_TOKEN= \
  "$IMAGE" bash -c 'supervisord -c /etc/supervisor/supervisord.conf >/dev/null 2>&1 & sleep 8' >/dev/null 2>&1

check "kommagetrennte Allowlist kommt unversehrt im Prozess an" "$PK1,$PK2" \
  cat "$RDIR/out/env.txt"

rm -rf "$RDIR"

echo
echo "== Agent mitlesen =="
# Der Buzz-Agent laeuft ohne Terminal. agent-watch folgt seinem Transkript in
# ~/.claude/projects. Dort liegen auch die eigenen Terminal-Sitzungen - die
# duerfen nicht gewaehlt werden, auch wenn sie neuer sind.
AW=$(spawn --platform "$PLATFORM" --entrypoint "" "$IMAGE" sleep infinity)

# Ein Eintrag im Aufbau der echten Transkripte von claude-agent-acp.
entry() { # <session> <entrypoint> <type> <content-json>
  printf '{"parentUuid":null,"isSidechain":false,"type":"%s","message":{"role":"%s","content":%s},"uuid":"%s","timestamp":"2026-09-14T07:00:00.000Z","userType":"external","entrypoint":"%s","cwd":"/workspace","sessionId":"%s","version":"2.1.237","gitBranch":"HEAD"}\n' \
    "$3" "$3" "$4" "$RANDOM-$RANDOM" "$2" "$1"
}
put() { # <datei> - haengt stdin als dev an
  docker exec -i --user dev "$AW" bash -c "mkdir -p \"\$(dirname '$1')\" && cat >> '$1'"
}
# wartet, bis <muster> in <datei> im Container auftaucht
seen() {
  for _ in $(seq 1 40); do
    docker exec "$AW" grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}

P=/home/dev/.claude/projects
{ entry agent-1 sdk-ts user '"@Agent bitte pruefen"'
  entry agent-1 sdk-ts assistant '[{"type":"text","text":"AGENT_ANTWORT"}]'
  entry agent-1 sdk-ts assistant '[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"git status --short","description":"Status"}}]'
  entry agent-1 sdk-ts user '[{"type":"tool_result","tool_use_id":"toolu_1","content":"M README.md","is_error":false}]'
} | put "$P/-workspace/agent-1.jsonl"
sleep 1
entry eigene-1 cli user '"EIGENE_SITZUNG"' | put "$P/-workspace/eigene-1.jsonl"

docker exec -d --user dev "$AW" bash -c 'agent-watch > /tmp/watch.out 2>&1'

if seen /tmp/watch.out AGENT_ANTWORT; then
  pass "agent-watch zeigt die Antwort des Agenten"
else
  fail "agent-watch zeigt die Antwort des Agenten nicht"
  docker exec "$AW" head -c 400 /tmp/watch.out 2>&1 | sed 's/^/       /'
fi
if docker exec "$AW" grep -qF EIGENE_SITZUNG /tmp/watch.out; then
  fail "agent-watch zeigt die eigene Terminal-Sitzung statt des Agenten"
else
  pass "die eigene Terminal-Sitzung wird nicht gewaehlt, obwohl sie neuer ist"
fi
seen /tmp/watch.out "Bash: git status --short" \
  && pass "Werkzeugaufrufe erscheinen mit ihrem Befehl" \
  || fail "Werkzeugaufruf fehlt in der Ausgabe"

entry agent-1 sdk-ts assistant '[{"type":"text","text":"LIVE_NACHGEREICHT"}]' | put "$P/-workspace/agent-1.jsonl"
seen /tmp/watch.out LIVE_NACHGEREICHT \
  && pass "neue Eintraege erscheinen live" \
  || fail "ein nachgereichter Eintrag erscheint nicht"

# buzz-acp beginnt nach idle_timeout eine neue Session. Bliebe agent-watch an
# der alten haengen, saehe man ab dann nichts mehr.
sleep 1
entry agent-2 sdk-ts assistant '[{"type":"text","text":"NEUE_SESSION"}]' | put "$P/-home-dev--buzz/agent-2.jsonl"
seen /tmp/watch.out NEUE_SESSION \
  && pass "agent-watch wechselt zu einer neuen Agent-Session" \
  || fail "agent-watch bleibt an der alten Session haengen"

# Vor dem ersten @mention gibt es noch kein Transkript. Dann soll agent-watch
# warten, statt abzubrechen - man startet es typischerweise vorher.
docker exec -d --user dev -e HOME=/tmp/leer "$AW" bash -c 'mkdir -p /tmp/leer && agent-watch > /tmp/leer.out 2>&1'
sleep 3
entry agent-3 sdk-ts assistant '[{"type":"text","text":"ERSTE_SESSION"}]' | put /tmp/leer/.claude/projects/-workspace/agent-3.jsonl
seen /tmp/leer.out ERSTE_SESSION \
  && pass "ohne Transkript wartet agent-watch auf die erste Session" \
  || fail "agent-watch greift die erste Session nicht auf"

docker rm -f "$AW" >/dev/null

echo
echo "== Pakete und cron =="
# packages.txt ist die Liste, die man pflegt, ohne das Dockerfile anzufassen.
# Geprueft wird am Ergebnis: steht ein Paket drin, muss sein Programm im Image
# liegen. Kommentare und Leerzeilen faengt schon der Build ab - kaemen sie bei
# apt an, baute das Image nicht.
# Geprueft wird ueber dpkg, nicht ueber Programmnamen: die stimmen oft nicht
# mit dem Paketnamen ueberein (dnsutils -> dig), und tzdata oder python3-venv
# bringen gar kein eigenes Programm mit.
PKGS=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' packages.txt | tr -d '\r')
while read -r pkg _; do
  [[ -z "$pkg" ]] && continue
  check "Paket $pkg ist installiert" "ok installed" \
    run dpkg-query -W -f '${Status}' "$pkg"
done <<<"$PKGS"

# tzdata allein reicht nicht - ohne gesetzte Zone bleibt der Container bei UTC.
# Geprueft wird deshalb, dass die Zone im Image wirklich aufloest.
ZONE=$(run bash -c 'TZ=Europe/Berlin date +%Z' 2>&1)
if [[ -n "$ZONE" && "$ZONE" != *UTC* ]]; then
  pass "Zeitzone Europe/Berlin loest auf ($ZONE)"
else
  fail "Europe/Berlin loest nicht auf - tzdata fehlt (erhalten: $ZONE)"
fi

# Gegenprobe zu den Paketnamen: diese Programme heissen anders als ihr Paket.
check "dig ist da" "dig"          run bash -c 'command -v dig'
check "nc ist da" "nc"            run bash -c 'command -v nc'
check "pip ist da" "pip"          run bash -c 'command -v pip3'
check "venv ist nutzbar" "usage"  run bash -c 'python3 -m venv --help 2>&1 | head -1 | tr "A-Z" "a-z"'
check "PHP ist da" "PHP"          run php --version
check "composer ist da" "Composer" run bash -c 'composer --version 2>&1'

# Ein Crontab ohne laufenden Dienst feuert nie. Der Entrypoint richtet cron nur
# ein, wenn das Paket in packages.txt steht - deshalb hier der Beweis am
# laufenden Container, nicht an einer Konfigurationsdatei.
CID=$(spawn --platform "$PLATFORM" -e GIT_USER_NAME=x -e GIT_USER_EMAIL=x@x "$IMAGE")
for _ in $(seq 1 60); do
  docker exec "$CID" supervisorctl status cron 2>/dev/null | grep -q RUNNING && break
  sleep 1
done
check "cron laeuft als Dienst" "RUNNING" docker exec "$CID" supervisorctl status cron

# Der Agent legt seine Crontabs als dev an. Ohne die richtigen Rechte auf
# /var/spool/cron/crontabs meldet crontab nur "must be suid to work properly".
docker exec --user dev "$CID" bash -c \
  'printf "* * * * * touch /tmp/cron-lief\n" | crontab -' >/dev/null 2>&1
check "dev kann einen Crontab anlegen" "cron-lief" \
  docker exec --user dev "$CID" crontab -l

# Und er muss wirklich ausgeloest werden. cron startet auf die Minute, deshalb
# bis zu 80 Sekunden Geduld.
CRON_OK=0
for _ in $(seq 1 80); do
  docker exec "$CID" test -f /tmp/cron-lief 2>/dev/null && { CRON_OK=1; break; }
  sleep 1
done
if [[ "$CRON_OK" == "1" ]]; then
  pass "ein Crontab von dev wird tatsaechlich ausgefuehrt"
else
  fail "der Crontab von dev feuert nicht"
  docker exec "$CID" supervisorctl status cron 2>&1 | sed 's/^/       /'
fi
docker rm -f "$CID" >/dev/null

echo
echo "== Claude-Config aus Sicherung =="
# Erster Start mit CLAUDE_CONFIG_DIR: die alte ~/.claude.json ist weg, die
# Sicherungen im Volume nicht. Die neueste ist hier absichtlich eine frische
# Config ohne Konto - so sieht es direkt nach einem Neustart aus.
CDIR=$(mktemp -d)
mkdir -p "$CDIR/backups"
printf '{"oauthAccount":{"x":"ALT"}}'  > "$CDIR/backups/.claude.json.backup.1789000000000"
printf '{"oauthAccount":{"x":"NEU"}}'  > "$CDIR/backups/.claude.json.backup.1789000000001"
printf '{"firstStartTime":"frisch"}'   > "$CDIR/backups/.claude.json.backup.1789000000002"

CID=$(spawn --platform "$PLATFORM" -v "$CDIR:/home/dev/.claude" -e PLUGINS_FILE=/nicht/da "$IMAGE")
for _ in $(seq 1 30); do
  docker exec "$CID" test -f /home/dev/.claude/.claude.json && break
  sleep 1
done
check "neueste Sicherung mit Konto wird wiederhergestellt" '"NEU"' \
  docker exec "$CID" cat /home/dev/.claude/.claude.json
check "wiederhergestellte Config gehoert dev und hat Mode 600" "600 dev" \
  docker exec "$CID" stat -c '%a %U' /home/dev/.claude/.claude.json
docker rm -f "$CID" >/dev/null

# Gegenprobe: eine vorhandene Config wird nie ueberschrieben. In einem eigenen
# Verzeichnis: der Entrypoint hat das erste an dev (uid 1000) uebergeben, und
# der Runner-Benutzer darf dort nicht mehr schreiben.
CDIR2=$(mktemp -d)
mkdir -p "$CDIR2/backups"
printf '{"oauthAccount":{"x":"NEU"}}' > "$CDIR2/backups/.claude.json.backup.1789000000001"
printf '{"oauthAccount":{"x":"AKTUELL"}}' > "$CDIR2/.claude.json"
CID=$(spawn --platform "$PLATFORM" -v "$CDIR2:/home/dev/.claude" -e PLUGINS_FILE=/nicht/da "$IMAGE")
for _ in $(seq 1 30); do
  docker exec "$CID" supervisorctl status ttyd 2>/dev/null | grep -q RUNNING && break
  sleep 1
done
check "vorhandene Config bleibt unangetastet" '"AKTUELL"' \
  docker exec "$CID" cat /home/dev/.claude/.claude.json
docker rm -f "$CID" >/dev/null
rm -rf "$CDIR" "$CDIR2" 2>/dev/null || sudo rm -rf "$CDIR" "$CDIR2" 2>/dev/null || true

echo
echo "== Plugins =="
# Der Entrypoint installiert die Plugins aus plugins.txt beim Start. Hier mit
# einem lokalen Marketplace, damit der Test ohne Netz auskommt - die echte
# Liste prueft test/stack.sh gegen den laufenden Stack.
PDIR=$(mktemp -d)
mkdir -p "$PDIR/markt/.claude-plugin" "$PDIR/markt/plugins/probe/.claude-plugin" \
         "$PDIR/markt/plugins/probe/skills/probe-skill"
printf '%s\n' '{"name":"test-markt","owner":{"name":"Test"},"plugins":[{"name":"probe","description":"Testplugin","source":"./plugins/probe"}]}' \
  > "$PDIR/markt/.claude-plugin/marketplace.json"
printf '%s\n' '{"name":"probe","description":"Testplugin","version":"0.0.1"}' \
  > "$PDIR/markt/plugins/probe/.claude-plugin/plugin.json"
printf -- '---\nname: probe-skill\ndescription: Testskill\n---\nTest.\n' \
  > "$PDIR/markt/plugins/probe/skills/probe-skill/SKILL.md"
cat > "$PDIR/plugins.txt" <<'LISTE'
# Kommentare und Leerzeilen werden uebersprungen

kaputt@nirgends  /gibt/es/nicht
probe@test-markt /opt/test-markt
LISTE

PID=$(spawn --platform "$PLATFORM" -v "$PDIR/markt:/opt/test-markt:ro" \
        -v "$PDIR/plugins.txt:/opt/test-plugins.txt:ro" -e PLUGINS_FILE=/opt/test-plugins.txt "$IMAGE")
# Die Installation laeuft im Hintergrund, damit der Start nicht auf das Netz
# wartet. Gewartet wird deshalb auf das Ergebnis, nicht auf ttyd. Die Liste
# arbeitet von oben nach unten: steht probe, ist kaputt schon durch.
for _ in $(seq 1 60); do
  docker exec --user dev "$PID" claude plugin list --json 2>/dev/null | grep -q 'probe@test-markt' && break
  sleep 2
done

# Zuerst der Besitzer: "claude plugin list" legt selbst Dateien unter
# ~/.claude/plugins an und wuerde eine Pruefung dort vakuum-gruen machen.
# BESITZER= statt nur "dev": die Fehlermeldung von stat enthaelt den Pfad
# /home/dev/... und damit ebenfalls "dev".
check "das Plugin liegt im Home von dev und gehoert dev" "BESITZER=dev" \
  docker exec "$PID" stat -c 'BESITZER=%U' /home/dev/.claude/plugins/cache/test-markt/probe
check "Plugin aus der Liste ist fuer dev installiert und aktiv" '"enabled": true' \
  docker exec --user dev "$PID" claude plugin list --json
# Ein Plugin, das sich nicht installieren laesst - Netz weg, Quelle falsch -,
# darf den Container nicht mitreissen: set -e im Entrypoint wuerde sonst
# supervisord nie starten, und mit ihm weder Terminal noch Agent.
# ttyd meldet erst nach startsecs=3 RUNNING - auf einem schnellen Runner ist die
# Plugin-Installation oben frueher fertig.
for _ in $(seq 1 30); do
  docker exec "$PID" supervisorctl status ttyd 2>/dev/null | grep -q RUNNING && break
  sleep 1
done
check "eine nicht installierbare Quelle haelt den Start nicht auf" "RUNNING" \
  docker exec "$PID" supervisorctl status ttyd
check "und sie wird gemeldet" "kaputt@nirgends" docker logs "$PID"

docker rm -f "$PID" >/dev/null
rm -rf "$PDIR"

echo
echo "== Mehrere Token-Owner =="
# Ein Fine-grained Token gilt nur fuer einen Resource Owner. Der Helper waehlt
# den richtigen anhand des Repo-Pfads aus der GITHUB_TOKENS-Zuordnung.
FIRMA="github_pat_FIRMENTOKEN_4711"
PRIVAT="github_pat_PRIVATTOKEN_0815"
FALLBACK="github_pat_FALLBACK_9999"
MAP="alice=$PRIVAT,ExampleOrg=$FIRMA"

# Voraussetzung fuer alles Weitere: reicht git den Pfad ueberhaupt durch?
check "useHttpPath ist systemweit aktiv" "true" \
  run git config --system --get 'credential.https://github.com.useHttpPath'

fill() {  # fill <pfad>
  docker run --rm --platform "$PLATFORM" --entrypoint "" \
    -e GITHUB_TOKEN="$FALLBACK" -e GITHUB_TOKENS="$MAP" "$IMAGE" \
    bash -c "printf 'protocol=https\nhost=github.com\npath=$1\n\n' | git credential fill"
}

check "Firmen-Repo bekommt den Firmen-Token" "$FIRMA" \
  fill "ExampleOrg/service-api.git"

# Der Owner in der URL muss nicht exakt so geschrieben sein wie in der Map.
check "Owner-Vergleich ignoriert Gross-/Kleinschreibung" "$FIRMA" \
  fill "exampleorg/service-api.git"

check "privates Repo bekommt den privaten Token" "$PRIVAT" \
  fill "alice/notes.git"

check "unbekannter Owner faellt auf GITHUB_TOKEN zurueck" "$FALLBACK" \
  fill "fremdorg/repo.git"

# Gegenprobe: die Tokens duerfen nicht gegenseitig auslaufen.
OUT=$(fill "ExampleOrg/service-api.git")
if grep -q "$PRIVAT" <<<"$OUT" || grep -q "$FALLBACK" <<<"$OUT"; then
  fail "Firmen-Anfrage liefert einen fremden Token mit"
else
  pass "Firmen-Anfrage liefert ausschliesslich den Firmen-Token"
fi

# Ohne Zuordnung und ohne Fallback muss der Helper schweigen.
check "ganz ohne Token schweigt der Helper" "TREFFER=0" \
  run bash -c "printf 'protocol=https\nhost=github.com\npath=x/y.git\n\n' \
    | git credential fill 2>/dev/null | grep -c '^password=' | sed 's/^/TREFFER=/'"

exit $FAILED
