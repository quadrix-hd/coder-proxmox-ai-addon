# Optional client for Pangolin's "Integration API" (REST, Bearer-token
# auth, enabled per self-hosted instance under Server Admin / org API
# keys). Only used when PANGOLIN_API_URL + PANGOLIN_API_KEY + PANGOLIN_ORG_ID
# are all set - otherwise the UI falls back to the fully manual flow this
# repo already documented (create the Newt site by hand in Pangolin's own
# web UI, paste the shown Newt ID/secret into the "new site" form here).
#
# UNVERIFIED AGAINST A LIVE PANGOLIN INSTANCE: direct HTTP access to
# docs.pangolin.net was DNS-blocked from the sandbox this was built in, same
# as when go-live/main.tf's Newt env-var names were written. The endpoint
# paths, request bodies and response envelope ("data" wrapper) below are
# reconstructed from search-indexed snippets of the official docs
# (docs.pangolin.net/manage/common-api-routes, /manage/integration-api) plus
# a third-party open-source tool (github.com/ktsouvalis/charmer) that
# automates the same site-creation flow - not from reading the actual
# Swagger spec or source. Before trusting this against real customers:
#   1. Open <your-pangolin-url>/v1/docs (Swagger UI) and diff it against
#      the method/path/body shapes used here.
#   2. Create one throwaway test site through the admin-ui and verify in
#      Pangolin's own UI that the Site/Resource/Target actually appear
#      correctly before relying on this for a paying customer.
# A GitHub issue (fosrl/pangolin#1344) also shows at least one of these
# request bodies changed between Pangolin versions (a `siteId` field that
# used to be required on the resource-create call was later rejected) -
# so this is version-sensitive, not just unverified.
import requests

API_VERSION = "v1"


class PangolinError(RuntimeError):
    pass


class PangolinClient:
    def __init__(self, base_url: str, api_key: str, org_id: str):
        self.base_url = base_url.rstrip("/")
        self.org_id = org_id
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {api_key}"
        self.session.headers["Content-Type"] = "application/json"

    def _url(self, path: str) -> str:
        return f"{self.base_url}/{API_VERSION}{path}"

    def _request(self, method: str, path: str, **kwargs) -> dict:
        resp = self.session.request(method, self._url(path), timeout=30, **kwargs)
        if not resp.ok:
            raise PangolinError(f"{method} {path} -> {resp.status_code}: {resp.text[:500]}")
        body = resp.json()
        # Pangolin's documented responses wrap the payload in a "data" key;
        # fall back to the raw body if a given endpoint doesn't.
        return body.get("data", body) if isinstance(body, dict) else body

    def list_domains(self) -> list:
        """Base domains already registered (and DNS-verified) in Pangolin.
        A brand-new customer apex domain still needs a one-time manual
        "Add Domain" + DNS verification step in Pangolin's UI first - that
        part is inherent to domain ownership verification, not something
        this client can skip. Pick an existing domainId here for
        subdomains under a domain you already verified once."""
        return self._request("GET", f"/org/{self.org_id}/domains")

    def create_newt_site(self, site_name: str) -> dict:
        """Creates a Pangolin "Site" (Newt tunnel endpoint) for one
        customer, fully via API - no manual click-through. Returns a dict
        with at least siteId/newtId/secret, used to feed the production
        LXC's `docker run ... fosrl/newt` invocation in go-live/main.tf."""
        defaults = self._request("GET", f"/org/{self.org_id}/pick-site-defaults")
        body = {
            "name": site_name,
            "type": "newt",
            "address": defaults.get("clientAddress") or defaults.get("address"),
            "newtId": defaults["newtId"],
            "secret": defaults.get("newtSecret") or defaults.get("secret"),
        }
        return self._request("PUT", f"/org/{self.org_id}/site", json=body)

    def delete_site(self, site_id: str):
        self._request("DELETE", f"/org/{self.org_id}/site/{site_id}")

    def create_public_resource(self, name: str, domain_id: str, subdomain: str) -> dict:
        body = {
            "name": name,
            "http": True,
            "protocol": "tcp",
            "domainId": domain_id,
            "subdomain": subdomain,
        }
        return self._request("PUT", f"/org/{self.org_id}/public-resource", json=body)

    def delete_resource(self, resource_id: str):
        self._request("DELETE", f"/public-resource/{resource_id}")

    def add_target(self, resource_id: str, site_id: str, ip: str, port: int = 8080):
        body = {"siteId": site_id, "ip": ip, "port": port, "method": "http"}
        return self._request("PUT", f"/public-resource/{resource_id}/target", json=body)


def client_from_env(env: dict):
    """Returns a configured PangolinClient, or None if integration isn't
    configured (the normal/manual-fallback case)."""
    base_url = env.get("PANGOLIN_API_URL", "").strip()
    api_key = env.get("PANGOLIN_API_KEY", "").strip()
    org_id = env.get("PANGOLIN_ORG_ID", "").strip()
    if not (base_url and api_key and org_id):
        return None
    return PangolinClient(base_url, api_key, org_id)
