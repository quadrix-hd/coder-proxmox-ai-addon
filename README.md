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
- `jq` installed in whatever environment actually runs the Terraform provisioning for `coder templates push` — for a standard Docker Compose deployment (the `coder` service from the [official docs](https://coder.com/docs)), that's **inside the `coder` container itself**, not the Docker host. The built-in provisioner runs there, so that's where `scripts/get_cluster_load.sh` and `scripts/find_free_ip.sh` execute. See "5.4 Push the template" for how to get `jq` into that container without rebuilding the image.
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

### 1.3 Trust the Proxmox certificate (instead of disabling TLS verification)

By default `pm_tls_insecure = false` — the template expects the Coder host to actually trust Proxmox's certificate rather than skipping verification entirely. Proxmox ships a self-signed certificate by default, so import it once on the Docker host running Coder:

```bash
# On the Proxmox host: grab the certificate
openssl s_client -connect YOUR-PROXMOX-IP:8006 -showcerts </dev/null 2>/dev/null | openssl x509 > proxmox.crt

# On the Coder/Docker host: trust it
sudo cp proxmox.crt /usr/local/share/ca-certificates/proxmox.crt
sudo update-ca-certificates
```

If you're running Coder itself inside a container, the certificate needs to be trusted **inside that container's** trust store, not just the Docker host's. Only if importing a real/self-signed certificate genuinely isn't possible in your setup, fall back to `pm_tls_insecure = true` on the `coder templates push` — understand that this disables TLS verification against the Proxmox API entirely.

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
| `lxc_subnet`, `lxc_gateway`, `lxc_vlan_tag` | respective variables | Your network for the workspaces |

If you have a Proxmox **cluster** and want to use node selection: the node dropdown is generated automatically from whatever `/nodes` returns — no per-node script edits needed, and no preset edits either, since node choice is a plain parameter (`target_node`, with "Automatisch" as the default option), not baked into presets.

### 5.3 Install the Coder CLI and log in

```bash
curl -fsSL https://coder.com/install.sh | sh
coder login https://your-coder-url.com
```

### 5.4 Push the template

Put your secrets in a **`terraform.tfvars`** file in the template directory (exactly that name — it's already excluded via `.gitignore`'s `*.tfvars` pattern) instead of passing them inline — inline `--variable` values land in your shell history. Terraform auto-loads this file, no extra flag needed. Don't use `coder templates push`'s own `--variables-file` flag for this: in practice it does **not** reliably accept a plain HCL tfvars file (it goes through a separate, stricter parser used for the "workspace tags" feature and tends to error out) — `terraform.tfvars` auto-loading is the mechanism that actually works.

A commented template with every variable is in [`terraform.tfvars.example`](terraform.tfvars.example) — copy it (`cp terraform.tfvars.example terraform.tfvars`) and fill in your real values instead of retyping everything from scratch.

```hcl
# terraform.tfvars — never commit this file
pm_api_token_id         = "root@pam!terraform"
pm_api_token_secret     = "YOUR-PROXMOX-TOKEN-SECRET"
claude_code_oauth_token = "YOUR-CLAUDE-OAUTH-TOKEN"
lxc_subnet              = "10.0.75"
lxc_gateway             = "10.0.75.1"
lxc_vlan_tag            = "75"      # quoted, see note below
pm_tls_insecure         = "false"   # quoted, see note below
```

> **Non-string variables must still be quoted here.** `lxc_vlan_tag` is declared as `number` and `pm_tls_insecure` as `bool` in `main.tf`, but Coder's own tfvars auto-discovery (separate from Terraform's normal HCL evaluation, used to populate the template variables list) fails with `unsupported value type: cty.Bool` / `cty.Number` on bare `true`/`75` literals. Quoting them as strings (`"true"`, `"75"`) works — Terraform still converts them to the declared type when it actually runs.

```bash
coder templates push lxc-claude-task -d .
```

> **Important:** All variables must be set explicitly on **every** push — otherwise Coder silently keeps reusing the last value, even if the default in `main.tf` has changed. Keep `terraform.tfvars` up to date.

**If `jq` is missing where the provisioner runs** (see Prerequisites) — for a Docker Compose Coder deployment, that's the `coder` container — you'll get `Error Message: jq ist nicht installiert` during `terraform plan`, even if `jq` is installed on the Docker host. Fastest fix, no image rebuild needed: mount a **statically linked** `jq` binary into the container (a dynamically-linked one from the host's package manager won't run — it's missing its shared libraries inside the container and fails with `exec: no such file or directory`):

```bash
# On the Docker host:
curl -L -o /opt/jq-static https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64
chmod +x /opt/jq-static
file /opt/jq-static   # must say "statically linked", not "dynamically linked"
```

Then add to the `coder` service's `volumes:` in your `docker-compose.yaml`:
```yaml
      - /opt/jq-static:/usr/bin/jq:ro
```
`docker compose up -d --force-recreate coder`, then verify with `docker exec <coder-container-name> jq --version`. Since this is a bind mount from a file on the Docker host (not something baked into the running container), it survives container recreation/restarts without any further action.

---

## 6. Usage

### Creating a new workspace with a website

1. Coder dashboard → **Tasks** → select the template
2. Pick a size preset (Small/Medium/Large) — node and confirmation-mode stay on their defaults here (Tasks only shows presets, not the individual parameters; use "Create workspace" instead of Tasks if you need to change those up front)
3. Enter a prompt, e.g.:
   > Build a modern landing page for [industry/topic]. Design the structure, content, and visuals yourself. Deploy with Docker (nginx:alpine), fixed port mapping -p 8080:80.
4. Click Start

### Important for the demo button

The demo button expects the website on **port 8080** (`localhost:8080` inside the workspace). Always explicitly write "fixed port mapping 8080:80" in your prompt, otherwise Docker assigns a random port and the button won't work.

### Stopping/deleting a workspace

- **Stop/Restart**: via the Coder UI — the container is preserved, no data loss
- **Delete permanently**: delete via the Coder UI (not just stop), otherwise the Proxmox container remains
- **Do not** check "Orphan"/"Skip resource cleanup" if that option appears when deleting

### Preventing forgotten workspaces from piling up

Nothing in this template stops a workspace automatically — a forgotten one just sits there running, using RAM/CPU on your Proxmox node(s) indefinitely. This matters more once more than one person can create workspaces (e.g. multiple OIDC users/groups): an inactivity-based TTL means stale workspaces free themselves up instead of quietly accumulating. Coder has built-in support for this independent of this template's Terraform code:

- **Per-workspace**: workspace owners can set a "Scheduled shutdown" from the workspace's own settings in the Coder UI.
- **Template-wide default**: check **Templates → `lxc-claude-task` → Settings → Schedule** in the Coder dashboard (exact wording depends on your Coder version), or `coder templates push --help` for a default-TTL-style flag your installed version supports. Setting a sane default there (e.g. auto-stop after 8h idle) means someone forgetting to stop a workspace doesn't silently eat cluster resources forever.

---

## Optional: SDN + IPAM (atomic IP allocation)

By default (`use_sdn_ipam = false`), IP allocation works the way described above: `find_free_ip.sh` reads the IPs actually configured on every VM/LXC via the Proxmox API and picks the first one that's free. That's reliable, but not fully atomic — two `terraform apply` runs racing at the exact same moment could in theory still pick the same IP (see "Known open issues").

Proxmox's built-in SDN + IPAM stack closes that gap: the PVE IPAM plugin locks its database (`cfs_lock_file`) while checking and writing an allocation, and rejects a request for an IP that's already taken (`"IP already exist"`). That makes "try to claim IP X, move to X+1 on conflict" a genuinely atomic operation. This template can use it, opt-in.

### One-time Proxmox setup

In the Proxmox web UI, under **Datacenter → SDN**:

1. **Zones** → Add a zone (e.g. `ws` of type "Simple" is enough if you just want IPAM bookkeeping on your existing bridge/VLAN — you don't have to migrate to VXLAN/EVPN for this).
2. **VNets** → Add a VNet inside that zone (e.g. `wsnet`).
3. **Subnets** (under that VNet) → Add a subnet matching your `lxc_subnet`, e.g. `10.0.75.0/24`. Leave "DHCP Ranges" empty — allocation happens via the API, not DHCP.
4. **Apply** the SDN configuration (there's an "Apply" button in the SDN overview — changes are staged until you click it).

The built-in IPAM plugin (id `pve`) is available by default, no extra plugin setup needed.

### Enable it in the template

Add these three lines to your `terraform.tfvars` (see "5.4 Push the template" — they're not secret, just easier to keep alongside the rest) and push as usual:

```hcl
use_sdn_ipam = "true"   # quoted - see the note on non-string variables in 5.4
sdn_zone     = "ws"
sdn_vnet     = "wsnet"
```

```bash
coder templates push lxc-claude-task -d .
```

**Test this on a throwaway workspace first.** This changes how the container's network interface is configured (a fixed `hwaddr` is now set, matching the MAC registered in IPAM) and adds a destroy-time cleanup step (`scripts/release_sdn_ip.sh`) that releases the IPAM reservation when a workspace is deleted. If that cleanup ever fails (e.g. Proxmox unreachable at delete time), it only logs a warning — it won't block the delete — but you may need to remove the stale entry manually under **Datacenter → SDN → IPAM**.

---

## Optional: Go live (managed hosting — promote a site to permanent production)

For a managed-offering setup where customers never touch Coder themselves (your team builds sites in dev workspaces, customers only give design input): a "Go live" button that takes the site currently running in a dev workspace and deploys it to a **permanent, Coder-independent** production LXC, reachable under the customer's own domain via [Pangolin](https://pangolin.net) (tunneled reverse proxy — the production LXC needs no public IP or inbound firewall rule).

This is a genuinely separate piece of infrastructure from the rest of this template, not just a Terraform variable. Three moving parts:

- **`registry/`** — a self-hosted private Docker registry (plain `registry:2`) that dev workspaces push finished images to, and production LXCs pull from. See [`registry/README.md`](registry/README.md).
- **`admin-ui/`** — a small, **dauerhaft laufende** (always-on, not per-workspace) web app that owns all the credentials this needs (Proxmox API token, the dedicated go-live SSH key, registry credentials, optionally a Pangolin API key) and does the actual provisioning. Lists every live customer site, lets you redeploy a new image or tear a site down **at any time** through the browser, instead of SSHing in by hand. See [`admin-ui/README.md`](admin-ui/README.md) for setup.
- **`go-live/`** — the Terraform stack that actually creates the production LXC (unchanged in shape, now called by `admin-ui/` instead of from inside a dev workspace — see below for why, and [`go-live/README.md`](go-live/README.md) for details).
- **Two `coder_app` buttons** inside the dev workspace (only when `golive_enabled = true`): **"Go live (Image pushen)"** runs one short, non-interactive terminal command that pushes the running demo container's image to the registry, then prints a link into the admin-ui's "new site" form with the image already filled in. **"Site-Verwaltung"** opens the admin-ui directly in a new tab (no terminal at all) — everything else (site name, domain, Newt credentials, status, redeploys, deletion) happens there, in a proper web form instead of terminal prompts.

**Why centralize into `admin-ui/` instead of running everything from the dev workspace button (the original design)?** Two reasons, found the hard way while building and testing this:
1. **Credentials stayed scattered.** Every dev workspace needed its own copy of the Proxmox token, SSH key and registry/Pangolin credentials just to run the button once. Centralizing them into one long-lived service shrinks the blast radius of a single compromised workspace to "can ask the admin-ui to create a site" rather than "holds the keys to production directly."
2. **No persistent state, no way to change anything later.** The old design ran `terraform apply` fresh inside an ephemeral, non-root dev-workspace container on every click, with no state kept afterwards — updating or removing a live site meant manual SSH (see git history of `go-live/README.md`). `admin-ui/` keeps one persistent Terraform state per site (via `terraform workspace`), so redeploying a new image or tearing a site down is now an ordinary, idempotent action in the UI.

**What's automated vs. manual, and why:** server provisioning, deployment and redeploys are fully automated. Pangolin domain registration (the customer-facing tunnel/routing) can *optionally* be automated too, via Pangolin's own Integration API — see `admin-ui/README.md`'s "Pangolin-Integration" section for exactly what's verified and what isn't (short version: the API shape is reconstructed from documentation search snippets, not confirmed against a live Pangolin instance — test it against one throwaway site before trusting it for a real customer). Without that configured, it falls back to the original fully-manual flow: create the Newt site by hand in Pangolin's UI, paste the Newt ID/secret into the admin-ui's "new site" form. A brand-new customer **apex domain** needs a one-time manual "Add Domain" + DNS verification step in Pangolin either way — that's inherent to proving domain ownership, not something any amount of automation here can skip.

### One-time setup

1. Set up the registry (`registry/README.md`) and note its URL.
2. Set up the admin-ui (`admin-ui/README.md`) — this is where the dedicated go-live SSH key, Proxmox credentials, and (optionally) Pangolin API key now live. Note its URL and the `ADMIN_UI_API_TOKEN` you generate for it.
3. Add to your `terraform.tfvars`:
   ```hcl
   golive_enabled            = "true"
   golive_registry_url       = "10.0.75.1:5000"
   golive_registry_user      = "golive"
   golive_registry_password  = "..."
   golive_admin_ui_url       = "http://10.0.75.1:9000"
   ```
   (No bearer token needed here — the workspace doesn't call the admin-ui's API directly anymore, see below.)
4. `coder templates push lxc-claude-task -d .` — every dev workspace created from here on gets both "Go live" buttons.

### Per-customer flow

1. Build and verify the site in a dev workspace as usual (port 8080 convention, demo button).
2. Click **"Go live (Image pushen)"** in the workspace. It finds the demo container, pushes its image to the registry under a unique tag, and prints a link — no prompts, nothing else to type here.
3. Click that link (or the **"Site-Verwaltung"** button, which is always there): it opens the admin-ui's "new site" form with the image already filled in. Enter the site name and customer domain, and (if Pangolin integration isn't configured) the Newt ID/secret from Pangolin's UI, then submit.
4. Watch the site's status on its detail page — it provisions the production LXC in the background (a couple of minutes). If Pangolin integration is configured, the tunnel/domain binding happens automatically too; otherwise follow the manual Pangolin steps described in `admin-ui/README.md`.
5. For any later change (new image version, taking the site down): do it from the admin-ui's site detail page (reachable any time via the **"Site-Verwaltung"** button), not by SSHing into the production LXC by hand.

### Security note

Dev workspaces no longer carry live Proxmox/SSH/registry credentials, nor even a token for the admin-ui — the push script needs only registry push access, and the admin-ui's web UI has its own separate login. The admin-ui itself holds the real credentials and should be reachable only from your internal network (see `admin-ui/README.md`).

---

## Template structure

```
.
├── main.tf                       Main template
├── watchdog.sh.tftpl              Keeps Claude Code/agentapi running reliably
├── terraform.tfvars.example       Commented template for your terraform.tfvars
├── scripts/
│   ├── lib_proxmox.sh             Shared curl-with-retry helper, sourced by the scripts below
│   ├── find_free_ip.sh            Default IP assignment, backed by the Proxmox API (not ping)
│   ├── get_cluster_load.sh        Live load display for multi-node selection, any cluster size
│   ├── allocate_sdn_ip.sh         Optional: atomic IP allocation via Proxmox SDN + IPAM
│   ├── release_sdn_ip.sh          Optional: releases the SDN+IPAM reservation on workspace destroy
│   └── go-live.sh.tftpl           Optional: the "Go live" button's script (pushes image, calls admin-ui), templated into each workspace
├── registry/                      Optional: self-hosted private Docker registry for "Go live" images
├── go-live/                       Optional: Terraform stack that provisions production LXCs, called by admin-ui/
└── admin-ui/                      Optional: always-on web app that manages live "Go live" sites
```

### Key design decisions

**Coder agent as a systemd service instead of a direct SSH call**
The agent runs as its own systemd service with `Restart=always` instead of being launched directly by the SSH provisioner — this prevents the Terraform connection from blocking indefinitely (the agent runs permanently in the foreground).

**Watchdog for Claude Code**
The automatic boot-time start of `agentapi` (the wrapper that embeds Claude Code into the Coder web UI) has no built-in restart mechanism. A cron job checks `localhost:3284/status` every minute and restarts it if needed.

**Persistence instead of recreation**
Originally, `count = data.coder_workspace.me.start_count` destroyed the entire container on every stop and created a brand-new one on start. This is now fixed: `count` was removed, `start` only controls power state, and `lifecycle.ignore_changes` prevents unwanted recreation due to IP/template changes.

**`coder_parameter` vs. `coder_workspace_preset`**
The Tasks flow (AI prompt text field) doesn't display raw `coder_parameter` values (official Coder behavior) — only presets. Size selection therefore goes through three `coder_workspace_preset` blocks (note: `data` block, not `resource`), one per size, setting only `instance_size`. Node choice and confirmation-mode are deliberately *not* duplicated into presets (that used to be 13 presets covering every size × node × mode combination — confusing, and redundant with the parameters themselves) — they stay plain `coder_parameter`s with sensible defaults, visible and changeable in the regular "Create workspace" form.

**Scripts talk to the Proxmox API, not to the network directly**
`find_free_ip.sh` and `get_cluster_load.sh` both call the Proxmox REST API (with `jq` for JSON parsing) instead of doing ICMP pings or ad-hoc string parsing. `get_cluster_load.sh` returns every node in the cluster (not a hardcoded pair), so the node dropdown (`data.coder_parameter.target_node` in `main.tf`) is generated dynamically via a `dynamic "option"` block. `find_free_ip.sh` determines "used" IPs from the actual `net0`/`ipconfig0` config of every VM/LXC in the cluster rather than pinging — this also catches stopped containers, which don't respond to ping but still hold their IP. Note: this still isn't a fully atomic reservation between two simultaneous `terraform apply` runs; see "Known open issues" below.

**Secrets live in one file on the workspace, not scattered across several**
The Coder agent token and the Claude OAuth token are written once to `/etc/coder-agent.env` (`chmod 600`, root-only) inside the LXC, and both the `coder-agent` systemd service (via `EnvironmentFile=`) and the watchdog script source that same file — instead of each having their own copy of the secrets on disk.

**`onboot = true` on the LXC**
Without it, a Proxmox **host** reboot leaves every workspace container stopped — Proxmox only auto-starts containers flagged `onboot` when the host comes back up, independent of whatever Coder's database thinks the workspace's last state was. This is unrelated to Coder's own stop/start handling (`start = data.coder_workspace.me.start_count == 1`), which only controls what happens on a Terraform apply, not on a bare-metal reboot.

**`curl_retry` (`scripts/lib_proxmox.sh`) instead of a bare `curl`**
Terraform re-evaluates `data "external"` sources on *every* apply — including a plain start/stop of a workspace that already exists, not just on creation. That means `find_free_ip.sh`/`get_cluster_load.sh`/`allocate_sdn_ip.sh` hit the Proxmox API on every single workspace action. A brief connection hiccup (e.g. the few seconds right after a Proxmox host or service restart, while the API is still coming up) would otherwise fail the whole apply and block starting *any* workspace, even ones that need no new IP. `curl_retry` retries with exponential backoff, but only on genuine connection-level failures (DNS/connect/timeout/TLS/empty-reply) — a real HTTP error (wrong credentials, permissions) still fails immediately rather than retrying a request that would fail the same way five times in a row.

**Port-8080 convention enforced via a global `CLAUDE.md`, not just prompt wording**
The demo button is hardcoded to `http://localhost:8080`. Relying on every prompt explicitly saying "fixed port mapping -p 8080:80" is fragile — forget it once and you get a 502. The agent's startup script now drops that instruction into `/root/.claude/CLAUDE.md`, which Claude Code reads as standing context regardless of what a given prompt says.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| SSH timeout during creation | Network/switch delay on first boot | Wait, optionally increase the timeout in the template |
| Workspaces don't come back after a Proxmox **host** reboot | Containers need `onboot=1` to auto-start when Proxmox itself boots — already set in this template (`onboot = true`), but if you're on an older pushed template version this fix predates, push again | `coder templates push lxc-claude-task -d .` to pick up the current template, then re-create or manually `pct start` any workspace that was created under the old version |
| Starting *any* existing workspace fails right after restarting Proxmox/its services | The Proxmox API can take a few seconds to come back up fully; `data "external"` sources (IP/node lookups) re-run on every apply and would fail if the API isn't ready yet | Should self-resolve now (`curl_retry` retries connection failures with backoff) — if it still fails after that, the outage outlasted the retry window; just try the start again a bit later |
| `agentapi` 502 in web UI | Watchdog hasn't kicked in yet | Wait 1–2 min, cron runs every minute |
| Claude asks to log in | OAuth token missing/wrong | Check `/etc/coder-agent.env` inside the LXC (`cat /etc/coder-agent.env`) |
| "Invalid host header" | `AGENTAPI_ALLOWED_HOSTS` missing | Set in the watchdog script, verify it |
| Demo button greyed out | `subdomain = true` without wildcard DNS configured | Set to `subdomain = false` |
| Demo button gives "502 Bad Gateway / connection was refused" on port 8080 | The site's Docker container is running on a different (often random) port, not 8080 — check with `docker ps` inside the workspace | Recreate it with the port pinned: `docker stop <name> && docker rm <name> && docker run -d --name <name> -p 8080:80 <image>`. Going forward, always spell out "fixed port mapping -p 8080:80" in the prompt (see "Important for the demo button") |
| "vm not found" during creation | Known bug in the provider's `clone` attribute | Use `ostemplate` instead of `clone` |
| Claude Code fails to install / `ECONNREFUSED downloads.claude.ai` | Brief network hiccup, often when creating workspaces in parallel | Reinstall manually: `curl -fsSL https://claude.ai/install.sh -o /tmp/i.sh && bash /tmp/i.sh`, then trigger the watchdog |
| `scripts/*.sh` fail with "jq ist nicht installiert" | `jq` missing where the provisioner actually runs (the `coder` container itself in a Docker Compose setup — installing on the Docker host doesn't help) | See "5.4 Push the template" for the static-binary bind-mount fix |
| `terraform plan`/`push` fails with a TLS error against Proxmox | `pm_tls_insecure` is now `false` by default | Import the Proxmox certificate (see "1.3 Trust the Proxmox certificate"), or explicitly pass `pm_tls_insecure=true` if you accept the risk |
| `allocate_sdn_ip.sh` fails with "sdn_zone/sdn_vnet sind nicht gesetzt" | `use_sdn_ipam=true` without `sdn_zone`/`sdn_vnet` | Pass both variables (see "Optional: SDN + IPAM") |
| `allocate_sdn_ip.sh` fails with a 5xx that isn't "IP already exist" | Zone/VNet/Subnet not set up correctly, or the token lacks `SDN.Allocate` permission | Check **Datacenter → SDN** is applied, and that the API token's role includes `SDN.Allocate` on `/sdn/zones/<zone>/<vnet>` |
| "Go live" button fails with "golive_admin_ui_url ist nicht gesetzt" | That `terraform.tfvars` value is missing or empty | Set `golive_admin_ui_url` (see "Optional: Go live" → step 3) and push the template again |
| The link printed by "Go live (Image pushen)" doesn't open / "Site-Verwaltung" button doesn't load | Workspace's browser session can't reach `golive_admin_ui_url` over the network, or the admin-ui container isn't running | Check the admin-ui is up (`docker compose ps` in `admin-ui/`) and reachable from wherever you open Coder's web UI in a browser (not just from the Proxmox LXC subnet) |
| A site's status stays stuck on `provisioning_lxc` / shows an error | Check `last_error` on the site's detail page in the admin-ui, and `docker compose logs -f admin-ui` for the full terraform output | Fix the underlying issue (same debugging as any terraform apply against this repo), then redeploy/retry from the UI |

---

## Known open issues

- **`dangerously_skip_permissions`** doesn't work while Claude Code runs as `root` (the default in this setup) — worked around via the `IS_SANDBOX=1` environment variable
- **Watchdog doesn't detect a missing Claude installation**: if the initial install fails entirely (e.g. network error), the watchdog currently only checks whether `agentapi` is running — not whether `claude` itself is installed. Manual reinstallation is required in that case (see Troubleshooting)
- **No live failover for running workspaces**: node selection only applies at creation time. A running workspace is never automatically migrated to another node, even if its node becomes heavily loaded
- **IP allocation is atomic only if you opt into SDN+IPAM**: by default, `find_free_ip.sh` reads the actually-configured IPs from every VM/LXC via the Proxmox API instead of pinging, which is far more reliable than ping, but two `terraform apply` runs racing at the exact same moment could in theory still pick the same "free" IP. Setting `use_sdn_ipam = true` (see "Optional: SDN + IPAM" above) closes this gap using Proxmox's own IPAM locking — but it's opt-in, not the default, since it needs a one-time SDN setup on the Proxmox side first. Note: the `telmate/proxmox` provider pinned here can't read back a container's IP when `network.ip = "dhcp"` ([open upstream issue](https://github.com/Telmate/terraform-provider-proxmox/issues/1453)), which is why even the SDN path pre-allocates the IP via the IPAM API and assigns it statically, rather than letting the container DHCP it at boot.
- **Pangolin API automation in `admin-ui/` is unverified against a live instance**: `admin-ui/app/pangolin_client.py` automates Site/Resource/Target creation via Pangolin's Integration API, but the endpoint paths/request/response shapes are reconstructed from documentation search snippets (direct access to `docs.pangolin.net` is DNS-blocked from this repo's development sandbox) plus a third-party reference tool, not from reading the actual Swagger spec. See the big comment at the top of that file and `admin-ui/README.md`'s "Pangolin-Integration" section before relying on it for a real customer — test against one throwaway site first, and diff against `<your-pangolin-url>/v1/docs`. Leaving `PANGOLIN_API_URL`/`KEY`/`ORG_ID` unset falls back to the original fully-manual Pangolin flow.
- **`go-live/`'s Newt container env vars are unverified against a live Pangolin instance**: `docker run ... -e PANGOLIN_ENDPOINT=... -e NEWT_ID=... -e NEWT_SECRET=... fosrl/newt` in `go-live/main.tf` is based on documented Newt configuration conventions, but this repo's development environment couldn't reach `docs.pangolin.net`/the Newt GitHub repo to confirm the exact env var names for the version you're running. Double-check against [github.com/fosrl/newt](https://github.com/fosrl/newt) before your first real "Go live" — if the names differ, the container will just fail to connect (visible immediately as "Offline" in Pangolin's Sites list), not silently misbehave.
- **admin-ui serializes all terraform runs through one lock**: `provision_site`/`teardown_site` run in a background Python thread per request, but all actual `terraform` invocations go through a single lock (`app/terraform_runner.py`) to prevent two simultaneous "Go live" clicks from racing on the shared `go-live/` working directory's selected-workspace state. Correct, but means a second click waits for the first site's apply to finish rather than running in parallel — fine for the "handful of customer sites, one admin clicking at a time" scale this was built for; worth revisiting (a real job queue, one working directory per site) if usage grows.
- **One shared, static SSH key for every workspace, forever**: `proxmox_lxc.workspace.ssh_public_keys` uses the same key (`~/.ssh/coder-ssh-key` on the Coder host) for every workspace it has ever created. If that key leaks, every existing *and future* workspace is reachable as root until someone manually rotates it everywhere. There's no per-workspace key, no expiry, no rotation story. Low risk for a single trusted operator; a real gap the moment more than one person can trigger workspace creation.
- **`use_sdn_ipam=true` claims a fresh IP on every workspace start/stop, not just on creation**: Terraform re-evaluates `data "external"` sources on every apply, including a plain restart of an already-existing workspace. `allocate_sdn_ip.sh` has no way to know "this workspace already has an IP, don't claim a new one" — each restart burns one more IP in the configured range, orphaned in Proxmox's IPAM (the actual container keeps its original IP, since `network` is in `ignore_changes`, but the spurious claim still sits in **Datacenter → SDN → IPAM**). Over enough start/stop cycles, this can exhaust the configured range even though far fewer workspaces are actually running. Not a problem for the default (non-SDN) path, which only *reads* state and never claims anything. Until this is fixed, periodically check **Datacenter → SDN → IPAM** for stale entries if you have `use_sdn_ipam` on, or just don't enable it in a workspace mix with frequent restarts yet.

---

## License

[MIT](LICENSE). Use at your own risk. Not an official Coder or Anthropic product.
