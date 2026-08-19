terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc05"
    }
    external = {
      source = "hashicorp/external"
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

variable "claude_code_oauth_token" {
  type      = string
  sensitive = true
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

# ---------------------------------------------------------
# Proxmox Provider
# ---------------------------------------------------------

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = true
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

data "coder_workspace_preset" "small_pve" {
  name    = "Klein - 1 CPU / 1GB RAM - pve (mit Rueckfragen)"
  default = true
  parameters = {
    instance_size    = "small"
    skip_permissions = "false"
    target_node      = "pve"
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
    small  = { cores = 1, memory = 1024, disk = "8G" }
    medium = { cores = 2, memory = 2048, disk = "15G" }
    large  = { cores = 4, memory = 4096, disk = "20G" }
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
  }
}

data "coder_parameter" "target_node" {
  name         = "target_node"
  display_name = "Proxmox-Node"
  description  = "Auslastung wird live angezeigt (RAM-Nutzung)."
  type         = "string"
  default      = "pve"
  mutable      = false

  option {
    name  = "${data.external.cluster_load.result.node1_name} (${data.external.cluster_load.result.node1_load}% RAM ausgelastet)"
    value = data.external.cluster_load.result.node1_name
  }
  option {
    name  = "${data.external.cluster_load.result.node2_name} (${data.external.cluster_load.result.node2_load}% RAM ausgelastet)"
    value = data.external.cluster_load.result.node2_name
  }
}

data "external" "free_ip" {
  program = ["bash", "${path.module}/scripts/find_free_ip.sh"]
  query = {
    subnet      = var.lxc_subnet
    range_start = "100"
    range_end   = "200"
  }
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

    # Claude Code Skills automatisch nachladen
    mkdir -p /root/.claude/skills
    if [ ! -d /root/.claude/skills/frontend-design ]; then
      git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/skills-repo 2>/dev/null || true
      if [ -d /tmp/skills-repo ]; then
        cd /tmp/skills-repo
        git sparse-checkout set skills/frontend-design
        cp -r skills/frontend-design /root/.claude/skills/frontend-design
        cd /
        rm -rf /tmp/skills-repo
      fi
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
    ip     = "${data.external.free_ip.result.ip}/24"
    gw     = var.lxc_gateway
  }

  ssh_public_keys = file("/home/coder/.ssh/id_rsa.pub")

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file("/home/coder/.ssh/id_rsa")
    host        = data.external.free_ip.result.ip
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get update && apt-get install -y curl sudo",
      "useradd -m -s /bin/bash coder || true",
      "mkdir -p /opt/coder",
      "echo '${base64encode(coder_agent.main.init_script)}' | base64 -d > /opt/coder/init.sh",
      "chmod +x /opt/coder/init.sh",
      "bash -c \"cat > /etc/systemd/system/coder-agent.service <<'UNIT_EOF'\n[Unit]\nDescription=Coder Agent\nAfter=network-online.target\n\n[Service]\nType=simple\nUser=root\nEnvironment=CODER_AGENT_TOKEN=${coder_agent.main.token}\nEnvironment=CLAUDE_CODE_OAUTH_TOKEN=${var.claude_code_oauth_token}\nEnvironment=IS_SANDBOX=1\nExecStart=/opt/coder/init.sh\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\nUNIT_EOF\"",
      "systemctl daemon-reload",
      "systemctl enable --now coder-agent.service",
      "echo '${base64encode(templatefile("${path.module}/watchdog.sh.tftpl", { chat_base_path = "/@${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}.${data.coder_workspace.me.id}/apps/ccw/chat", claude_token = var.claude_code_oauth_token }))}' | base64 -d > /usr/local/bin/agentapi-watchdog.sh",
      "chmod +x /usr/local/bin/agentapi-watchdog.sh",
      "bash -c \"cat > /etc/cron.d/agentapi-watchdog <<'CRON_EOF'\n* * * * * root sleep 20 && /usr/local/bin/agentapi-watchdog.sh\nCRON_EOF\"",
    ]
  }
}

# ---------------------------------------------------------
# Claude Code Modul
# ---------------------------------------------------------

resource "coder_ai_task" "task" {
  app_id = module.claude-code.task_app_id
}

module "claude-code" {
  source                  = "registry.coder.com/coder/claude-code/coder"
  version                 = "4.7.3"
  agent_id                = coder_agent.main.id
  workdir                 = "/home/coder/project"
  claude_code_oauth_token = var.claude_code_oauth_token
  ai_prompt               = data.coder_task.me.prompt
  model                   = "sonnet"
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
