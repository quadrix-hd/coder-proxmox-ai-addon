# Private Docker registry for "Go live"

A plain, self-hosted instance of [Docker Distribution](https://github.com/distribution/distribution)
(`registry:2` — the same open-source project Docker Hub itself runs on),
with basic-auth. Dev workspaces push finished site images here; production
LXCs created by the `go-live/` Terraform stack pull from here. Runs
unauthenticated-by-TLS on your internal network — it's meant to sit behind
your existing VLAN isolation, not be exposed to the internet. Add TLS in
front of it (e.g. your existing reverse proxy) if that assumption doesn't
hold for your network.

## One-time setup

On whatever host should run the registry (can be the same Docker host as
Coder, or a separate machine — just needs to be reachable from both dev
workspaces and production LXCs):

```bash
mkdir -p auth
docker run --rm httpd:2.4-alpine htpasswd -Bbn golive 'CHOOSE-A-PASSWORD' > auth/htpasswd
docker compose up -d
```

Note the host:port you end up running this on (e.g. `10.0.75.1:5000` or a
hostname) — you'll need it as `registry_url` in both:
- the main workspace template's `terraform.tfvars` (`golive_registry_url`,
  `golive_registry_user`, `golive_registry_password`), so the "Go live"
  button inside dev workspaces can push to it
- `go-live/terraform.tfvars` (same three values), so the production LXC
  provisioning can pull from it

## Trusting it from Docker clients

Since this runs over plain HTTP (no TLS), every Docker daemon that talks to
it — inside dev workspaces *and* on production LXCs — needs to explicitly
allow it as an "insecure registry". The main template's `startup_script`
and `go-live/main.tf`'s provisioner both already do this automatically
(writing `/etc/docker/daemon.json` with `insecure-registries`) as long as
`golive_registry_url`/`registry_url` is set correctly — nothing to do here
beyond making sure that value matches where this registry actually runs.

## Cleanup

This registry keeps every image you ever push, forever — there's no
automatic garbage collection. Periodically run:

```bash
docker compose exec registry bin/registry garbage-collect /etc/docker/registry/config.yml
```

after deleting tags you no longer need (`docker exec -it <container>
registry garbage-collect` won't reclaim space for a tag that's still
referenced — delete the tag via the registry API first).
