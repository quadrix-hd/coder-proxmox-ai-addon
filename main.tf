terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc05"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ---------------------------------------------------------
# Variablen
# ---------------------------------------------------------

variable "pm_api_url" {
  type    = string
  default = "https://10.0.10.2:8006/api2/json"
}

variable "pm_api_token_id" {
  type = string
}

variable "pm_api_token_secret" {
  type      = string
  sensitive = true
}

variable "pm_tls_insecure" {
  type        = bool
  description = "TLS-Zertifikatspruefung gegen die Proxmox-API. Nur auf true setzen, wenn kein Zertifikat importiert werden kann (siehe README, Abschnitt 'Prepare Proxmox')."
  default     = false
}

variable "claude_code_oauth_token" {
  type      = string
  sensitive = true
}

variable "skills_repo_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "skills_repo_path" {
  type    = string
  default = "quadrix-hd/claude-skills"
}

variable "target_node" {
  type    = string
  default = "pve"
}

variable "lxc_subnet" {
  type    = string
  default = "10.0.75"
}

variable "lxc_gateway" {
  type    = string
  default = "10.0.75.1"
}

variable "lxc_vlan_tag" {
  type    = number
  default = 75
}

variable "use_sdn_ipam" {
  type        = bool
  description = "IP-Vergabe atomar ueber Proxmox SDN + IPAM statt ueber die Ist-Abfrage der Guest-Configs. Erfordert eine einmalige SDN-Einrichtung in Proxmox (Zone/VNet/Subnet), siehe README, Abschnitt 'SDN + IPAM'. Default false: die bisherige, getestete API-Abfrage bleibt unveraendert aktiv."
  default     = false
}

variable "sdn_zone" {
  type        = string
  description = "Name der Proxmox-SDN-Zone. Nur relevant, wenn use_sdn_ipam=true."
  default     = ""
}

variable "sdn_vnet" {
  type        = string
  description = "Name des Proxmox-SDN-VNet innerhalb der Zone. Nur relevant, wenn use_sdn_ipam=true."
  default     = ""
}

# ---------------------------------------------------------
# Proxmox Provider
# ---------------------------------------------------------

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = var.pm_tls_insecure
}

# ---------------------------------------------------------
# Coder Metadaten
# ---------------------------------------------------------

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}

# ---------------------------------------------------------
# Auswahl der Workspace-Größe (erscheint als Dropdown in der UI)
# ---------------------------------------------------------

data "coder_parameter" "instance_size" {
  name         = "instance_size"
  display_name = "Workspace-Größe"
  description  = "Wie viel Leistung brauchst du?"
  type         = "string"
  default      = "small"
  mutable      = false

  option {
    name  = "Klein (einfache Webseite) - 1 CPU / 1GB RAM / 8GB Disk"
    value = "small"
  }
  option {
    name  = "Mittel - 2 CPU / 2GB RAM / 15GB Disk"
    value = "medium"
  }
  option {
    name  = "Groß (Dev-Umgebung) - 4 CPU / 4GB RAM / 20GB Disk"
    value = "large"
  }
}

data "coder_workspace_preset" "small_auto_node" {
  # Default-Preset: setzt bewusst KEIN target_node, damit der dynamische
  # Default von data.coder_parameter.target_node (der am wenigsten
  # ausgelastete Knoten) tatsaechlich greift. Wer einen bestimmten Knoten
  # erzwingen will, nutzt eines der expliziten *_pve/*_pve4-Presets unten.
  name    = "Klein - 1 CPU / 1GB RAM - automatische Node-Auswahl (mit Rueckfragen)"
  default = true
  parameters = {
    instance_size    = "small"
    skip_permissions = "false"
  }
}

data "coder_workspace_preset" "small_pve4" {
  name = "Klein - 1 CPU / 1GB RAM - pve4 (mit Rueckfragen)"
  parameters = {
    instance_size    = "small"
    skip_permissions = "false"
    target_node      = "pve4"
  }
}

data "coder_workspace_preset" "small_auto_pve" {
  name = "Klein - 1 CPU / 1GB RAM - pve (Automatik, ohne Rueckfragen)"
  parameters = {
    instance_size    = "small"
    skip_permissions = "true"
    target_node      = "pve"
  }
}

data "coder_workspace_preset" "small_auto_pve4" {
  name = "Klein - 1 CPU / 1GB RAM - pve4 (Automatik, ohne Rueckfragen)"
  parameters = {
    instance_size    = "small"
    skip_permissions = "true"
    target_node      = "pve4"
  }
}

