import os
import threading

from flask import Flask, jsonify, redirect, render_template, request, session, url_for

from . import db, provisioning
from .auth import check_api_token, check_password, login_required
from .pangolin_client import client_from_env


def create_app():
    app = Flask(__name__)
    app.secret_key = os.environ.get("SECRET_KEY", "")
    if not app.secret_key:
        raise RuntimeError("SECRET_KEY must be set (see admin-ui/README.md)")

    db.init_db()

    @app.get("/")
    def index():
        return redirect(url_for("sites_list"))

    @app.get("/login")
    def login():
        return render_template("login.html", error=None)

    @app.post("/login")
    def login_submit():
        password = request.form.get("password", "")
        if check_password(password):
            session["logged_in"] = True
            next_url = request.args.get("next") or url_for("sites_list")
            return redirect(next_url)
        return render_template("login.html", error="Falsches Passwort."), 401

    @app.post("/logout")
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.get("/sites")
    @login_required
    def sites_list():
        return render_template("sites_list.html", sites=db.list_sites())

    @app.get("/sites/new")
    @login_required
    def site_new():
        pangolin = client_from_env(os.environ)
        domains = []
        pangolin_error = None
        if pangolin:
            try:
                domains = pangolin.list_domains()
            except Exception as exc:  # noqa: BLE001 - show it in the form, don't crash the page
                pangolin_error = str(exc)
        return render_template(
            "site_new.html",
            pangolin_enabled=bool(pangolin),
            domains=domains,
            pangolin_error=pangolin_error,
        )

    @app.post("/sites/new")
    @login_required
    def site_new_submit():
        site_name = request.form["site_name"].strip()
        customer_domain = request.form.get("customer_domain", "").strip()
        docker_image = request.form["docker_image"].strip()
        newt_id = request.form.get("newt_id", "").strip()
        newt_secret = request.form.get("newt_secret", "").strip()
        pangolin_domain_id = request.form.get("pangolin_domain_id", "").strip()
        pangolin_subdomain = request.form.get("pangolin_subdomain", "").strip()

        if db.site_exists(site_name):
            return render_template("site_new.html", error=f"'{site_name}' existiert schon.",
                                    pangolin_enabled=bool(client_from_env(os.environ)), domains=[]), 400

        db.create_site(site_name, customer_domain, docker_image)
        _start_provisioning(site_name, customer_domain, docker_image, newt_id, newt_secret,
                             pangolin_domain_id, pangolin_subdomain)
        return redirect(url_for("site_detail", site_name=site_name))

    @app.get("/sites/<site_name>")
    @login_required
    def site_detail(site_name):
        site = db.get_site(site_name)
        if not site:
            return "Nicht gefunden", 404
        return render_template("site_detail.html", site=site)

    @app.post("/sites/<site_name>/redeploy")
    @login_required
    def site_redeploy(site_name):
        site = db.get_site(site_name)
        if not site:
            return "Nicht gefunden", 404
        new_tag = request.form["docker_image"].strip()
        from . import ssh_runner
        try:
            ssh_runner.redeploy_image(
                site["production_ip"],
                os.environ["REGISTRY_URL"],
                os.environ["REGISTRY_USER"],
                os.environ["REGISTRY_PASSWORD"],
                new_tag,
            )
            db.update_site(site_name, docker_image=new_tag, status="live", last_error="")
        except Exception as exc:  # noqa: BLE001
            db.update_site(site_name, status="error", last_error=f"Redeploy fehlgeschlagen: {exc}")
        return redirect(url_for("site_detail", site_name=site_name))

    @app.post("/sites/<site_name>/delete")
    @login_required
    def site_delete(site_name):
        threading.Thread(target=provisioning.teardown_site, args=(site_name,), daemon=True).start()
        return redirect(url_for("sites_list"))

    # --- JSON API for the dev-workspace "Go live" button ---

    @app.post("/api/sites")
    def api_create_site():
        if not check_api_token(request.headers.get("Authorization", "")):
            return jsonify(error="unauthorized"), 401
        payload = request.get_json(force=True, silent=True) or {}
        site_name = (payload.get("site_name") or "").strip()
        docker_image = (payload.get("docker_image") or "").strip()
        customer_domain = (payload.get("customer_domain") or "").strip()
        if not site_name or not docker_image:
            return jsonify(error="site_name and docker_image are required"), 400
        if db.site_exists(site_name):
            return jsonify(error=f"site '{site_name}' already exists - use the web UI to redeploy instead"), 409

        db.create_site(site_name, customer_domain, docker_image)
        _start_provisioning(
            site_name, customer_domain, docker_image,
            payload.get("newt_id", ""), payload.get("newt_secret", ""),
            payload.get("pangolin_domain_id", ""), payload.get("pangolin_subdomain", ""),
        )
        base_url = os.environ.get("ADMIN_UI_PUBLIC_URL", request.host_url.rstrip("/"))
        return jsonify(status="provisioning", status_url=f"{base_url}/sites/{site_name}"), 202

    @app.get("/api/sites/<site_name>")
    def api_site_status(site_name):
        if not check_api_token(request.headers.get("Authorization", "")):
            return jsonify(error="unauthorized"), 401
        site = db.get_site(site_name)
        if not site:
            return jsonify(error="not found"), 404
        return jsonify(site)

    return app


def _start_provisioning(site_name, customer_domain, docker_image, newt_id, newt_secret,
                         pangolin_domain_id, pangolin_subdomain):
    threading.Thread(
        target=provisioning.provision_site,
        args=(site_name, customer_domain, docker_image, newt_id, newt_secret,
              pangolin_domain_id, pangolin_subdomain),
        daemon=True,
    ).start()


app = create_app()
