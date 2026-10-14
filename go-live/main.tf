# Eigenstaendiger Terraform-Stack fuer "Go live": erstellt eine dauerhafte,
# von Coder unabhaengige Proxmox-LXC fuer eine fertige Kundenseite, deployt
# das Docker-Image aus der privaten Registry und verbindet sie per Newt mit
# Pangolin. Wird typischerweise von main.tf's "Go live"-Button im
# Dev-Workspace aus aufgerufen (siehe scripts/go-live.sh.tftpl dort), kann
# aber auch manuell ausgefuehrt werden.
#
# WICHTIG - kein geteilter State: jeder "Go live"-Lauf startet mit frischem
# lokalen State (meist innerhalb des ephemeren Dev-Workspace, der den Lauf
# ausgeloest hat). Die hier erzeugte LXC ist danach NICHT mehr ueber
# "terraform destroy" aus einem spaeteren Lauf heraus verwaltbar - Updates
# oder Abbau einer bestehenden Produktions-Site laufen manuell (siehe
# README.md in diesem Verzeichnis).

terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc05"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4"
    }
  }
}

variable "pm_api_url" {
  type = string
}

variable "pm_api_token_id" {
  type = string
}

variable "pm_api_token_secret" {
  type      = string
  sensitive = true
}

variable "pm_tls_insecure" {
  type    = bool
  default = false
}

variable "target_node" {
  type        = string
  description = "Proxmox-Node, auf dem die Produktions-LXC erstellt wird."
}

variable "lxc_subnet" {
  type = string
}

variable "lxc_gateway" {
  type = string
}

variable "lxc_vlan_tag" {
  type = number
}

variable "ip_range_start" {
  type        = number
  default     = 200
  description = "Eigener IP-Bereich fuer Go-live-LXCs, getrennt vom Dev-Workspace-Bereich (100-200 im Haupttemplate), um Kollisionen zu vermeiden."
}

variable "ip_range_end" {
  type    = number
  default = 250
}

variable "ssh_public_key" {
  type        = string
  description = "Oeffentlicher Teil des dedizierten Go-live-SSH-Keys (nicht derselbe Key wie fuer normale Dev-Workspaces)."
}

variable "ssh_private_key" {
  type        = string
  sensitive   = true
  description = "Privater Teil desselben Keypairs, zum initialen Provisionieren."
}

variable "site_name" {
  type        = string
  description = "Kurzer, eindeutiger Name (z.B. kundenname-website) - wird Hostname und Teil des Image-Tags."
}

variable "customer_domain" {
  type        = string
  default     = ""
  description = "Nur zu Dokumentationszwecken (erscheint im Output) - das eigentliche Domain-Routing passiert in Pangolin, nicht hier."
}

variable "registry_url" {
  type        = string
  description = "Host:Port der privaten Registry, z.B. 10.0.75.1:5000 (siehe registry/README.md)."
}

variable "registry_user" {
  type = string
}

variable "registry_password" {
  type      = string
  sensitive = true
}

variable "docker_image" {
  type        = string
  description = "Image:Tag in der Registry, ohne Registry-Praefix, z.B. kundenname-website:latest."
}

variable "newt_endpoint" {
  type        = string
  description = "URL deines Pangolin-Servers, z.B. https://pangolin.example.com."
}

variable "newt_id" {
  type        = string
  description = "Aus der Pangolin-WebUI beim einmaligen Anlegen der Newt-Site fuer diesen Kunden (Datacenter > ... > Sites > Add Site > Type: Newt)."
}

variable "newt_secret" {
  type        = string
  sensitive   = true
  description = "Wird nur einmal beim Anlegen der Newt-Site in Pangolin angezeigt - dort kopieren, hier einfuegen."
}

provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = var.pm_tls_insecure
}

# Derselbe API-basierte Ansatz wie im Haupttemplate (siehe
# ../scripts/find_free_ip.sh) - eigener IP-Bereich, damit sich Go-live- und
# Dev-Workspace-Vergabe nicht in die Quere kommen.
data "external" "free_ip" {
  program = ["bash", "${path.module}/../scripts/find_free_ip.sh"]
  query = {
    subnet       = var.lxc_subnet
    range_start  = tostring(var.ip_range_start)
    range_end    = tostring(var.ip_range_end)
    api_url      = var.pm_api_url
    token_id     = var.pm_api_token_id
    token_secret = var.pm_api_token_secret
    tls_insecure = var.pm_tls_insecure ? "true" : "false"
  }
}

resource "proxmox_lxc" "production" {
  hostname     = "live-${var.site_name}"
  target_node  = var.target_node
  ostemplate   = "local:vztmpl/ubuntu-ssh-ready.tar.zst"
  cores        = 2
  memory       = 2048
  swap         = 2048
  unprivileged = true
  start        = true
  onboot       = true

  features {
    nesting = true
  }

  rootfs {
    storage = "local-lvm"
    size    = "15G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    tag    = var.lxc_vlan_tag
    ip     = "${data.external.free_ip.result.ip}/24"
    gw     = var.lxc_gateway
  }

  ssh_public_keys = var.ssh_public_key

  connection {
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
    host        = data.external.free_ip.result.ip
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get update && apt-get install -y curl",
      "if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi",
      "mkdir -p /etc/docker",
      "echo '{\"insecure-registries\":[\"${var.registry_url}\"]}' > /etc/docker/daemon.json",
      "systemctl restart docker",
      "echo '${var.registry_password}' | docker login ${var.registry_url} -u '${var.registry_user}' --password-stdin",
      "docker pull ${var.registry_url}/${var.docker_image}",
      "docker rm -f site >/dev/null 2>&1 || true",
      "docker run -d --name site --restart unless-stopped -p 8080:80 ${var.registry_url}/${var.docker_image}",
      # fosrl/newt verbindet sich ausgehend zu Pangolin - kein eingehender Port noetig.
      # ENV-Variablennamen gegen https://github.com/fosrl/newt gegenpruefen, falls das
      # beim ersten Lauf nicht verbindet (von hier aus nicht gegen eine echte
      # Pangolin-Instanz verifizierbar gewesen).
      "docker rm -f newt >/dev/null 2>&1 || true",
      "docker run -d --name newt --restart unless-stopped -e PANGOLIN_ENDPOINT='${var.newt_endpoint}' -e NEWT_ID='${var.newt_id}' -e NEWT_SECRET='${var.newt_secret}' fosrl/newt",
    ]
  }
}

output "production_ip" {
  value = data.external.free_ip.result.ip
}

output "next_steps" {
  value = <<-EOT
    LXC "${var.site_name}" laeuft unter ${data.external.free_ip.result.ip}:8080, Newt-Tunnel sollte verbunden sein (in Pangolin unter der Site "${var.site_name}" pruefen - Status sollte "Online" zeigen).

    Falls fuer diese Site noch keine Resource in Pangolin existiert: dort
    eine neue Resource anlegen, Domain = ${var.customer_domain != "" ? var.customer_domain : "<Kundendomain>"},
    Target = diese Newt-Site, Port 8080. Danach ist die Seite unter der
    Kundendomain live.

    Diese LXC wird von Coder NICHT verwaltet - Updates/Abbau laufen manuell
    (siehe go-live/README.md).
  EOT
}