data "coder_workspace_preset" "medium_pve" {
  name = "Mittel - 2 CPU / 2GB RAM - pve (mit Rueckfragen)"
  parameters = {
    instance_size    = "medium"
    skip_permissions = "false"
    target_node      = "pve"
  }
}

data "coder_workspace_preset" "medium_pve4" {
  name = "Mittel - 2 CPU / 2GB RAM - pve4 (mit Rueckfragen)"
  parameters = {
    instance_size    = "medium"
    skip_permissions = "false"
    target_node      = "pve4"
  }
}

data "coder_workspace_preset" "medium_auto_pve" {
  name = "Mittel - 2 CPU / 2GB RAM - pve (Automatik, ohne Rueckfragen)"
  parameters = {
    instance_size    = "medium"
    skip_permissions = "true"
    target_node      = "pve"
  }
}

data "coder_workspace_preset" "medium_auto_pve4" {
  name = "Mittel - 2 CPU / 2GB RAM - pve4 (Automatik, ohne Rueckfragen)"
  parameters = {
    instance_size    = "medium"
    skip_permissions = "true"
    target_node      = "pve4"
  }
}

data "coder_workspace_preset" "large_pve" {
  name = "Gross (Dev) - 4 CPU / 4GB RAM - pve (mit Rueckfragen)"
  parameters = {
    instance_size    = "large"
    skip_permissions = "false"
    target_node      = "pve"
  }
}

data "coder_workspace_preset" "large_pve4" {
  name = "Gross (Dev) - 4 CPU / 4GB RAM - pve4 (mit Rueckfragen)"
  parameters = {
    instance_size    = "large"
    skip_permissions = "false"
    target_node      = "pve4"
  }
}

data "coder_workspace_preset" "large_auto_pve" {
  name = "Gross (Dev) - 4 CPU / 4GB RAM - pve (Automatik, ohne Rueckfragen)"
  parameters = {
    instance_size    = "large"
    skip_permissions = "true"
    target_node      = "pve"
  }
}

data "coder_workspace_preset" "large_auto_pve4" {
  name = "Gross (Dev) - 4 CPU / 4GB RAM - pve4 (Automatik, ohne Rueckfragen)"
  parameters = {
    instance_size    = "large"
    skip_permissions = "true"
    target_node      = "pve4"
  }
}

data "coder_parameter" "skip_permissions" {
  name         = "skip_permissions"
  display_name = "Automatik-Modus (ohne Rückfragen)"
  type         = "bool"
  default      = "false"
  mutable      = false
}

locals {
  size_presets = {
    small  = { cores = 1, memory = 1024, disk = "8G", swap = 1024 }
    medium = { cores = 2, memory = 2048, disk = "15G", swap = 4096 }
    large  = { cores = 4, memory = 4096, disk = "20G", swap = 2048 }
  }
  chosen = local.size_presets[data.coder_parameter.instance_size.value]
}

# ---------------------------------------------------------
# Automatische freie IP im VLAN suchen
# ---------------------------------------------------------

data "external" "cluster_load" {
  program = ["bash", "${path.module}/scripts/get_cluster_load.sh"]
  query = {
    api_url      = var.pm_api_url
    token_id     = var.pm_api_token_id
    token_secret = var.pm_api_token_secret
    tls_insecure = var.pm_tls_insecure ? "true" : "false"
  }
}

locals {
  # scripts/get_cluster_load.sh liefert die Knotenliste als JSON-String
  # (die "external"-Data-Source kann nur flache String-Maps zurueckgeben),
  # hier wird sie fuer den dynamischen Dropdown wieder dekodiert.
  cluster_nodes = jsondecode(data.external.cluster_load.result.nodes_json)
}

data "coder_parameter" "target_node" {
  name         = "target_node"
  display_name = "Proxmox-Node"
  description  = "Auslastung wird live angezeigt (RAM-Nutzung), Liste wird automatisch aus dem Cluster ermittelt."
  type         = "string"
  default      = data.external.cluster_load.result.default_node
  mutable      = false

  dynamic "option" {
    for_each = local.cluster_nodes
    content {
      name  = "${option.value.name} (${option.value.load}% RAM ausgelastet)"
      value = option.value.name
    }
  }
}

data "external" "free_ip" {
  count   = var.use_sdn_ipam ? 0 : 1
  program = ["bash", "${path.module}/scripts/find_free_ip.sh"]
  query = {
    subnet       = var.lxc_subnet
    range_start  = "100"
    range_end    = "200"
    api_url      = var.pm_api_url
    token_id     = var.pm_api_token_id
    token_secret = var.pm_api_token_secret
    tls_insecure = var.pm_tls_insecure ? "true" : "false"
  }
}

