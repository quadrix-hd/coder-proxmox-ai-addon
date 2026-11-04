# Gemeinsame Helfer fuer die Proxmox-API-Skripte. Wird per "source" von
# find_free_ip.sh, get_cluster_load.sh und allocate_sdn_ip.sh eingebunden,
# kein eigenstaendig ausfuehrbares Skript.

# curl_retry: wie curl, aber mit Retry (exponentielles Backoff) bei
# transienten Verbindungsfehlern - relevant z.B. direkt nach einem
# Proxmox-Host-Neustart, wenn die API noch ein paar Sekunden braucht, bis
# sie wieder sauber antwortet. Terraform wertet diese Skripte als "external"
# Data Sources bei JEDEM Apply neu aus (auch beim blossen Start/Stop eines
# laengst bestehenden Workspaces, nicht nur bei der Erstellung) - ein
# kurzer API-Hänger wuerde sonst jeden Start eines beliebigen Workspaces
# scheitern lassen, nicht nur Neuanlagen.
#
# Nur echte Verbindungsfehler werden wiederholt (curl exit codes 6/7/28/35/
# 52/56 = DNS/Connect/Timeout/TLS/Empty-Reply/Receive-Error). Ein HTTP-
# Fehler (curl -f -> exit 22, z.B. 401/403/500) wird NICHT wiederholt, da
# der naechste Versuch denselben Fehler liefern wuerde - der liegt an
# Credentials/Berechtigungen, nicht an einer kurzzeitigen Nichterreichbarkeit.
curl_retry() {
  local max_attempts=5
  local delay=2
  local attempt=1
  local rc

  while true; do
    curl "$@"
    rc=$?
    [ "$rc" -eq 0 ] && return 0

    case "$rc" in
      6 | 7 | 28 | 35 | 52 | 56) ;; # transient - weiter unten retryn
      *) return "$rc" ;;
    esac

    if [ "$attempt" -ge "$max_attempts" ]; then
      return "$rc"
    fi

    echo "curl-Verbindungsfehler (exit $rc), Versuch $attempt/$max_attempts, naechster Versuch in ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}
