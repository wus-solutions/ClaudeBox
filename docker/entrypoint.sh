#!/usr/bin/env bash
# Docker legt frisch angelegte named volumes als root:root an. Die Mountpoints
# muessen dem Benutzer gehoeren, unter dem die Prozesse laufen - deshalb startet
# der Entrypoint als root und gibt die Rechte ab, bevor supervisord uebernimmt.
set -euo pipefail

# Frisch angelegte named volumes gehoeren root. Jeder Mountpoint, unter dem ein
# Volume haengt, muss dem Benutzer gehoeren, der darin schreibt - sonst kann
# etwa Zed seine Serverkomponente nicht installieren und meldet nur einen
# nichtssagenden Verbindungsfehler.
for d in /workspace /home/dev/.claude /home/dev/.buzz \
         /home/dev/.vscode-server /home/dev/.zed_server \
         /home/dev/.antigravity-ide-server; do
  mkdir -p "$d"
  chown dev:dev "$d"
done

# Globale Claude-Config ins Volume holen (siehe CLAUDE_CONFIG_DIR im
# Dockerfile). Beim ersten Start mit der Variable liegt dort noch keine
# .claude.json - die alte lag im fluechtigen Home und ist mit dem Redeploy weg.
# Claude Code legt aber Sicherungen unter ~/.claude/backups an, und die liegen
# im Volume. Genommen wird die neueste mit Konto: direkt nach einem Neustart
# schreibt Claude auch Sicherungen einer frischen, fast leeren Config.
# Eine vorhandene .claude.json wird nie angetastet.
restore_claude_config() {
  local dir="${CLAUDE_CONFIG_DIR:-/home/dev/.claude}" f
  [[ -e "$dir/.claude.json" ]] && return 0
  [[ -d "$dir/backups" ]] || return 0
  # Die Namen enden auf einen Millisekunden-Zeitstempel; sort -V sortiert
  # danach, unabhaengig von mtimes, die ein Kopieren des Volumes verfaelscht.
  while IFS= read -r f; do
    if grep -q '"oauthAccount"' "$f"; then
      install -m 0600 -o dev -g dev "$f" "$dir/.claude.json"
      echo "Claude-Config: aus Sicherung $(basename "$f") wiederhergestellt" >&2
      return 0
    fi
  done < <(find "$dir/backups" -maxdepth 1 -type f -name '.claude.json.backup.*' | sort -rV)
}
restore_claude_config

