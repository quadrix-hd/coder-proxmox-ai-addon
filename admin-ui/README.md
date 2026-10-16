# Go-live Admin UI

Zentrale, dauerhaft laufende Verwaltungsoberflaeche fuer alle live Kunden-
Seiten ("Go live"). Loest zwei Probleme der vorherigen Button-nur-Loesung:

1. **Kein Gedaechtnis mehr:** jede Site hat jetzt einen eigenen,
   persistenten Terraform-State (ueber `terraform workspace`, siehe
   `app/terraform_runner.py`) statt bei jedem Lauf frisch zu starten. Das
   macht "jederzeit aendern" (neues Image, Site entfernen) zu einem
   normalen, idempotenten Vorgang statt einer manuellen SSH-Aktion.
2. **Zentrale statt verteilte Zugangsdaten:** Proxmox-API-Token, der
   dedizierte Go-live-SSH-Key, Registry- und (optional) Pangolin-
   Zugangsdaten liegen nur noch hier, nicht mehr in jedem einzelnen
   Dev-Workspace. Der "Go live"-Button im Workspace pusht nur noch das
   Image und verlinkt direkt auf das Formular hier - keinerlei
   Admin-UI-Zugangsdaten im Workspace noetig (siehe Haupt-README,
   Abschnitt "Go live").

## Architektur in Kuerze

- Flask-App (`app/`), SQLite fuer den Site-Index (`app/db.py`).
- `app/terraform_runner.py` ruft das unveraenderte `go-live/main.tf` dieses
  Repos auf (in dieses Image hineinkopiert, siehe `Dockerfile` - kein
  Runtime-`git clone` mehr, siehe Kommentar dort fuer die Begruendung).
- `app/pangolin_client.py` ist optional (siehe unten) und automatisiert
  Pangolin Site/Resource/Target-Erstellung ueber dessen Integration-API.
- `app/ssh_runner.py` macht Redeploys (neues Image auf eine schon
  bestehende Produktions-LXC) per direktem SSH, ohne neuen `terraform apply`.

## Setup

1. SSH-Key fuer Go-live-Provisionierung (falls noch nicht vorhanden, siehe
   Haupt-README Abschnitt "Go live" fuer Details zum Zweck):
   ```bash
   mkdir -p ssh
   ssh-keygen -t rsa -b 4096 -f ssh/golive_id_rsa -N ""
   chown 1000:1000 ssh/golive_id_rsa ssh/golive_id_rsa.pub   # Container laeuft als UID 1000 (adminui)
   chmod 600 ssh/golive_id_rsa
   chmod 644 ssh/golive_id_rsa.pub
   ```
2. `.env` anlegen:
   ```bash
   cp .env.example .env
   # SECRET_KEY und ADMIN_UI_PASSWORD_HASH erzeugen (Befehle stehen als
   # Kommentar in .env.example), restliche Werte (Proxmox, Registry,
   # optional Pangolin) eintragen. ADMIN_UI_API_TOKEN nur setzen, falls du
   # POST /api/sites programmatisch nutzen willst (z.B. aus einer CI-
   # Pipeline) - der "Go live"-Button im Workspace braucht ihn nicht.
   ```
3. Bauen und starten:
   ```bash
   docker compose up -d --build
   ```
4. Unter `http://<docker-host>:9000` einloggen (Passwort = das, aus dem du
   `ADMIN_UI_PASSWORD_HASH` erzeugt hast).

## Pangolin-Integration (optional, UNVERIFIZIERT)

Wenn `PANGOLIN_API_URL`/`PANGOLIN_API_KEY`/`PANGOLIN_ORG_ID` gesetzt sind,
legt diese App die Pangolin-Site (Newt-Tunnel) und - falls eine Basis-Domain
gewaehlt wird - auch die Resource/Target automatisch an, statt dass du es
manuell in Pangolins WebUI machst.

**Das ist nicht gegen eine echte Pangolin-Instanz getestet.** Die
Endpunkte/Request-Formate in `app/pangolin_client.py` stammen aus
durchsuchten Snippets der offiziellen Doku (direkter Zugriff auf
docs.pangolin.net war aus der Sandbox, in der das geschrieben wurde, per
DNS blockiert) plus einem Drittanbieter-Tool, das denselben Ablauf
automatisiert. Bevor du dich darauf verlaesst:

1. `<deine-pangolin-url>/v1/docs` (Swagger) oeffnen und mit den Pfaden/
   Feldnamen in `pangolin_client.py` abgleichen.
2. Eine Test-Site durch diese UI anlegen und in Pangolins eigener
   Oberflaeche verifizieren, dass Site/Resource/Target wie erwartet
   erscheinen - **bevor** du damit einen echten Kunden anlegst.

Ohne diese drei Variablen funktioniert alles weiter wie bisher: Newt-Site
manuell in Pangolin anlegen, Newt-ID/Secret im "Neue Site"-Formular hier
eintragen. Eine komplett neue Kunden-Apex-Domain braucht so oder so einmalig
einen manuellen "Add Domain"-Schritt in Pangolin (DNS-Verifizierung laesst
sich nicht automatisieren) - danach koennen Subdomains darunter automatisch
vergeben werden.

## Update (go-live/main.tf hat sich geaendert)

```bash
docker compose up -d --build
```

Bestehende Sites sind nicht betroffen (ihr State liegt in eigenen Volumes,
siehe `docker-compose.yml`), neue/zukuenftige Redeploys/Teardowns laufen
mit der aktualisierten Konfiguration.

## Backup

Alles, was ueber einen Server-Neuaufbau hinweg erhalten bleiben muss, liegt
in den drei Docker-Volumes (`admin_ui_db`, `admin_ui_tfstate`,
`admin_ui_tfcache`) plus `ssh/` und `.env` auf dem Host.
