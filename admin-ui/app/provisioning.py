# Orchestrates one "Go live" request end-to-end: optionally talks to
# Pangolin, then calls terraform_runner against the unchanged go-live/
# stack, then records the result. Runs in a background thread (see main.py)
# since LXC creation + Docker install realistically takes a couple of
# minutes - callers get a "provisioning" status immediately and poll the
# site detail page/API for completion.
import os
import traceback

from . import db
from .pangolin_client import PangolinError, client_from_env
from .terraform_runner import TerraformError, apply_site, destroy_site

REQUIRED_ENV = [
    "PM_API_URL",
    "PM_API_TOKEN_ID",
    "PM_API_TOKEN_SECRET",
    "LXC_SUBNET",
    "LXC_GATEWAY",
    "LXC_VLAN_TAG",
    "TARGET_NODE",
    "REGISTRY_URL",
    "REGISTRY_USER",
    "REGISTRY_PASSWORD",
]

SSH_PUBLIC_KEY_PATH = "/data/ssh/golive_id_rsa.pub"
SSH_PRIVATE_KEY_PATH = "/data/ssh/golive_id_rsa"


def _common_vars() -> dict:
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        raise RuntimeError(f"admin-ui is missing required config: {', '.join(missing)} (see admin-ui/README.md)")
    with open(SSH_PUBLIC_KEY_PATH) as f:
        ssh_public_key = f.read()
    with open(SSH_PRIVATE_KEY_PATH) as f:
        ssh_private_key = f.read()
    return {
        "pm_api_url": os.environ["PM_API_URL"],
        "pm_api_token_id": os.environ["PM_API_TOKEN_ID"],
        "pm_api_token_secret": os.environ["PM_API_TOKEN_SECRET"],
        "pm_tls_insecure": os.environ.get("PM_TLS_INSECURE", "false").lower() == "true",
        "target_node": os.environ["TARGET_NODE"],
        "lxc_subnet": os.environ["LXC_SUBNET"],
        "lxc_gateway": os.environ["LXC_GATEWAY"],
        "lxc_vlan_tag": int(os.environ["LXC_VLAN_TAG"]),
        "ssh_public_key": ssh_public_key,
        "ssh_private_key": ssh_private_key,
        "registry_url": os.environ["REGISTRY_URL"],
        "registry_user": os.environ["REGISTRY_USER"],
        "registry_password": os.environ["REGISTRY_PASSWORD"],
        "newt_endpoint": os.environ.get("PANGOLIN_NEWT_ENDPOINT", ""),
    }


def provision_site(site_name: str, customer_domain: str, docker_image: str,
                    newt_id: str = "", newt_secret: str = "",
                    pangolin_domain_id: str = "", pangolin_subdomain: str = ""):
    """Runs synchronously in a background thread - updates the DB row as it
    goes so the UI can show live progress/failure instead of just success
    or silence."""
    pangolin = client_from_env(os.environ)
    pangolin_site_id = ""
    pangolin_resource_id = ""
    pangolin_managed = bool(pangolin)

    try:
        if pangolin:
            db.update_site(site_name, status="creating_pangolin_site")
            site_resp = pangolin.create_newt_site(site_name)
            pangolin_site_id = str(site_resp.get("siteId", ""))
            newt_id = str(site_resp.get("newtId", newt_id))
            newt_secret = str(site_resp.get("secret", newt_secret))
            if not (newt_id and newt_secret):
                raise RuntimeError(
                    "Pangolin site created but response had no newtId/secret - "
                    "check PangolinClient.create_newt_site against your Pangolin "
                    "version's actual response shape (see pangolin_client.py comment)."
                )

        if not (newt_id and newt_secret):
            raise RuntimeError(
                "No Newt ID/secret available. Either configure PANGOLIN_API_URL/"
                "KEY/ORG_ID for automatic site creation, or create the Newt site "
                "manually in Pangolin's UI first and pass newt_id/newt_secret."
            )

        db.update_site(site_name, status="provisioning_lxc")
        variables = {
            **_common_vars(),
            "site_name": site_name,
            "customer_domain": customer_domain,
            "docker_image": docker_image,
            "newt_id": newt_id,
            "newt_secret": newt_secret,
        }
        outputs = apply_site(site_name, variables)
        production_ip = outputs.get("production_ip", "")

        if pangolin and pangolin_domain_id and pangolin_subdomain:
            db.update_site(site_name, status="creating_pangolin_resource")
            resource_resp = pangolin.create_public_resource(site_name, pangolin_domain_id, pangolin_subdomain)
            pangolin_resource_id = str(resource_resp.get("resourceId", ""))
            if pangolin_resource_id and pangolin_site_id:
                pangolin.add_target(pangolin_resource_id, pangolin_site_id, production_ip, 8080)

        db.update_site(
            site_name,
            status="live",
            production_ip=production_ip,
            target_node=variables["target_node"],
            pangolin_site_id=pangolin_site_id,
            pangolin_resource_id=pangolin_resource_id,
            pangolin_managed=1 if pangolin_managed else 0,
            last_error="",
        )
    except (TerraformError, PangolinError, RuntimeError, OSError) as exc:
        db.update_site(site_name, status="error", last_error=str(exc))
    except Exception:
        db.update_site(site_name, status="error", last_error=traceback.format_exc()[-2000:])


def teardown_site(site_name: str):
    row = db.get_site(site_name)
    if not row:
        return
    db.update_site(site_name, status="deleting")
    try:
        variables = {
            **_common_vars(),
            "site_name": site_name,
            "customer_domain": row["customer_domain"],
            "docker_image": row["docker_image"],
            # destroy doesn't need a *valid* newt_id/secret, only *some*
            # value so the variable is satisfied - the resource holding it
            # is being destroyed either way.
            "newt_id": "destroying",
            "newt_secret": "destroying",
        }
        destroy_site(site_name, variables)

        pangolin = client_from_env(os.environ)
        if pangolin:
            if row["pangolin_resource_id"]:
                pangolin.delete_resource(row["pangolin_resource_id"])
            if row["pangolin_site_id"]:
                pangolin.delete_site(row["pangolin_site_id"])

        db.delete_site(site_name)
    except (TerraformError, PangolinError, RuntimeError, OSError) as exc:
        db.update_site(site_name, status="error", last_error=f"Teardown failed: {exc}")
