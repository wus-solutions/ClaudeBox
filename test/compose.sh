#!/usr/bin/env bash
# Assertions gegen die Compose-Datei und das Tailscale-Sidecar-Image.
# Braucht weder eine .env noch ein Tailnet.
set -uo pipefail

FAILED=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# Platzhalter fuer die Pflichtvariablen, sonst bricht compose config ab.
# Sie ueberdecken eine vorhandene .env - geprueft wird die Datei, nicht die
# Konfiguration.
export TS_HOSTNAME=test TS_AUTHKEY=test BUZZ_RELAY_URL=wss://test BUZZ_ACP_AGENT_OWNER=test

CONFIG=$(docker compose config --format json 2>&1) \
  || { fail "compose config"; printf '%s\n' "${CONFIG:0:400}"; exit 1; }
pass "compose config"

# Mit TS_AUTH_ONCE braucht nur die allererste Anmeldung den Auth-Key. Danach
# soll er aus der Umgebung verschwinden duerfen - Coolify reicht jede Variable
# per env_file auch in den claude-Container, wo der Agent ohne Rueckfrage
# arbeitet. Verlangt die Compose-Datei ihn weiter, startet der Stack ohne nicht.
# --env-file /dev/null: sonst lieferte eine lokale .env den Key doch.
if env -u TS_AUTHKEY docker compose --env-file /dev/null config --quiet >/dev/null 2>&1; then
  pass "der Stack laesst sich ohne TS_AUTHKEY konfigurieren"
else
  fail "ohne TS_AUTHKEY verweigert compose den Start"
fi

echo
echo "== Keine Host-Pfade =="

# Coolify legt fuer einen relativen Bind-Mount nicht die Datei aus dem Repo ab.
# Es biegt ./ auf /data/coolify/applications/<uuid>/ um und legt dort ein
# leeres VERZEICHNIS an. Beim serve.json-Mount las containerboot daraufhin ein
# Verzeichnis, beendete sich mit log.Fatalf, und der claude-Container blieb in
# einem Namespace ohne Netz zurueck - Buzz scheiterte an der DNS-Aufloesung.
# Lokal faellt das nie auf, weil die Datei im Checkout liegt.
BINDS=$(python3 -c '
import sys, json
for name, svc in json.load(sys.stdin)["services"].items():
    for v in svc.get("volumes", []):
        if v.get("type") == "bind":
            print(name + ": " + v["source"] + " -> " + v["target"])
' <<<"$CONFIG")
if [[ -z "$BINDS" ]]; then
  pass "kein Service haengt an einem Host-Pfad"
else
  fail "Bind-Mounts gefunden - unter Coolify werden daraus leere Verzeichnisse"
  sed 's/^/       /' <<<"$BINDS"
fi

# Crontabs liegen unter /var/spool/cron/crontabs. Ohne Volume nimmt jedes
# Deployment sie still mit - der Agent wundert sich dann, warum sein Job nicht
# mehr laeuft.
CRON_VOL=$(python3 -c '
import sys, json
for v in json.load(sys.stdin)["services"]["claude"].get("volumes", []):
    if v.get("target") == "/var/spool/cron/crontabs":
        print(v.get("type"), v.get("source"))
' <<<"$CONFIG")
if [[ "$CRON_VOL" == volume* ]]; then
  pass "Crontabs liegen in einem Volume ($CRON_VOL)"
else
  fail "kein Volume fuer /var/spool/cron/crontabs - Crontabs sind nach dem Deployment weg"
fi

TZ_SET=$(python3 -c \
  'import sys, json; print(json.load(sys.stdin)["services"]["claude"]["environment"].get("TZ", ""))' \
  <<<"$CONFIG")
if [[ -n "$TZ_SET" ]]; then
  pass "Zeitzone ist gesetzt ($TZ_SET) - sonst liefe cron in UTC"
else
  fail "keine TZ im claude-Service - Crontabs feuerten zur falschen Stunde"
fi

echo
echo "== Tailscale-Sidecar =="

TS_ENV=$(python3 -c \
  'import sys, json; e = json.load(sys.stdin)["services"]["tailscale"]["environment"]; print(e.get("TS_HOSTNAME", "")); print(e.get("TS_EXTRA_ARGS", "")); print(e.get("TS_AUTH_ONCE", ""))' \
  <<<"$CONFIG")

# Ohne TS_AUTH_ONCE ruft containerboot bei JEDEM Start "tailscale up --authkey"
# auf. Der Auth-Key ist aber einmalig und nach der ersten Anmeldung verbraucht -
# ein Redeploy scheiterte dann trotz gueltigem Zustand im Volume.
if [[ "$(sed -n 3p <<<"$TS_ENV")" == "true" ]]; then
  pass "TS_AUTH_ONCE: der Auth-Key wird nur ohne Anmeldung benutzt"
else
  fail "TS_AUTH_ONCE fehlt - jeder Start meldet sich mit dem Einmal-Key neu an"
fi

# containerboot haengt --hostname selbst an, sobald TS_HOSTNAME in der Umgebung
# steht. Coolify schreibt jedem Service env_file: .env dazu, TS_HOSTNAME steht
# dort also immer. Ein zweites --hostname in TS_EXTRA_ARGS laesst
# "tailscale up" mit "flag provided multiple times" abbrechen.
if [[ "$(sed -n 1p <<<"$TS_ENV")" == "$TS_HOSTNAME" ]]; then
  pass "TS_HOSTNAME ist im Sidecar gesetzt"
else
  fail "TS_HOSTNAME fehlt im Sidecar - der Node bekaeme den Containernamen"
fi
if grep -q -- '--hostname' <<<"$(sed -n 2p <<<"$TS_ENV")"; then
  fail "TS_EXTRA_ARGS setzt --hostname - doppelt, sobald TS_HOSTNAME in der Umgebung steht"
else
  pass "TS_EXTRA_ARGS setzt kein --hostname"
fi

SERVE_PATH=$(python3 -c \
  'import sys, json; print(json.load(sys.stdin)["services"]["tailscale"]["environment"]["TS_SERVE_CONFIG"])' \
  <<<"$CONFIG")
IMG=$(docker compose config --images tailscale)

docker compose build tailscale >/dev/null 2>&1 \
  || { fail "Sidecar-Image baut"; exit 1; }
pass "Sidecar-Image baut"

if docker run --rm --entrypoint sh "$IMG" -c "test -f '$SERVE_PATH'" >/dev/null 2>&1; then
  pass "TS_SERVE_CONFIG ($SERVE_PATH) ist im Image eine Datei"
else
  fail "TS_SERVE_CONFIG ($SERVE_PATH) ist im Image keine Datei ($IMG)"
fi

# Das Image muss genau die Konfiguration aus dem Repo tragen, nicht irgendeine.
if diff <(docker run --rm --entrypoint cat "$IMG" "$SERVE_PATH" 2>&1) docker/serve.json >/dev/null; then
  pass "serve-Konfiguration im Image entspricht docker/serve.json"
else
  fail "serve-Konfiguration im Image weicht von docker/serve.json ab"
fi

exit $FAILED
