# Coder + Claude Code on Proxmox (LXC)

A Coder template that automatically spins up a Proxmox LXC workspace with Claude Code for every task — authenticated via a Claude Pro/Max subscription OAuth token (no API key needed), including a demo-website button, size presets, an automatic ("no confirmations") mode, and multi-node support.

## What this template does

- Automatically creates a fresh Proxmox LXC container for every new task
- Installs and starts Claude Code inside it, authenticated with your **Pro/Max subscription** (not pay-per-token)
- Provides a **demo website button** to view sites built inside the workspace directly
- Size presets (Small/Medium/Large) and an **automatic mode** (Claude works without asking for confirmation on every action)
- **Persistent**: Stop/Start no longer destroys the container — data is preserved
- Optional: pick between multiple Proxmox nodes at creation time (cluster setups)

## Prerequisites

- A running **Coder server** (Docker, see the [official Coder docs](https://coder.com/docs))
- **Proxmox VE** (single node or cluster)
- A **Claude Pro or Max subscription** (for the OAuth token)
- Basic familiarity with Terraform/Proxmox

---

## 1. Prepare Proxmox

### 1.1 Create an API token

In the Proxmox web UI:

1. **Datacenter → Permissions → API Tokens → Add**
2. User: `root@pam`, Token ID: `terraform`
3. **Disable "Privilege Separation"** (important — otherwise API calls fail without extra ACL entries)
4. Note the secret securely (it's shown only once)

Alternatively via CLI on the Proxmox host:

```bash
pveum user token add root@pam terraform --privsep 0
```

### 1.2 Prepare the template container (VMID 9000)

This is the base image every workspace container gets cloned from. It needs an SSH server so Coder can connect.

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

> **Known bug:** The native `clone` attribute of the `telmate/proxmox` provider is broken ("vm not found", open GitHub issue). A backup archive is created instead and referenced via `ostemplate`:

```bash
vzdump 9000 --mode stop --compress zstd --dumpdir /var/lib/vz/dump
cp /var/lib/vz/dump/vzdump-lxc-9000-*.tar.zst /var/lib/vz/template/cache/ubuntu-ssh-ready.tar.zst
```

---

## 2. SSH key for the Coder container

The Coder server container needs an SSH key to connect to newly created LXCs.

On the Docker host (where Coder runs):

```bash
ssh-keygen -t rsa -b 4096 -f ~/coder-ssh-key -N ""
```

Find out which user/UID the Coder container runs as:

```bash
docker exec -it coder-coder-1 id
```

Adjust ownership accordingly (example for UID 1000):

```bash
chown 1000:1000 ~/coder-ssh-key ~/coder-ssh-key.pub
chmod 600 ~/coder-ssh-key
chmod 644 ~/coder-ssh-key.pub
```

Add to your `docker-compose.yaml` under the `coder` service:

```yaml
services:
  coder:
    volumes:
      - ~/coder-ssh-key:/home/coder/.ssh/id_rsa
      - ~/coder-ssh-key.pub:/home/coder/.ssh/id_rsa.pub
```

Then: `docker compose up -d`

---

## 3. Network / firewall

If your Proxmox LXCs run in their own isolated VLAN (recommended), the Coder server needs to reach them — and vice versa.

**Required firewall rules** (UniFi example, applies analogously to any firewall):

| Order | Rule | Source | Destination | Port | Action |
|---|---|---|---|---|---|
| 1 | Docker→Workspace VLAN | Docker host IP | Workspace VLAN | 22 | Allow |
| 2 | Workspace VLAN→Docker | Workspace VLAN | Docker host IP | 22, 7080 | Allow |
| 3 | Workspace VLAN isolation | Workspace VLAN | Any | Any | Block |

**Important:** The order matters — allow rules must come before the general block rule, otherwise they never take effect.

> **Known issue:** New LXC containers can take several minutes after first boot before they're reliably reachable (likely switch-side delay when a new MAC address first appears — spanning-tree forwarding delay). The SSH provisioner timeout in the template is therefore set to 10 minutes. If possible, enable PortFast/edge port on the relevant switch port to fix this properly.

---

## 4. Generate a Claude Code OAuth token

On your local machine (not on the server):

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude
/login
claude setup-token
```

The token starts with `sk-ant-oat...` — note it securely, you'll need it for every template push.

---

## 5. Configure and deploy the template

### 5.1 Clone the repo

```bash
git clone https://github.com/YOUR-USERNAME/YOUR-REPO.git
cd YOUR-REPO
```

### 5.2 Adjust values

In `main.tf`, adjust these defaults to your environment:

| Variable | Where | What |
|---|---|---|
| `pm_api_url` | `variable "pm_api_url"` | Your Proxmox API URL, e.g. `https://192.168.1.10:8006/api2/json` |
| `target_node` | `variable "target_node"` | Your Proxmox node name |
| `lxc_subnet`, `lxc_gateway`, `lxc_vlan_tag` | respective variables | Your network for the workspaces |

If you have **two Proxmox nodes** (cluster) and want to use node selection: adjust `PREFERRED_NODE` and `FAILOVER_NODE` in `scripts/get_cluster_load.sh`, and update every `"pve"`/`"pve4"` occurrence in `main.tf` to your real node names.

### 5.3 Install the Coder CLI and log in

```bash
curl -fsSL https://coder.com/install.sh | sh
coder login https://your-coder-url.com
```

### 5.4 Push the template

```bash
coder templates push lxc-claude-task -d . \
  --variable pm_api_token_id='root@pam!terraform' \
  --variable pm_api_token_secret='YOUR-PROXMOX-TOKEN-SECRET' \
  --variable claude_code_oauth_token='YOUR-CLAUDE-OAUTH-TOKEN' \
  --variable lxc_subnet='10.0.75' \
  --variable lxc_gateway='10.0.75.1' \
  --variable lxc_vlan_tag='75'
```

> **Important:** All variables must be passed explicitly on **every** push — otherwise Coder silently keeps reusing the last value, even if the default in `main.tf` has changed.

---

## 6. Usage

### Creating a new workspace with a website

1. Coder dashboard → **Tasks** → select the template
2. Pick a preset (size + with/without confirmations + optionally node)
3. Enter a prompt, e.g.:
   > Build a modern landing page for [industry/topic]. Design the structure, content, and visuals yourself. Deploy with Docker (nginx:alpine), fixed port mapping -p 8080:80.
4. Click Start

### Important for the demo button

The demo button expects the website on **port 8080** (`localhost:8080` inside the workspace). Always explicitly write "fixed port mapping 8080:80" in your prompt, otherwise Docker assigns a random port and the button won't work.

### Stopping/deleting a workspace

- **Stop/Restart**: via the Coder UI — the container is preserved, no data loss
- **Delete permanently**: delete via the Coder UI (not just stop), otherwise the Proxmox container remains
- **Do not** check "Orphan"/"Skip resource cleanup" if that option appears when deleting

---

## Template structure

```
.
├── main.tf                       Main template
├── watchdog.sh.tftpl              Keeps Claude Code/agentapi running reliably
└── scripts/
    ├── find_free_ip.sh            Automatic IP assignment within the VLAN
    └── get_cluster_load.sh        Live load display for multi-node selection
```

### Key design decisions

**Coder agent as a systemd service instead of a direct SSH call**
The agent runs as its own systemd service with `Restart=always` instead of being launched directly by the SSH provisioner — this prevents the Terraform connection from blocking indefinitely (the agent runs permanently in the foreground).

**Watchdog for Claude Code**
The automatic boot-time start of `agentapi` (the wrapper that embeds Claude Code into the Coder web UI) has no built-in restart mechanism. A cron job checks `localhost:3284/status` every minute and restarts it if needed.

**Persistence instead of recreation**
Originally, `count = data.coder_workspace.me.start_count` destroyed the entire container on every stop and created a brand-new one on start. This is now fixed: `count` was removed, `start` only controls power state, and `lifecycle.ignore_changes` prevents unwanted recreation due to IP/template changes.

**`coder_parameter` vs. `coder_workspace_preset`**
The Tasks flow (AI prompt text field) doesn't display raw `coder_parameter` values (official Coder behavior). Size and mode selection therefore goes through `coder_workspace_preset` blocks (note: `data` block, not `resource`).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| SSH timeout during creation | Network/switch delay on first boot | Wait, optionally increase the timeout in the template |
| `agentapi` 502 in web UI | Watchdog hasn't kicked in yet | Wait 1–2 min, cron runs every minute |
| Claude asks to log in | OAuth token missing/wrong in the watchdog | Check the token in `watchdog.sh.tftpl` |
| "Invalid host header" | `AGENTAPI_ALLOWED_HOSTS` missing | Set in the watchdog script, verify it |
| Demo button greyed out | `subdomain = true` without wildcard DNS configured | Set to `subdomain = false` |
| "vm not found" during creation | Known bug in the provider's `clone` attribute | Use `ostemplate` instead of `clone` |
| Claude Code fails to install / `ECONNREFUSED downloads.claude.ai` | Brief network hiccup, often when creating workspaces in parallel | Reinstall manually: `curl -fsSL https://claude.ai/install.sh -o /tmp/i.sh && bash /tmp/i.sh`, then trigger the watchdog |
| Decimal-comma error in `awk` (cluster load script) | German locale on the Coder host | Prefix every `awk` call with `LC_NUMERIC=C` (already included in the script) |

---

## Known open issues

- **`dangerously_skip_permissions`** doesn't work while Claude Code runs as `root` (the default in this setup) — worked around via the `IS_SANDBOX=1` environment variable
- **Watchdog doesn't detect a missing Claude installation**: if the initial install fails entirely (e.g. network error), the watchdog currently only checks whether `agentapi` is running — not whether `claude` itself is installed. Manual reinstallation is required in that case (see Troubleshooting)
- **No live failover for running workspaces**: node selection only applies at creation time. A running workspace is never automatically migrated to another node, even if its node becomes heavily loaded
- **Planned, not yet built**: a "Go live" button that exports a finished workspace into a permanent, Coder-independent production container

---

## License

Use at your own risk. Not an official Coder or Anthropic product.
