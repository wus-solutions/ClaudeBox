# syntax=docker/dockerfile:1.7
# Alle Stages sind linux/amd64: die Buzz-Binaries gibt es nur fuer diese Architektur.

ARG BUZZ_VERSION=0.5.20
ARG BUZZ_DEB_SHA256=sha256:55c7de42bc196aed69597b01c25b3daf78aa8840f0f33174d7534e87cac71424

FROM --platform=linux/amd64 debian:trixie-slim AS buzz-binaries
ARG BUZZ_VERSION
ARG BUZZ_DEB_SHA256

# Das Release-Asset ist die Desktop-App; wir brauchen nur die CLI-Binaries daraus.
# Deren deklarierte Abhaengigkeiten (libwebkit2gtk, libgtk-3) gelten der GUI und
# werden hier bewusst ignoriert - buzz-acp braucht nur libc, libgcc_s und libm.
ADD --checksum=${BUZZ_DEB_SHA256} \
    https://github.com/block/buzz/releases/download/desktop-v${BUZZ_VERSION}/Buzz_${BUZZ_VERSION}_amd64.deb \
    /tmp/buzz.deb

RUN dpkg-deb -x /tmp/buzz.deb /tmp/buzz \
 && mkdir -p /out \
 && cp /tmp/buzz/usr/bin/buzz \
       /tmp/buzz/usr/bin/buzz-acp \
       /tmp/buzz/usr/bin/buzz-agent \
       /tmp/buzz/usr/bin/git-credential-nostr \
       /out/ \
 && chmod 0755 /out/* \
 && rm -rf /tmp/buzz /tmp/buzz.deb

FROM --platform=linux/amd64 node:22-trixie-slim AS runtime

# Der Autoupdater kann als nicht-root nicht nach /usr/local schreiben und wuerde
# bei jedem Start scheitern; Versionswechsel laufen ueber einen Image-Rebuild.
#
# CLAUDE_CONFIG_DIR: Claude Code legt seine globale Config sonst als
# ~/.claude.json NEBEN das Volume ~/.claude - ins fluechtige Container-
# Dateisystem. Darin stehen Konto und Onboarding-Status; ohne sie beginnt
# Claude nach jedem Redeploy mit Einrichtung und Login von vorn, obwohl die
# Credentials im Volume ueberlebt haben. Mit der Variable liegt die Datei im
# Volume. Fuer SSH-Sitzungen setzt sshd_config sie noch einmal.
ENV DISABLE_AUTOUPDATER=1 \
    HOME=/home/dev \
    LANG=C.UTF-8 \
    CLAUDE_CONFIG_DIR=/home/dev/.claude

# Leere Defaults, damit supervisord seine Config auch dann expandieren kann,
# wenn die Buzz-Variablen fehlen. Ohne sie stirbt supervisord komplett - und
# reisst ttyd mit, also genau das Terminal, mit dem man den Fehler suchen
# wuerde. Compose ueberschreibt diese Werte.
ENV BUZZ_RELAY_URL="" \
    BUZZ_PRIVATE_KEY="" \
    BUZZ_ACP_AGENT_OWNER="" \
    BUZZ_AGENTS="" \
    GITHUB_TOKEN="" \
    GITHUB_TOKENS="" \
    GIT_USER_NAME="" \
    GIT_USER_EMAIL="" \
    SSH_AUTHORIZED_KEYS=""

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      iproute2 \
      less \
      openssh-server \
      procps \
      ripgrep \
      sudo \
      supervisor \
      tmux \
      wget \
 && rm -rf /var/lib/apt/lists/*

# Das Basis-Image belegt uid 1000 mit dem Benutzer "node". Wir wollen dieselbe
# uid fuer "dev", damit Volume-Ownership zu einem typischen Host-Benutzer passt.
# useradd legt das Konto ohne Passwort an, was in /etc/shadow ein "!" ergibt -
# also gesperrt. OpenSSH weist gesperrte Konten bei UsePAM no als "invalid user"
# ab, auch bei Schluessel-Authentifizierung. "*" heisst dagegen: kein Passwort-
# Login moeglich, aber das Konto ist nicht gesperrt.
RUN userdel -r node \
 && useradd --create-home --uid 1000 --shell /bin/bash dev \
 && usermod -p '*' dev

# dev darf per sudo root werden, ohne Passwort - das Konto hat ohnehin keins
# (siehe oben). Noetig, damit Claude im Container Pakete nachinstallieren und
# Systemdateien anpassen kann. Die Abschottung haengt am Tailnet, nicht daran,
# dass dev kein root werden kann. visudo -c bricht den Build ab, falls die
# Regel syntaktisch kaputt ist - ein kaputtes sudoers sperrt sudo komplett.
RUN echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev \
 && visudo -c

RUN npm install --global --no-fund --no-audit \
      @anthropic-ai/claude-code \
      @agentclientprotocol/claude-agent-acp \
 && npm cache clean --force

ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256=sha256:8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55

# ttyd ist in Debian Trixie nicht paketiert. Das Release-Binary ist statisch
# gelinkt und damit unabhaengig von der libc des Basis-Images.
ADD --checksum=${TTYD_SHA256} \
    https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64 \
    /usr/local/bin/ttyd

COPY --from=buzz-binaries /out/ /usr/local/bin/
COPY docker/sshd_config /etc/ssh/sshd_config
COPY docker/supervisord.conf /etc/supervisor/supervisord.conf
COPY docker/entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY docker/git-credential-github-token /usr/local/bin/git-credential-github-token
COPY docker/render-agents.py /usr/local/bin/render-agents.py
# Der Buzz-Agent laeuft ohne Terminal; agent-watch folgt seinem Transkript.
COPY docker/agent-watch      /usr/local/bin/agent-watch
COPY agents/ /opt/agents/
COPY skills/ /opt/skills/
# Installiert der Entrypoint beim Start ins Volume - siehe dort.
COPY plugins.txt /opt/plugins.txt

# Systemweit registriert, damit es keine Rolle spielt, welcher Prozess klont.
# Der Helper no-opt, wenn GITHUB_TOKEN leer ist - die Registrierung schadet
# also nicht, wenn kein Token hinterlegt wurde.
# useHttpPath reicht dem Helper den Pfad durch. Ohne das saehe er nur
# "github.com" und koennte private von Firmen-Repos nicht unterscheiden -
# ein Fine-grained Token gilt aber immer nur fuer einen Resource Owner.
RUN chmod 0755 /usr/local/bin/git-credential-github-token \
 && git config --system credential."https://github.com".helper github-token \
 && git config --system credential."https://github.com".useHttpPath true

# buzz-acp rollt die buzz-cli-Skill nicht selbst aus - lokal macht das die
# Desktop-App, die es hier nicht gibt. Ohne sie weiss der Agent zwar, dass er
# angesprochen wurde, aber nicht, wie er ueber das buzz-CLI zurueckschreibt.
#
# Sie liegt bewusst NICHT unter /home/dev/.buzz: dort haengt ein Volume, das
# den Image-Inhalt verdecken wuerde. Der Entrypoint synchronisiert sie bei
# jedem Start hinein - so zieht ein Image-Update die Skill mit.
COPY docker/skills/ /opt/buzz-skills/

RUN chmod 0755 /usr/local/bin/ttyd /usr/local/bin/entrypoint.sh /usr/local/bin/render-agents.py \
               /usr/local/bin/agent-watch \
 && mkdir -p /workspace /home/dev/.claude /home/dev/.buzz \
              /home/dev/.vscode-server /home/dev/.zed_server \
              /home/dev/.antigravity-ide-server \
 && chown -R dev:dev /workspace /home/dev

# Bewusst als LETZTE Schicht: eine Aenderung an der Liste soll nur diesen
# Schritt neu bauen, nicht npm und apt darueber. Kommentare und Leerzeilen
# werden entfernt, eine leere Liste ist erlaubt.
COPY packages.txt /opt/packages.txt
RUN PKGS="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /opt/packages.txt | tr '\n' ' ')" \
 && if [ -n "$PKGS" ]; then \
      apt-get update \
   && apt-get install -y --no-install-recommends $PKGS \
   && rm -rf /var/lib/apt/lists/*; \
    fi

# Der Entrypoint startet als root, um Volume-Ownership zu setzen; die
# eigentlichen Prozesse laufen laut supervisord.conf als dev.
WORKDIR /workspace
EXPOSE 7681
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
