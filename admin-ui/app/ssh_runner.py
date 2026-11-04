# Direct SSH for the one thing that doesn't need a full terraform apply:
# swapping the running site container for a newer image tag on an already
# -provisioned production LXC. Shells out to the system `ssh` binary with
# the dedicated go-live key (same key terraform's own remote-exec
# provisioner uses for initial setup) rather than a Python SSH library, to
# keep this container's dependencies minimal and match how the rest of this
# repo already shells out to ssh/terraform/git.
import shlex
import subprocess

SSH_KEY_PATH = "/data/ssh/golive_id_rsa"
SSH_OPTS = [
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ConnectTimeout=10",
    "-i", SSH_KEY_PATH,
]


class SSHError(RuntimeError):
    def __init__(self, result: subprocess.CompletedProcess):
        self.result = result
        super().__init__(f"ssh failed (exit {result.returncode}):\n{result.stdout}\n{result.stderr}")


def run_remote(ip: str, command: str, timeout: int = 120) -> subprocess.CompletedProcess:
    result = subprocess.run(
        ["ssh", *SSH_OPTS, f"root@{ip}", command],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise SSHError(result)
    return result


def redeploy_image(ip: str, registry_url: str, registry_user: str, registry_password: str, image_tag: str):
    # Same docker login/pull/run sequence as go-live/main.tf's initial
    # provisioning and go-live/README.md's documented manual update
    # procedure - this just automates that manual procedure over SSH.
    command = " && ".join(
        [
            f"echo {shlex.quote(registry_password)} | docker login {shlex.quote(registry_url)} -u {shlex.quote(registry_user)} --password-stdin",
            f"docker pull {shlex.quote(registry_url)}/{shlex.quote(image_tag)}",
            "docker stop site >/dev/null 2>&1 || true",
            "docker rm site >/dev/null 2>&1 || true",
            f"docker run -d --name site --restart unless-stopped -p 8080:80 {shlex.quote(registry_url)}/{shlex.quote(image_tag)}",
        ]
    )
    return run_remote(ip, command, timeout=300)
