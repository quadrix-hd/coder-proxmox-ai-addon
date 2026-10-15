# Go live

Takes a finished site built in a dev workspace and deploys it to a
permanent, Coder-independent production LXC, connected to the outside
world via [Pangolin](https://pangolin.net) (tunneled reverse proxy — no
public IP needed on the production LXC itself).

Normally triggered via the "Go live" button inside a dev workspace (see the
main README's "Go live" section), which runs this stack with the right
variables already filled in. You can also run it manually from here.

## One-time setup (per environment, not per customer)

1. **Private registry** running — see `../registry/README.md`.
2. **A dedicated SSH keypair for go-live provisioning**, separate from the
   key used for normal dev workspaces:
   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/golive-ssh-key -N ""
   ```
   `coder templates push` runs Terraform *inside* the `coder` container as
   the non-root `coder` user — same situation as the regular dev-workspace
   key, so this one also needs `chown`ing and bind-mounting into the
   container rather than just referenced by a host path. See the main
   README's "Optional: Go live" section for the exact `chown`/
   `docker-compose.yaml` steps. The private key's in-container path goes
   into every dev workspace (via `golive_ssh_private_key_path` in the main
   template's `terraform.tfvars` — Terraform reads the file directly, no
   need to paste/escape the key content anywhere) so the "Go live" button
   can use it; it's intentionally not the same key used to provision dev workspaces themselves, to keep
   the blast radius of a leak smaller.

## One-time setup (per customer)

In the Pangolin web UI: **Sites → Add Site → Type: Newt**. Give it a name
matching your `site_name` (e.g. `kundenname-website`). Pangolin shows a
Newt ID and Secret **once** — copy both immediately, you'll need them as
`newt_id`/`newt_secret` here. If you lose them, delete the site and
recreate it.

(Not automated here — see the note in the main README about why: the
community Terraform providers for Pangolin weren't verifiable from the
environment this was built in, and getting production domain-routing
automation wrong is worse than a 2-minute manual step.)

## Running it directly

```bash
cd go-live
cat > terraform.tfvars <<'EOF'
pm_api_url           = "https://10.0.10.2:8006/api2/json"
pm_api_token_id      = "root@pam!terraform"
pm_api_token_secret  = "..."
target_node          = "pve"
lxc_subnet           = "10.0.75"
lxc_gateway           = "10.0.75.1"
lxc_vlan_tag          = "75"
ssh_public_key        = "ssh-rsa AAAA..."
ssh_private_key       = "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
site_name             = "kundenname-website"
customer_domain       = "kundenname.example.com"
registry_url          = "10.0.75.1:5000"
registry_user         = "golive"
registry_password     = "..."
docker_image          = "kundenname-website:latest"
newt_endpoint         = "https://pangolin.example.com"
newt_id               = "..."
newt_secret           = "..."
EOF
terraform init
terraform apply
```

## Updating an already-live site

There's no shared Terraform state across runs (see the warning at the top
of `main.tf`) — treat a later update as an operational task, not a
Terraform one:

```bash
# Push a new image tag to the registry, then on the production LXC itself:
ssh root@<production-ip>
docker pull <registry>/<image>:<new-tag>
docker stop site && docker rm site
docker run -d --name site --restart unless-stopped -p 8080:80 <registry>/<image>:<new-tag>
```

## Taking a site down permanently

Delete the LXC directly in the Proxmox UI (or `pct destroy <vmid>` on the
Proxmox host), and remove the corresponding Site in Pangolin. Nothing in
Coder or this Terraform stack tracks these LXCs after creation, so there's
no "undo" command — this is a manual, deliberate action by design, so a
customer's live site is never at risk of being torn down by an unrelated
Terraform change elsewhere in this repo.
