# Build context is the REPO ROOT (see docker-compose.yml's `build.context: ..`),
# not admin-ui/ itself - this image ships its own copy of go-live/, so there's
# no runtime git clone of this repo (that was the old, more fragile design:
# see the git history of main.tf's golive_enabled block for the bugs that
# caused - private-repo auth, wrong branch, missing unzip inside an ad-hoc
# dev-workspace container). Rebuilding/redeploying this image is now the
# explicit way to pick up go-live/ changes, which is also just more correct
# for anything calling itself infrastructure-as-code.
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl unzip openssh-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG TERRAFORM_VERSION=1.9.8
RUN curl -fsSL -o /tmp/tf.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip -o /tmp/tf.zip -d /usr/local/bin \
    && rm -f /tmp/tf.zip

WORKDIR /srv

COPY admin-ui/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY admin-ui/app ./app
COPY go-live /data/go-live
COPY scripts /data/scripts

# Explicitly create every directory a named volume will later be mounted
# over (db, tfstate, tfcache) - otherwise Docker creates the mount point as
# root:root on first start, which the non-root adminui user below can't
# write into.
RUN mkdir -p /data/ssh /data/db /data/go-live/terraform.tfstate.d /data/go-live/.terraform \
    && useradd -u 1000 -m adminui \
    && chown -R adminui:adminui /data /srv
USER adminui

EXPOSE 9000
CMD ["python", "-m", "gunicorn", "--bind", "0.0.0.0:9000", "--workers", "1", "--timeout", "120", "app.main:app"]
