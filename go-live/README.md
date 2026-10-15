# Go live

Takes a finished site built in a dev workspace and deploys it to a
permanent, Coder-independent production LXC, connected to the outside
world via [Pangolin](https://pangolin.net) (tunneled reverse proxy — no
public IP needed on the production LXC itself).

**This stack itself is unchanged in shape** (same resource, same
variables) — what changed is *who calls it*. It's no longer run from
inside an ephemeral dev workspace on every "Go live" click; it's now
called by [`../admin-ui/`](../admin-ui/README.md), a small always-on
service that keeps one persistent Terraform state per customer site (via
`terraform workspace`) so updates and teardowns are ordinary, idempotent
operations instead of manual SSH. See the main README's "Optional: Go
live" section for the full picture and why this changed.

You normally never run this directory's `terraform` commands directly —
use the admin-ui's web interface instead. The manual instructions below
remain for debugging or if you want to provision a one-off site without
setting up the admin-ui at all.

## Running it manually (debugging / one-off, bypassing admin-ui)

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
terraform workspace new kundenname-website   # isolates this site's state - matches what admin-ui does automatically
terraform init
terraform apply
```

You'll still need a Newt site created in Pangolin first (manually, or via
`admin-ui`'s Pangolin client used standalone) to get `newt_id`/`newt_secret`
— see the main README's "Optional: Go live" section.

## Updating or removing a site provisioned this way

Since you created it outside admin-ui's tracking, it also won't show up in
admin-ui's site list. Use plain Terraform in this directory with the same
workspace selected:

```bash
terraform workspace select kundenname-website
terraform apply   -var docker_image=kundenname-website:new-tag   # update
terraform destroy                                                # remove
```

If you provisioned a site through the admin-ui instead (the normal path),
manage it from there — it already has this directory's state, under the
same `terraform workspace` mechanism, in its own persistent volume.
