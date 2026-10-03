#!/usr/bin/env bash
# Assertions gegen den laufenden Compose-Stack. Erwartet eine ausgefuellte .env.
set -uo pipefail

FAILED=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
check() {
  local desc="$1" expect="$2"; shift 2
  local out; out=$("$@" 2>&1)
  if [[ "$out" == *"$expect"* ]]; then pass "$desc"; else
    fail "$desc"; printf '       erwartet: %s\n       erhalten: %s\n' "$expect" "${out:0:400}"
  fi
}

[[ -f .env ]] || { echo "FEHLER: .env fehlt. Siehe .env.example."; exit 1; }
TS_HOSTNAME=$(grep -E '^TS_HOSTNAME=' .env | cut -d= -f2-)
[[ -n "${TS_HOSTNAME:-}" ]] || { echo "FEHLER: TS_HOSTNAME ist leer."; exit 1; }
# Der Key wird nur fuer die erste Anmeldung gebraucht; mit bestehendem
# tailscale-state-Volume darf er fehlen.
grep -qE '^TS_AUTHKEY=tskey-' .env \
  || echo "HINWEIS: kein TS_AUTHKEY - funktioniert nur, wenn der Node schon angemeldet ist."

# Der Agentenname steht nicht fest: er kommt aus BUZZ_AGENTS, und die
# Agentendateien heissen entsprechend. agents/AGENT_NAME.md ist nur die
# Vorlage. Geprueft wird der erste Eintrag der Liste.
AGENT=$(grep -E '^BUZZ_AGENTS=' .env | cut -d= -f2- | cut -d, -f1 | cut -d= -f1)
[[ -n "${AGENT:-}" ]] || { echo "FEHLER: BUZZ_AGENTS ist leer - es gibt keinen Agenten zu pruefen."; exit 1; }

echo "== Stack startet =="
docker compose up -d --build >/dev/null 2>&1 || { fail "compose up"; exit 1; }
pass "compose up"

echo -n "  ... warte auf Tailnet-Anmeldung "
for _ in $(seq 1 60); do
  docker compose exec -T tailscale tailscale status 2>/dev/null | grep -q "$TS_HOSTNAME" && break
  echo -n "."; sleep 2
done
echo

echo
echo "== Netzwerk-Topologie =="

# Die zentrale Zusicherung des Designs: der claude-Container besitzt keinen
# eigenen Netzwerk-Namespace, sondern den des tailscale-Containers.
# Ein Container mit network_mode: service:... hat KEINE eigenen
# NetworkSettings - SandboxKey ist dort leer, nicht identisch. Die Bindung
# steht in HostConfig.NetworkMode als "container:<id>".
TS_ID=$(docker compose ps -q tailscale)
CL_MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$(docker compose ps -q claude)" 2>/dev/null)
if [[ -n "$TS_ID" && "$CL_MODE" == "container:$TS_ID" ]]; then
  pass "claude teilt den Netzwerk-Namespace von tailscale"
else
  fail "claude haengt nicht am tailscale-Namespace (NetworkMode=$CL_MODE)"
fi

# Der ID-Vergleich oben reicht nicht: ein "docker compose restart tailscale"
# laesst die ID unveraendert, zerreisst aber den tatsaechlichen Namespace -
# der claude-Container haengt dann an einem toten. Deshalb wird hier geprueft,
# ob das Loopback wirklich geteilt wird: der tailscale-Container muss die
# Dienste des claude-Containers auf 127.0.0.1 erreichen.
# Mit Wiederholung, denn nach einem Rebuild braucht ttyd ein paar Sekunden.
# Eine Assertion, die je nach Timing fehlschlaegt, ist schlimmer als keine -
# man gewoehnt sich an rotes Rauschen und uebersieht den echten Befund.
NS_OK=0
for _ in $(seq 1 30); do
  if docker compose exec -T tailscale sh -c \
       'wget -q -T 3 -O /dev/null http://127.0.0.1:7681/ 2>/dev/null' 2>/dev/null; then
    NS_OK=1; break
  fi
  sleep 2
done
if [[ "$NS_OK" == "1" ]]; then
  pass "tailscale erreicht ttyd auf dem geteilten Loopback"
else
  fail "tailscale erreicht ttyd NICHT - der Namespace ist zerrissen"
  echo "       Abhilfe: docker compose restart claude" >&2
fi

# Kein Port darf auf dem Host veroeffentlicht sein.
PUBLISHED=$(docker compose ps --format '{{.Ports}}' 2>/dev/null | tr -d '[:space:]')
if [[ -z "$PUBLISHED" ]]; then
  pass "kein Port auf dem Host veroeffentlicht"
else
  fail "Ports veroeffentlicht: $PUBLISHED"
fi

# Gegenprobe vom Host aus: der Tailnet-Port darf lokal nicht erreichbar sein.
if curl -s -m 3 -o /dev/null http://127.0.0.1:7681/ 2>/dev/null; then
  fail "ttyd ist vom Host aus auf 127.0.0.1:7681 erreichbar"