# Alternative, atomare IP-Vergabe ueber Proxmox SDN + IPAM (opt-in via
# use_sdn_ipam). Braucht das Ziel-Node schon vor der LXC-Erstellung, daher
# die Abhaengigkeit von data.coder_parameter.target_node statt dem
# proxmox_lxc-Resource selbst.
data "external" "free_ip_sdn" {
  count   = var.use_sdn_ipam ? 1 : 0
  program = ["bash", "${path.module}/scripts/allocate_sdn_ip.sh"]
  query = {
    subnet       = var.lxc_subnet
    range_start  = "100"
    range_end    = "200"
    api_url      = var.pm_api_url
    token_id     = var.pm_api_token_id
    token_secret = var.pm_api_token_secret
    tls_insecure = var.pm_tls_insecure ? "true" : "false"
    node         = data.coder_parameter.target_node.value
    zone         = var.sdn_zone
    vnet         = var.sdn_vnet
  }
}

locals {
  workspace_ip  = var.use_sdn_ipam ? data.external.free_ip_sdn[0].result.ip : data.external.free_ip[0].result.ip
  workspace_mac = var.use_sdn_ipam ? data.external.free_ip_sdn[0].result.mac : null
}

# ---------------------------------------------------------
# Coder Agent (läuft im LXC)
# ---------------------------------------------------------

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  startup_script = <<-EOT
    #!/bin/bash
    set -e
    if ! command -v docker &> /dev/null; then
      curl -fsSL https://get.docker.com | sh
      usermod -aG docker coder || true
    fi

    # Claude Code Skills zentral aus privatem Repo nachladen
    # (Token laeuft ueber GIT_ASKPASS statt in der Klartext-URL, damit es nicht in
    #  der Prozessliste (ps aux) des git-Subprozesses auftaucht)
    mkdir -p /root/.claude/skills
    rm -rf /tmp/skills-repo
    if [ -n "${var.skills_repo_token}" ]; then
      SKILLS_ASKPASS=$(mktemp)
      printf '#!/bin/bash\nprintf "%%s" "%s"\n' "${var.skills_repo_token}" > "$SKILLS_ASKPASS"
      chmod 700 "$SKILLS_ASKPASS"
      GIT_ASKPASS="$SKILLS_ASKPASS" GIT_TERMINAL_PROMPT=0 \
        git clone --depth 1 "https://x-access-token@github.com/${var.skills_repo_path}.git" /tmp/skills-repo 2>/dev/null || true
      rm -f "$SKILLS_ASKPASS"
    fi
    if [ -d /tmp/skills-repo ]; then
      for skill_dir in /tmp/skills-repo/*/; do
        skill_name=$(basename "$skill_dir")
        rm -rf "/root/.claude/skills/$skill_name"
        cp -r "$skill_dir" "/root/.claude/skills/$skill_name"
      done
      rm -rf /tmp/skills-repo
    fi
  EOT
}

# ---------------------------------------------------------
# Der eigentliche Workspace als Proxmox LXC
# ---------------------------------------------------------

resource "proxmox_lxc" "workspace" {
  hostname     = "ws-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
  target_node  = data.coder_parameter.target_node.value
  ostemplate   = "local:vztmpl/ubuntu-ssh-ready.tar.zst"
  cores        = local.chosen.cores
  memory       = local.chosen.memory
  swap         = local.chosen.swap
  unprivileged = true
  start        = data.coder_workspace.me.start_count == 1

  lifecycle {
    ignore_changes = [network, ostemplate]
  }

  features {
    nesting = true
  }

  rootfs {
    storage = "local-lvm"
    size    = local.chosen.disk
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    tag    = var.lxc_vlan_tag
    ip     = "${local.workspace_ip}/24"
    gw     = var.lxc_gateway
    hwaddr = local.workspace_mac
  }

  ssh_public_keys = file("/home/coder/.ssh/id_rsa.pub")

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/home/coder/.ssh/id_rsa")
    host        = local.workspace_ip
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get update && apt-get install -y curl sudo",
      "useradd -m -s /bin/bash coder || true",
      "mkdir -p /opt/coder",
      "echo '${base64encode(coder_agent.main.init_script)}' | base64 -d > /opt/coder/init.sh",
      "chmod +x /opt/coder/init.sh",
      # Secrets liegen nur noch in dieser einen Datei (statt doppelt in Unit + Watchdog-Skript),
      # umask 077 sorgt dafuer, dass sie nie mit laxeren Rechten als 600 entsteht.
      "bash -c \"umask 077; printf 'CODER_AGENT_TOKEN=%s\\nCLAUDE_CODE_OAUTH_TOKEN=%s\\n' '${coder_agent.main.token}' '${var.claude_code_oauth_token}' > /etc/coder-agent.env\"",
      "chmod 600 /etc/coder-agent.env",
      "bash -c \"cat > /etc/systemd/system/coder-agent.service <<'UNIT_EOF'\n[Unit]\nDescription=Coder Agent\nAfter=network-online.target\n\n[Service]\nType=simple\nUser=root\nEnvironmentFile=/etc/coder-agent.env\nEnvironment=IS_SANDBOX=1\nExecStart=/opt/coder/init.sh\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\nUNIT_EOF\"",
      "systemctl daemon-reload",
      "systemctl enable --now coder-agent.service",
      "echo '${base64encode(templatefile("${path.module}/watchdog.sh.tftpl", { chat_base_path = "/@${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}.${data.coder_workspace.me.id}/apps/ccw/chat" }))}' | base64 -d > /usr/local/bin/agentapi-watchdog.sh",
      "chmod +x /usr/local/bin/agentapi-watchdog.sh",
      "bash -c \"cat > /etc/cron.d/agentapi-watchdog <<'CRON_EOF'\n* * * * * root sleep 20 && /usr/local/bin/agentapi-watchdog.sh\nCRON_EOF\"",
    ]
  }
}

# Gibt eine ueber SDN+IPAM reservierte IP beim Zerstoeren des Workspaces
# wieder frei. Nur relevant wenn use_sdn_ipam=true (siehe free_ip_sdn oben);
# scripts/find_free_ip.sh (der Default-Pfad) braucht kein Gegenstueck, weil
# es nichts reserviert, sondern nur den Ist-Zustand abfragt.
resource "null_resource" "sdn_ip_release" {
  count = var.use_sdn_ipam ? 1 : 0

  triggers = {
    script       = "${path.module}/scripts/release_sdn_ip.sh"
    api_url      = var.pm_api_url
    token_id     = var.pm_api_token_id
    token_secret = var.pm_api_token_secret
    tls_insecure = var.pm_tls_insecure ? "true" : "false"
    node         = data.coder_parameter.target_node.value
    zone         = var.sdn_zone
    vnet         = var.sdn_vnet
    ip           = data.external.free_ip_sdn[0].result.ip
    mac          = data.external.free_ip_sdn[0].result.mac
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${self.triggers.script}'"
    environment = {
      API_URL      = self.triggers.api_url
      TOKEN_ID     = self.triggers.token_id
      TOKEN_SECRET = self.triggers.token_secret
      TLS_INSECURE = self.triggers.tls_insecure
      NODE         = self.triggers.node
      ZONE         = self.triggers.zone
      VNET         = self.triggers.vnet
      IP           = self.triggers.ip
      MAC          = self.triggers.mac
    }
  }
}

# ---------------------------------------------------------
# Claude Code Modul
# ---------------------------------------------------------

resource "coder_ai_task" "task" {
  app_id = module.claude-code.task_app_id
}

module "claude-code" {
  source                       = "registry.coder.com/coder/claude-code/coder"
  version                      = "4.7.3"
  agent_id                     = coder_agent.main.id
  workdir                      = "/home/coder/project"
  claude_code_oauth_token      = var.claude_code_oauth_token
  ai_prompt                    = data.coder_task.me.prompt
  model                        = "sonnet"
  dangerously_skip_permissions = data.coder_parameter.skip_permissions.value == "true"
}

# ---------------------------------------------------------
# Demo-Button
# ---------------------------------------------------------

resource "coder_app" "reboot" {
  agent_id     = coder_agent.main.id
  slug         = "reboot"
  display_name = "Server neu starten"
  icon         = "/emojis/1f504.png"
  command      = "sudo reboot"
}

resource "coder_app" "demo_site" {
  agent_id     = coder_agent.main.id
  slug         = "demo"
  display_name = "Demo-Webseite"
  url          = "http://localhost:8080"
  icon         = "/icon/globe.svg"
  subdomain    = false
  share        = "authenticated"

  healthcheck {
    url       = "http://localhost:8080"
    interval  = 10
    threshold = 6
  }
}
