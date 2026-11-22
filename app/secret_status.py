import hashlib
import json
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import URLError
from urllib.parse import quote, urlsplit
from urllib.request import ProxyHandler, Request, build_opener


IMDS_TOKEN_URL = (
    "http://169.254.169.254/metadata/identity/oauth2/token"
    "?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"
)


def _request_json(request):
    opener = build_opener(ProxyHandler({}))
    with opener.open(request, timeout=5) as response:
        return json.load(response)


def read_key_vault_secret():
    vault_uri = os.environ.get("KEY_VAULT_URI", "").rstrip("/")
    secret_name = os.environ.get("KEY_VAULT_SECRET_NAME", "")
    if not vault_uri or not secret_name:
        raise ValueError("Key Vault configuration is missing")

    token_request = Request(IMDS_TOKEN_URL, headers={"Metadata": "true"})
    token_response = _request_json(token_request)
    access_token = token_response.get("access_token")
    if not access_token:
        raise ValueError("Managed identity token is missing")

    secret_url = (
        f"{vault_uri}/secrets/{quote(secret_name, safe='')}?api-version=7.4"
    )
    secret_request = Request(
        secret_url,
        headers={"Authorization": f"Bearer {access_token}"},
    )
    secret_response = _request_json(secret_request)
    secret_value = secret_response.get("value")
    if not isinstance(secret_value, str):
        raise ValueError("Key Vault returned no secret value")
    return secret_value


def secret_summary(secret_value):
    return {
        "status": "ok",
        "secret_length": len(secret_value),
        "sha256_prefix": hashlib.sha256(
            secret_value.encode("utf-8")
        ).hexdigest()[:12],
    }


class SecretStatusHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if urlsplit(self.path).path != "/secret-check":
            self._send_json(404, {"status": "not_found"})
            return

        try:
            response = secret_summary(read_key_vault_secret())
        except (URLError, TimeoutError, ValueError, KeyError) as error:
            logging.warning(
                "Key Vault secret check failed (%s)", type(error).__name__
            )
            self._send_json(503, {"status": "error", "reason": "secret_unavailable"})
            return

        self._send_json(200, response)

    def _send_json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    ThreadingHTTPServer(("127.0.0.1", 8080), SecretStatusHandler).serve_forever()