# Skills aus dem Image in die Volumes spiegeln. Das geht nicht per COPY im
# Dockerfile, weil die Volumes den Image-Inhalt an diesen Pfaden verdecken.
#
# Es wird nur hineinkopiert, nie geloescht: ein zur Laufzeit angelegter Skill
# bleibt erhalten. Bei Namensgleichheit gewinnt das Image, damit das Verhalten
# nach einem Deploy vorhersagbar ist.
mirror_skills() {  # mirror_skills <quelle> <ziel> <bezeichnung>
  local src="$1" dest="$2" label="$3"
  [[ -d "$src" ]] || return 0
  install -d -o dev -g dev "$dest"
  local n
  n=$(find "$src" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
  if [[ "$n" -gt 0 ]]; then
    cp -R "$src/." "$dest/"
    chown -R dev:dev "$dest"
    echo "$label: $n aus dem Image gespiegelt" >&2
  fi
}

# Beide Quellen landen im selben Ziel: die buzz-cli-Skill ist fuer den Agenten
# eine Claude-Skill wie jede andere. buzz-acp reicht --skill nur an buzz-pi-acp
# durch, nicht an claude-agent-acp - unter ~/.buzz/.agents/skills wuerde sie
# niemand lesen.
mirror_skills /opt/buzz-skills "${SKILLS_DEST:-/home/dev/.claude/skills}" "Buzz-Skills"
mirror_skills "${SKILLS_SRC:-/opt/skills}" "${SKILLS_DEST:-/home/dev/.claude/skills}" "Claude-Skills"
chown -R dev:dev /home/dev/.buzz/.agents 2>/dev/null || true

# Claude-Code-Plugins aus plugins.txt installieren - als dev, ins Volume unter
# ~/.claude. Im Dockerfile geht das nicht: das Volume verdeckt den Image-Inhalt.
# Und als Plugin statt als lose Skills, weil etwa Superpowers einen
# SessionStart-Hook mitbringt und seine Skills einander ueber den
# Plugin-Namen aufrufen.
#
# Bei jedem Start, aber idempotent: ein schon installiertes Plugin kostet zwei
# kurze CLI-Aufrufe. Schlaegt eines fehl - Netz weg, Quelle falsch -, bleibt es
# bei einer Warnung. Terminal und Agent sollen nicht an einem Plugin haengen.
install_plugins() {  # install_plugins <liste>
  local list="$1" id src rest log
  [[ -f "$list" ]] || return 0
  log=$(mktemp)
  while read -r id src rest || [[ -n "$id" ]]; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    # </dev/null: sonst liest claude die restlichen Zeilen der Liste mit.
    if su dev -s /bin/bash -c \
         "timeout 180 claude plugin marketplace add '$src' && timeout 180 claude plugin install '$id'" \
         </dev/null >"$log" 2>&1; then
      echo "Plugin: $id" >&2
    else
      echo "WARNUNG: Plugin $id liess sich nicht installieren (Quelle: ${src:-fehlt})." >&2
      tail -3 "$log" | sed 's/^/         /' >&2
    fi
  done < "$list"
  rm -f "$log"
}

# Im Hintergrund: beim ersten Start klont das den Marketplace, und bei
# haengendem Netz warteten Terminal, SSH und Agent sonst bis zu den Timeouts.
# Ein Agent-Turn in den ersten Sekunden des allerersten Starts laeuft dann noch
# ohne Plugin - danach ist es im Volume und wird nur bestaetigt.
install_plugins "${PLUGINS_FILE:-/opt/plugins.txt}" &

# Commit-Identitaet, damit Commits des Agenten zuordenbar sind. Der Token
# selbst wandert NICHT hierher - den liefert git-credential-github-token aus
# der Umgebung.
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  su dev -s /bin/bash -c "git config --global user.name '${GIT_USER_NAME}'"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  su dev -s /bin/bash -c "git config --global user.email '${GIT_USER_EMAIL}'"
fi

# git verweigert jeden Commit ohne user.email ("Author identity unknown").
# Ohne diese Warnung faellt das erst auf, wenn der Agent mitten in einem
# Buzz-Turn committen will - und die Fehlermeldung landet dann im Kanal.
if [[ -z "${GIT_USER_EMAIL:-}" ]]; then
  echo "WARNUNG: GIT_USER_EMAIL ist nicht gesetzt - der Agent kann nicht committen." >&2
  echo "         git bricht jeden Commit mit 'Author identity unknown' ab." >&2
fi

# Bequemlichkeit: /workspace auch vom Home aus auffindbar machen. Der
# Oeffnen-Dialog der Editoren startet in ~, und dort liegen sonst nur
# versteckte Verzeichnisse - der Container wirkt dann leer, obwohl er es nicht
# ist. -n verhindert, dass der Link bei wiederholtem Start in sich selbst
# zeigt; ein echtes Verzeichnis an dieser Stelle wird nicht angetastet.
if [[ ! -e /home/dev/workspace || -L /home/dev/workspace ]]; then
  ln -sfn /workspace /home/dev/workspace
  chown -h dev:dev /home/dev/workspace
fi

# SSH aufsetzen. sshd laeuft nur, wenn Public Keys hinterlegt sind - eine
# fehlende Variable darf nicht den ganzen Container mitreissen, sondern kostet
# nur den SSH-Zugang. Das Web-Terminal bleibt in jedem Fall erreichbar.
install -d -m 0755 /run/sshd
install -d -m 0700 -o dev -g dev /home/dev/.ssh
rm -f /etc/supervisor/conf.d/sshd.conf

if [[ -n "${SSH_AUTHORIZED_KEYS:-}" ]]; then
  # Host-Schluessel im Volume erzeugen, falls noch keiner da ist. Ohne das
  # wechselt der Fingerabdruck bei jedem Redeploy.
  install -d -m 0700 /etc/ssh/keys
  if [[ ! -f /etc/ssh/keys/ssh_host_ed25519_key ]]; then
    ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/keys/ssh_host_ed25519_key
    echo "SSH: neuen Host-Schluessel erzeugt." >&2
  fi
  chmod 600 /etc/ssh/keys/ssh_host_ed25519_key

  # Mehrere Keys per ';' oder Zeilenumbruch trennen.
  printf '%s\n' "${SSH_AUTHORIZED_KEYS//;/$'\n'}" \
    | sed '/^[[:space:]]*$/d' > /home/dev/.ssh/authorized_keys
  chown dev:dev /home/dev/.ssh/authorized_keys
  chmod 600 /home/dev/.ssh/authorized_keys
  n=$(wc -l < /home/dev/.ssh/authorized_keys | tr -d '[:space:]')

  cat > /etc/supervisor/conf.d/sshd.conf <<'SSHD'
; Erzeugt vom Entrypoint, weil Public Keys hinterlegt sind.
[program:sshd]
command=/usr/sbin/sshd -D -e
user=root
autostart=true
autorestart=true
startsecs=3
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
SSHD
  echo "SSH: aktiv, $n Public Key(s) hinterlegt." >&2
else
  echo "WARNUNG: SSH_AUTHORIZED_KEYS ist leer - sshd bleibt aus." >&2
  echo "         Das Web-Terminal ist davon nicht betroffen." >&2
fi

# Systemzeitzone setzen. TZ als Variable reicht nicht: sie wirkt nur in
# Prozessen, die die Umgebung erben. cron plant nach der Systemzeitzone und
# startet seine Jobs mit LEERER Umgebung - ohne das feuerte "0 8 * * *" um
# 8 Uhr UTC, also um 10 Uhr in Berlin, waehrend im Terminal alles richtig aussah.
# Braucht tzdata aus packages.txt; fehlt die Zone, bleibt es bei UTC.
#
# Dieselbe leere Umgebung kostet einem Cron-Job auch CLAUDE_CONFIG_DIR - "claude
# -p" aus einem Crontab suchte die Anmeldung dann neben dem Volume und faende
# keine. Ueber /etc/environment kommen beide an: cron laedt die Datei per
# pam_env. PATH bleibt davon unberuehrt, den setzt cron selbst auf
# /usr/bin:/bin - Jobs brauchen fuer claude oder buzz eine eigene PATH-Zeile
# im Crontab oder absolute Pfade.
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-/home/dev/.claude}"
sed -i '/^CLAUDE_CONFIG_DIR=/d; /^TZ=/d' /etc/environment 2>/dev/null || touch /etc/environment
printf 'CLAUDE_CONFIG_DIR=%s\n' "$CLAUDE_CFG" >> /etc/environment

