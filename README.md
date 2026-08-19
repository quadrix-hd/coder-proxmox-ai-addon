# Coder + Claude Code auf Proxmox (LXC)

Ein Coder-Template, das pro Task automatisch einen Proxmox-LXC-Workspace mit Claude Code erstellt — authentifiziert über einen Claude Pro/Max-Abo OAuth-Token (kein API-Key nötig), inklusive Demo-Webseiten-Button, Größen-Presets, Automatik-Modus und Multi-Node-Unterstützung.

## Was das Template macht

- Erstellt bei jedem neuen Task automatisch einen frischen Proxmox-LXC-Container
- Installiert und startet Claude Code darin, authentifiziert mit deinem **Pro/Max-Abo** (nicht pay-per-token)
- Bietet einen **Demo-Webseiten-Button**, um im Workspace erstellte Webseiten direkt anzusehen
- Größen-Presets (Klein/Mittel/Groß) und ein **Automatik-Modus** (Claude arbeitet ohne Rückfragen)
- **Persistent**: Stop/Start löscht den Container nicht mehr — Daten bleiben erhalten
- Optional: Wahl zwischen mehreren Proxmox-Nodes bei der Erstellung (Cluster-Setup)

## Voraussetzungen

- Ein laufender **Coder-Server** (Docker, siehe [offizielle Coder-Doku](https://coder.com/docs))
- **Proxmox VE** (Single-Node oder Cluster)
- Ein **Claude Pro oder Max Abo** (für den OAuth-Token)
- Grundkenntnisse in Terraform/Proxmox

---

## 1. Proxmox vorbereiten

### 1.1 API-Token erstellen

In der Proxmox-Weboberfläche:

1. **Datacenter → Permissions → API Tokens → Add**
2. User: `root@pam`, Token-ID: `terraform`
3. **"Privilege Separation" deaktivieren** (wichtig — sonst funktionieren API-Calls nicht ohne zusätzliche ACL-Einträge)
4. Secret sicher notieren (wird nur einmal angezeigt)

Alternativ per CLI auf dem Proxmox-Host:

```bash
pveum user token add root@pam terraform --privsep 0
```

### 1.2 Template-Container vorbereiten (VMID 9000)

Dies ist die Vorlage, aus der jeder Workspace-Container geklont wird. Sie braucht einen SSH-Server, damit Coder sich verbinden kann.

```bash
pveam update
pveam available | grep ubuntu
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst

pct create 9000 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname template-builder \
  --cores 1 --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs local-lvm:4 \
  --unprivileged 1 \
  --features nesting=1

pct start 9000
pct exec 9000 -- bash -c "apt-get update && apt-get install -y openssh-server curl sudo"
pct exec 9000 -- sed -i 's/#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
pct exec 9000 -- systemctl enable ssh
pct stop 9000
pct set 9000 --template 1
```

> **Bekannter Bug:** Das native `clone`-Attribut des `telmate/proxmox`-Providers ist fehlerhaft ("vm not found", GitHub Issue offen). Deshalb wird stattdessen ein Backup-Archiv erstellt und über `ostemplate` referenziert:

```bash
vzdump 9000 --mode stop --compress zstd --dumpdir /var/lib/vz/dump
cp /var/lib/vz/dump/vzdump-lxc-9000-*.tar.zst /var/lib/vz/template/cache/ubuntu-ssh-ready.tar.zst
```

---

## 2. SSH-Key für den Coder-Container

Der Coder-Server-Container braucht einen SSH-Key, um sich mit neu erstellten LXCs zu verbinden.

Auf dem Docker-Host (wo Coder läuft):

```bash
ssh-keygen -t rsa -b 4096 -f ~/coder-ssh-key -N ""
```

Herausfinden, als welcher User/UID der Coder-Container läuft:

```bash
docker exec -it coder-coder-1 id
```

Rechte entsprechend anpassen (Beispiel für UID 1000):

```bash
chown 1000:1000 ~/coder-ssh-key ~/coder-ssh-key.pub
chmod 600 ~/coder-ssh-key
chmod 644 ~/coder-ssh-key.pub
```

In deiner `docker-compose.yaml` beim `coder`-Service ergänzen:

```yaml
services:
  coder:
    volumes:
      - ~/coder-ssh-key:/home/coder/.ssh/id_rsa
      - ~/coder-ssh-key.pub:/home/coder/.ssh/id_rsa.pub
```

Danach: `docker compose up -d`

---

## 3. Netzwerk / Firewall

Falls deine Proxmox-LXCs in einem eigenen, isolierten VLAN laufen (empfohlen), muss der Coder-Server sie erreichen können — und umgekehrt.

**Benötigte Firewall-Regeln** (Beispiel UniFi, gilt sinngemäß für jede Firewall):

| Reihenfolge | Regel | Quelle | Ziel | Port | Aktion |
|---|---|---|---|---|---|
| 1 | Docker→Workspace-VLAN | Docker-Host-IP | Workspace-VLAN | 22 | Zulassen |
| 2 | Workspace-VLAN→Docker | Workspace-VLAN | Docker-Host-IP | 22, 7080 | Zulassen |
| 3 | Workspace-VLAN Isolation | Workspace-VLAN | Beliebig | Beliebig | Blockieren |

**Wichtig:** Die Reihenfolge muss exakt so sein — Allow-Regeln müssen vor der allgemeinen Block-Regel stehen, sonst greifen sie nie.

> **Bekanntes Problem:** Neue LXC-Container können nach dem ersten Boot mehrere Minuten brauchen, bis sie zuverlässig erreichbar sind (vermutlich Switch-seitige Verzögerung, wenn eine neue MAC-Adresse zum ersten Mal auftaucht — sogenanntes Spanning-Tree-Forwarding-Delay). Der SSH-Provisioner-Timeout im Template ist deshalb auf 10 Minuten gesetzt. Falls möglich, PortFast/Edge-Port am betroffenen Switch-Port aktivieren, um das zu beheben.

---

## 4. Claude Code OAuth-Token generieren

Auf deinem lokalen Rechner (nicht auf dem Server):

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude
/login
claude setup-token
```

Der Token beginnt mit `sk-ant-oat...` — sicher notieren, du brauchst ihn für jeden Template-Push.

---

## 5. Template konfigurieren und ausrollen

### 5.1 Repo klonen

```bash
git clone https://github.com/DEIN-USERNAME/DEIN-REPO.git
cd DEIN-REPO
```

### 5.2 Werte anpassen

In `main.tf` folgende Defaults auf deine Umgebung anpassen:

| Variable | Wo | Was |
|---|---|---|
| `pm_api_url` | `variable "pm_api_url"` | Deine Proxmox-API-URL, z. B. `https://192.168.1.10:8006/api2/json` |
| `target_node` | `variable "target_node"` | Dein Proxmox-Node-Name |
| `lxc_subnet`, `lxc_gateway`, `lxc_vlan_tag` | jeweilige Variablen | Dein Netzwerk für die Workspaces |

Falls du **zwei Proxmox-Nodes** (Cluster) hast und die Node-Auswahl nutzen willst: in `scripts/get_cluster_load.sh` die Variablen `PREFERRED_NODE` und `FAILOVER_NODE` sowie in `main.tf` alle `"pve"`/`"pve4"`-Vorkommen auf deine echten Node-Namen anpassen.

### 5.3 Coder CLI installieren und einloggen

```bash
curl -fsSL https://coder.com/install.sh | sh
coder login https://deine-coder-url.de
```

### 5.4 Template pushen

```bash
coder templates push lxc-claude-task -d . \
  --variable pm_api_token_id='root@pam!terraform' \
  --variable pm_api_token_secret='DEIN-PROXMOX-TOKEN-SECRET' \
  --variable claude_code_oauth_token='DEIN-CLAUDE-OAUTH-TOKEN' \
  --variable lxc_subnet='10.0.75' \
  --variable lxc_gateway='10.0.75.1' \
  --variable lxc_vlan_tag='75'
```

> **Wichtig:** Alle Variablen müssen bei **jedem** Push explizit mitgegeben werden — Coder speichert sonst stillschweigend den zuletzt genutzten Wert weiter, auch wenn sich der Default in `main.tf` geändert hat.

---

## 6. Nutzung

### Neuen Workspace mit Webseite erstellen

1. Coder-Dashboard → **Tasks** → Template auswählen
2. Preset wählen (Größe + mit/ohne Rückfragen + ggf. Node)
3. Prompt eingeben, z. B.:
   > Erstelle eine moderne Landingpage für [Branche/Thema]. Entwirf Struktur, Inhalte und Design selbst. Deploye mit Docker (nginx:alpine), festes Port-Mapping -p 8080:80.
4. Start klicken

### Wichtig für den Demo-Button

Der Demo-Button erwartet die Webseite auf **Port 8080** (`localhost:8080` im Workspace). Immer explizit "festes Port-Mapping 8080:80" ins Prompt schreiben, sonst vergibt Docker einen zufälligen Port und der Button funktioniert nicht.

### Workspace stoppen/löschen

- **Stoppen/Neustarten**: über die Coder-UI — der Container bleibt erhalten, keine Datenverluste
- **Endgültig löschen**: über die Coder-UI löschen (nicht nur stoppen), sonst bleibt der Proxmox-Container bestehen
- Beim Löschen **nicht** "Orphan"/"Skip resource cleanup" ankreuzen, falls diese Option erscheint

---

## Template-Struktur

```
.
├── main.tf                       Haupt-Template
├── watchdog.sh.tftpl              Hält Claude Code/agentapi zuverlässig am Laufen
└── scripts/
    ├── find_free_ip.sh            Automatische IP-Zuweisung im VLAN
    └── get_cluster_load.sh        Live-Auslastungsanzeige für Multi-Node-Auswahl
```

### Wichtige Design-Entscheidungen

**Coder-Agent als systemd-Service statt direktem SSH-Aufruf**
Der Agent läuft als eigener systemd-Service mit `Restart=always`, statt direkt über den SSH-Provisioner gestartet zu werden — das verhindert, dass die Terraform-Verbindung dauerhaft blockiert (der Agent läuft ja permanent im Vordergrund).

**Watchdog für Claude Code**
Der automatische Boot-Start von `agentapi` (dem Wrapper, der Claude Code in die Coder-Web-UI einbettet) hat keinen eingebauten Neustart-Mechanismus. Ein Cronjob prüft `localhost:3284/status` jede Minute und startet bei Bedarf neu.

**Persistenz statt Neu-Erstellung**
Ursprünglich löschte `count = data.coder_workspace.me.start_count` den kompletten Container bei jedem Stop und erstellte bei Start einen neuen. Das ist jetzt behoben: `count` wurde entfernt, `start` steuert nur noch den Power-Status, `lifecycle.ignore_changes` verhindert ungewollte Neuerstellung durch IP-/Template-Änderungen.

**`coder_parameter` vs. `coder_workspace_preset`**
Der Tasks-Flow (AI-Prompt-Textfeld) zeigt keine rohen `coder_parameter`-Werte an (offizielles Coder-Verhalten). Größen- und Modus-Auswahl läuft deshalb über `coder_workspace_preset`-Blöcke (Achtung: `data`-Block, nicht `resource`).

---

## Troubleshooting

| Symptom | Wahrscheinliche Ursache | Fix |
|---|---|---|
| SSH-Timeout beim Erstellen | Netzwerk-/Switch-Verzögerung beim ersten Boot | Warten, ggf. Timeout im Template erhöhen |
| `agentapi` 502 in Web-UI | Watchdog hat noch nicht gegriffen | 1–2 Min. warten, Cron läuft jede Minute |
| Claude fragt nach Login | OAuth-Token fehlt/falsch im Watchdog | Token in `watchdog.sh.tftpl` prüfen |
| "Invalid host header" | `AGENTAPI_ALLOWED_HOSTS` fehlt | Im Watchdog-Skript gesetzt, prüfen |
| Demo-Button ausgegraut | `subdomain = true` ohne Wildcard-DNS konfiguriert | Auf `subdomain = false` setzen |
| "vm not found" beim Erstellen | Bekannter Bug im `clone`-Attribut des Providers | `ostemplate` statt `clone` verwenden |
| Claude Code installiert nicht / `ECONNREFUSED downloads.claude.ai` | Kurzzeitiger Netzwerk-Hänger, oft bei parallel erstellten Workspaces | Manuell nachinstallieren: `curl -fsSL https://claude.ai/install.sh -o /tmp/i.sh && bash /tmp/i.sh`, danach Watchdog antriggern |
| Dezimal-Komma-Fehler in `awk` (Cluster-Load-Skript) | Deutsche Locale auf dem Coder-Host | `LC_NUMERIC=C` vor jedem `awk`-Aufruf setzen (bereits im Skript enthalten) |

---

## Bekannte offene Punkte

- **`dangerously_skip_permissions`** funktioniert nicht, wenn Claude Code als `root` läuft (Standardfall in diesem Setup) — umgangen über `IS_SANDBOX=1` als Umgebungsvariable
- **Watchdog erkennt fehlende Claude-Installation nicht**: Falls die Erstinstallation komplett fehlschlägt (z. B. Netzwerkfehler), erkennt der Watchdog aktuell nur, ob `agentapi` läuft — nicht, ob `claude` selbst installiert ist. Bei diesem Fehlerbild ist manuelles Nachinstallieren nötig (siehe Troubleshooting)
- **Kein Live-Failover für laufende Workspaces**: Die Node-Auswahl gilt nur bei der Erstellung. Ein bereits laufender Workspace wird nicht automatisch auf einen anderen Node verschoben, selbst wenn sein Node stark ausgelastet ist
- **Geplant, noch nicht gebaut**: Ein "Produktiv"-Button, der einen fertigen Workspace in einen dauerhaften, von Coder losgelösten Produktiv-Container exportiert

---

## Lizenz

Nutzung auf eigenes Risiko. Kein offizielles Coder- oder Anthropic-Produkt.