else
  pass "ttyd ist vom Host aus nicht erreichbar"
fi

echo
echo "== Tailscale =="
check "Tailnet-Verbindung steht" "$TS_HOSTNAME" \
  docker compose exec -T tailscale tailscale status

check "serve-Konfiguration aktiv" "7681" \
  docker compose exec -T tailscale tailscale serve status

echo
echo "== Web-Terminal ueber den Namespace =="
# supervisord meldet buzz-acp erst nach startsecs=10 als RUNNING, und ttyd
# braucht seinerseits ein paar Sekunden. Ohne dieses Warten misst der Test
# einen Startvorgang statt eines Zustands.
echo -n "  ... warte auf die Dienste im claude-Container "
for _ in $(seq 1 45); do
  st=$(docker compose exec -T claude supervisorctl status 2>/dev/null)
  if ! grep -qE 'STARTING|BACKOFF' <<<"$st" && grep -q 'RUNNING' <<<"$st"; then break; fi
  echo -n "."; sleep 2
done
echo

check "ttyd erreichbar" "200" \
  docker compose exec -T claude bash -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7681/'

echo
echo "== Buzz-Agent =="
check "Agent $AGENT laeuft" "buzz-acp-$AGENT" \
  docker compose exec -T claude supervisorctl status

check "Agent ist nicht in einer Neustart-Schleife" "RUNNING" \
  docker compose exec -T claude supervisorctl status "buzz-acp-$AGENT"

check "Relay-URL ist im Container gesetzt" "$(grep -E '^BUZZ_RELAY_URL=' .env | cut -d= -f2-)" \
  docker compose exec -T claude bash -c 'echo $BUZZ_RELAY_URL'

# owner-only ist das Gate, das verhindert, dass Fremde den Agenten steuern.
# Der Gate-Modus ist bewusst konfigurierbar (owner-only, allowlist, nobody).
# Geprueft wird deshalb die Sicherheitseigenschaft, nicht ein fester Wert:
# kein Agent darf auf "anyone" stehen, und ein Gate muss ueberhaupt gesetzt
# sein - sonst koennte ein Fremder einen Agenten mit Schreibzugriff auf
# /workspace und gueltigen GitHub-Tokens steuern.
GATES=$(docker compose exec -T claude bash -c \
  'grep -h "BUZZ_ACP_RESPOND_TO=" /etc/supervisor/conf.d/agent-*.conf' 2>&1)
NAGENTS=$(docker compose exec -T claude bash -c \
  'ls /etc/supervisor/conf.d/agent-*.conf 2>/dev/null | wc -l' 2>&1 | tr -d "[:space:]")
if grep -q '"anyone"' <<<"$GATES"; then
  fail "ein Agent antwortet jedem (respond_to: anyone)"
  sed 's/^/       /' <<<"$GATES"
elif [[ "$(grep -c 'BUZZ_ACP_RESPOND_TO=' <<<"$GATES")" -lt "${NAGENTS:-1}" ]]; then
  fail "nicht jeder Agent hat ein respond_to gesetzt ($NAGENTS Agenten)"
  sed 's/^/       /' <<<"$GATES"
else
  pass "jeder Agent hat ein einschraenkendes respond_to ($NAGENTS Agenten)"
fi

# Ohne diese Skill kann der Agent nicht in Buzz antworten. buzz-acp rollt sie
# nicht aus, deshalb liegt sie im Image.
check "buzz-cli-Skill ist vorhanden" "buzz-cli" \
  docker compose exec -T claude ls /home/dev/.claude/skills/

# Die echte plugins.txt, mit Netz - test/image.sh prueft nur den Mechanismus.
check "Superpowers-Plugin ist fuer dev installiert" "superpowers@claude-plugins-official" \
  docker compose exec -T --user dev claude claude plugin list


if grep -qE '^SSH_AUTHORIZED_KEYS=.+' .env; then
  echo
  echo "== SSH =="
  check "sshd laeuft" "sshd" \
    docker compose exec -T claude supervisorctl status
  check "TCP-Forwarder auf 22 ist eingerichtet" "tcp://" \
    docker compose exec -T tailscale tailscale serve status
  # Auch hier zaehlt das geteilte Loopback, nicht nur die Konfiguration.
  if docker compose exec -T tailscale sh -c \
       'nc -z -w 5 127.0.0.1 22 2>/dev/null || timeout 5 sh -c "echo > /dev/tcp/127.0.0.1/22"' 2>/dev/null; then
    pass "tailscale erreicht sshd auf dem geteilten Loopback"
  else
    fail "tailscale erreicht sshd nicht"
  fi
fi

echo
echo "Tailnet-Adresse:"
docker compose exec -T tailscale tailscale status --json 2>/dev/null \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  https://" + d["Self"]["DNSName"].rstrip("."))' 2>/dev/null \
  || echo "  (konnte DNS-Namen nicht ermitteln)"

exit $FAILED