if [[ -n "${TZ:-}" ]]; then
  if [[ -f "/usr/share/zoneinfo/$TZ" ]]; then
    ln -sfn "/usr/share/zoneinfo/$TZ" /etc/localtime
    printf '%s\n' "$TZ" > /etc/timezone
    printf 'TZ=%s\n' "$TZ" >> /etc/environment
  else
    echo "WARNUNG: Zeitzone '$TZ' nicht gefunden - alles laeuft in UTC." >&2
    echo "         tzdata fehlt in packages.txt oder der Name ist falsch." >&2
  fi
fi

# cron, aber nur wenn das Paket in packages.txt steht. Ohne laufenden Dienst
# feuert kein Crontab, und ein Eintrag, der nie ausgefuehrt wird, faellt lange
# nicht auf.
#
# Debian erwartet /var/spool/cron/crontabs als root:crontab mit 1730. Ein
# frisches Volume gehoert root:root - "crontab -" meldete dann nur
# "must be suid to work properly".
rm -f /etc/supervisor/conf.d/cron.conf
if [[ -x /usr/sbin/cron ]]; then
  install -d -m 1730 -o root -g crontab /var/spool/cron/crontabs
  cat > /etc/supervisor/conf.d/cron.conf <<'CRON'
; Erzeugt vom Entrypoint, weil cron installiert ist (packages.txt).
[program:cron]
command=/usr/sbin/cron -f -L 2
user=root
autostart=true
autorestart=true
startsecs=3
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
CRON
  echo "cron: aktiv, Crontabs unter /var/spool/cron/crontabs." >&2
fi

# Agenten aufsetzen. BUZZ_AGENTS ordnet Namen auf private Schluessel zu:
#   BUZZ_AGENTS=tuatara=<privkey>,gecko=<privkey>
# Die Schluessel werden als Umgebungsvariablen exportiert und in den erzeugten
# supervisord-Dateien nur referenziert - sie stehen nie auf der Platte.
names=()
if [[ -n "${BUZZ_AGENTS:-}" ]]; then
  IFS=',' read -ra entries <<<"$BUZZ_AGENTS"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    name="${entry%%=*}"
    key="${entry#*=}"
    if [[ -z "$name" || "$name" == "$entry" || -z "$key" ]]; then
      echo "WARNUNG: BUZZ_AGENTS-Eintrag ohne 'name=key' uebersprungen." >&2
      continue
    fi
    var="BUZZ_AGENT_KEY_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
    export "$var=$key"
    names+=("$name")
  done
elif [[ -n "${BUZZ_PRIVATE_KEY:-}" ]]; then
  # Rueckwaertskompatibel: eine einzelne Identitaet ohne BUZZ_AGENTS.
  export BUZZ_AGENT_KEY_DEFAULT="$BUZZ_PRIVATE_KEY"
  names+=("default")
fi

