# Wraps the unchanged go-live/main.tf stack (from the repo this admin-ui
# ships in) via `terraform workspace`, so every customer site gets its own
# isolated, *persistent* state - instead of each "Go live" run starting from
# scratch inside an ephemeral dev workspace with no state carried over (the
# old design, see go-live/README.md's "no shared state" warning). A plain
# "terraform workspace" here is Terraform's own CLI feature for multiple
# named states in one working directory - unrelated to a Coder workspace,
# despite the shared name.
import json
import os
import subprocess
import tempfile
import threading

GOLIVE_DIR = os.environ.get("GOLIVE_DIR", "/data/go-live")
TF_TIMEOUT = int(os.environ.get("TERRAFORM_TIMEOUT_SECONDS", "900"))

# `terraform workspace select` + the following apply/destroy/output share
# one on-disk "currently selected workspace" marker in GOLIVE_DIR - two
# provisioning requests running in overlapping background threads (see
# main.py/provisioning.py) could otherwise select each other's workspace
# out from under one another mid-operation. This process is single-worker
# (see admin-ui/README.md), so a plain lock serializing all terraform runs
# is enough; it just means a second "Go live" click waits for the first to
# finish rather than running in parallel.
_TF_LOCK = threading.Lock()


class TerraformError(RuntimeError):
    def __init__(self, action: str, result: subprocess.CompletedProcess):
        self.action = action
        self.result = result
        super().__init__(
            f"terraform {action} failed (exit {result.returncode}):\n{result.stdout}\n{result.stderr}"
        )


def _run(args, cwd=GOLIVE_DIR):
    return subprocess.run(
        ["terraform", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=TF_TIMEOUT,
    )


def _ensure_init():
    marker = os.path.join(GOLIVE_DIR, ".terraform", "terraform.tfstate")
    if os.path.exists(marker):
        return
    result = _run(["init", "-input=false"])
    if result.returncode != 0:
        raise TerraformError("init", result)


def _select_workspace(site_name: str):
    result = _run(["workspace", "select", site_name])
    if result.returncode != 0:
        result = _run(["workspace", "new", site_name])
        if result.returncode != 0:
            raise TerraformError("workspace new", result)


def _write_tfvars_file(variables: dict) -> str:
    # Sensitive values (registry/SSH/Proxmox/Newt secrets) go through a
    # 0600 tempfile and -var-file, never -var on the CLI - a bare -var
    # shows up in `ps aux` for the whole duration of the apply, same class
    # of leak fixed elsewhere in this repo (GIT_ASKPASS, --password-stdin).
    fd, path = tempfile.mkstemp(suffix=".auto.tfvars.json", dir="/tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(variables, f)
    os.chmod(path, 0o600)
    return path


def apply_site(site_name: str, variables: dict) -> dict:
    """Runs terraform apply for one site's isolated workspace/state.
    Returns parsed `terraform output -json`."""
    with _TF_LOCK:
        _ensure_init()
        _select_workspace(site_name)
        varfile = _write_tfvars_file(variables)
        try:
            result = _run(["apply", "-auto-approve", "-input=false", f"-var-file={varfile}"])
            if result.returncode != 0:
                raise TerraformError("apply", result)
        finally:
            os.remove(varfile)

        output_result = _run(["output", "-json"])
        if output_result.returncode != 0:
            raise TerraformError("output", output_result)
        raw = json.loads(output_result.stdout)
        return {k: v.get("value") for k, v in raw.items()}


def destroy_site(site_name: str, variables: dict):
    with _TF_LOCK:
        _ensure_init()
        result = _run(["workspace", "select", site_name])
        if result.returncode != 0:
            # Nothing to destroy - workspace/state never existed.
            return
        varfile = _write_tfvars_file(variables)
        try:
            result = _run(["destroy", "-auto-approve", "-input=false", f"-var-file={varfile}"])
            if result.returncode != 0:
                raise TerraformError("destroy", result)
        finally:
            os.remove(varfile)

        _run(["workspace", "select", "default"])
        _run(["workspace", "delete", site_name])
