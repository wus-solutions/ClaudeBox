# Tailscale-Sidecar mit eingebauter serve-Konfiguration.
#
# Die Datei liegt im Image statt als Bind-Mount. Coolify legt fuer einen
# relativen Bind-Mount ein leeres Verzeichnis auf dem Host an; containerboot
# liest TS_SERVE_CONFIG dann als Verzeichnis, beendet sich mit log.Fatalf, und
# der claude-Container bleibt in einem Namespace ohne Netz zurueck.
#
# Bewusst ohne --platform - siehe docker-compose.yml.
FROM ghcr.io/tailscale/tailscale:stable
COPY serve.json /config/serve.json