# Owner-Attestierung je Agent (NIP-OA). Ohne sie ist ein Agent fuer Buzz ein
# gewoehnliches Konto: er steht nicht im Agentenverzeichnis der Desktop-App,
# und eine @-Mention zieht ihn nicht in einen Huddle.
#
# Format wie bei GITHUB_TOKENS, ein Eintrag je Agent:
#   BUZZ_AUTH_TAGS=agentname=<signatur>,zweiter=<signatur>
# Der Wert ist nur die Signatur des Owners ueber den Pubkey des Agenten - das
# ganze Tag baut buzz-acp-launch daraus. Erzeugt wird sie auf dem Host mit
#   tools/enroll-agent.py --agent-name <name>
if [[ -n "${BUZZ_AUTH_TAGS:-}" && ${#names[@]} -gt 0 ]]; then
  IFS=',' read -ra entries <<<"$BUZZ_AUTH_TAGS"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    name="${entry%%=*}"
    sig="${entry#*=}"
    if [[ -z "$name" || "$name" == "$entry" || -z "$sig" ]]; then
      echo "WARNUNG: BUZZ_AUTH_TAGS-Eintrag ohne 'name=signatur' uebersprungen." >&2
      continue
    fi
    # Eine kaputte Signatur haengt sonst als ungueltiges Tag an jedem Event.
    if [[ ! "$sig" =~ ^[0-9a-fA-F]{128}$ ]]; then
      echo "WARNUNG: Signatur fuer '$name' sind keine 128 Hex-Zeichen - uebersprungen." >&2
      continue
    fi
    known=0
    for agent in "${names[@]}"; do
      if [[ "$agent" == "$name" ]]; then
        known=1
      fi
    done
    if [[ "$known" -eq 0 ]]; then
      echo "WARNUNG: BUZZ_AUTH_TAGS nennt '$name' - BUZZ_AGENTS kennt den nicht." >&2
      continue
    fi
    var="BUZZ_AUTH_SIG_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
    export "$var=$sig"
  done
fi

if [[ -n "${BUZZ_AUTH_TAGS:-}" && -z "${BUZZ_ACP_AGENT_OWNER:-}" ]]; then
  echo "WARNUNG: BUZZ_AUTH_TAGS ist gesetzt, BUZZ_ACP_AGENT_OWNER aber leer." >&2
  echo "         Ohne Owner-Pubkey entsteht kein Tag - die Agenten laufen ohne." >&2
fi

# Optional: Zugangsdaten je Agent fuer Cron-Jobs ablegen. Cron startet Jobs mit
# leerer Umgebung, ohne BUZZ_*-Variablen scheitert "buzz messages send" still.
#
# Bewusst ein Schalter und kein Default: Damit liegt der Schluessel lesbar im
# Dateisystem, und das widerspricht der Zusicherung aus dem README, dass
# Geheimnisse nur in der Prozessumgebung stehen. Unter /run/buzz, weil
# docker-compose.yml dort ein tmpfs einhaengt - RAM statt Platte. Das
# Verzeichnis bekommt 0750 root:dev, nicht nur die Datei: ein tmpfs kommt
# standardmaessig mit 1777.
#
# Format: schlichte KEY=wert-Zeilen ohne export, damit ein Job sie mit
#   set -a; . /run/buzz/<name>.env; set +a
# in einem Schritt laedt.
if [[ -n "${CRON_SECRETS:-}" && "${CRON_SECRETS}" != "0" && "${CRON_SECRETS}" != "false" ]]; then
  if [[ ${#names[@]} -gt 0 ]]; then
    install -d -m 0750 -o root -g dev /run/buzz
    for name in "${names[@]}"; do
      suffix="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')"
      var="BUZZ_AGENT_KEY_$suffix"
      sigvar="BUZZ_AUTH_SIG_$suffix"
      umask 027
      {
        printf 'BUZZ_RELAY_URL=%s\n' "${BUZZ_RELAY_URL:-}"
        printf 'BUZZ_PRIVATE_KEY=%s\n' "${!var:-}"
        # In einfachen Anfuehrungszeichen, damit "set -a; . datei" die
        # doppelten im JSON nicht wegwirft.
        if [[ -n "${!sigvar:-}" && -n "${BUZZ_ACP_AGENT_OWNER:-}" ]]; then
          printf "BUZZ_AUTH_TAG='[\"auth\",\"%s\",\"\",\"%s\"]'\n" \
            "$BUZZ_ACP_AGENT_OWNER" "${!sigvar}"
        fi
      } > "/run/buzz/$name.env"
      umask 022
      chown root:dev "/run/buzz/$name.env"
      chmod 0640 "/run/buzz/$name.env"
    done
    echo "CRON_SECRETS: Zugangsdaten unter /run/buzz/<agent>.env (tmpfs, 0640 root:dev)." >&2
  fi
fi

if [[ ${#names[@]} -eq 0 ]]; then
  echo "WARNUNG: kein Agent konfiguriert - BUZZ_AGENTS ist leer." >&2
  echo "         Das Web-Terminal laeuft trotzdem." >&2
else
  /usr/local/bin/render-agents.py "${names[@]}"
fi

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
