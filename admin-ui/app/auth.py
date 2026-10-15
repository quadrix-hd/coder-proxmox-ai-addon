import hmac
import os
from functools import wraps

from flask import redirect, request, session, url_for
from werkzeug.security import check_password_hash

ADMIN_PASSWORD_HASH = os.environ.get("ADMIN_UI_PASSWORD_HASH", "")
API_TOKEN = os.environ.get("ADMIN_UI_API_TOKEN", "")


def check_password(password: str) -> bool:
    if not ADMIN_PASSWORD_HASH:
        return False
    return check_password_hash(ADMIN_PASSWORD_HASH, password)


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


def check_api_token(auth_header: str) -> bool:
    if not API_TOKEN:
        return False
    if not auth_header or not auth_header.startswith("Bearer "):
        return False
    token = auth_header[len("Bearer "):]
    return hmac.compare_digest(token, API_TOKEN)
