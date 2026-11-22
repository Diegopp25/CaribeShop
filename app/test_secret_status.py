import hashlib
import http.client
import io
import json
import os
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from urllib.error import URLError

from secret_status import (
    IMDS_TOKEN_URL,
    SecretStatusHandler,
    read_key_vault_secret,
)


class SecretStatusHandlerTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(
            ("127.0.0.1", 0), SecretStatusHandler
        )
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def _get(self, path):
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1]
        )
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read()
        connection.close()
        return response.status, body

    @patch.dict(
        os.environ,
        {
            "KEY_VAULT_URI": "https://kv-example.vault.azure.net/",
            "KEY_VAULT_SECRET_NAME": "caribeshop-demo",
        },
    )
    @patch("secret_status.build_opener")
    def test_reads_secret_using_managed_identity(self, build_opener):
        opener = build_opener.return_value
        opener.open.side_effect = [
            io.BytesIO(b'{"access_token":"managed-identity-token"}'),
            io.BytesIO(b'{"value":"secret-value"}'),
        ]

        value = read_key_vault_secret()

        self.assertEqual(value, "secret-value")
        token_request, secret_request = [
            call.args[0] for call in opener.open.call_args_list
        ]
        self.assertEqual(token_request.full_url, IMDS_TOKEN_URL)
        self.assertEqual(token_request.get_header("Metadata"), "true")
        self.assertEqual(
            secret_request.get_header("Authorization"),
            "Bearer managed-identity-token",
        )
        self.assertIn("/secrets/caribeshop-demo?api-version=7.4", secret_request.full_url)

    @patch("secret_status.read_key_vault_secret")
    def test_returns_secret_fingerprint_without_secret_value(self, read_secret):
        secret = "demo-secret-that-must-not-be-returned"
        read_secret.return_value = secret

        status, body = self._get("/secret-check")
        payload = json.loads(body)

        self.assertEqual(status, 200)
        self.assertEqual(payload["secret_length"], len(secret))
        self.assertEqual(
            payload["sha256_prefix"],
            hashlib.sha256(secret.encode("utf-8")).hexdigest()[:12],
        )
        self.assertNotIn(secret.encode("utf-8"), body)

    @patch(
        "secret_status.read_key_vault_secret",
        side_effect=URLError("network unavailable"),
    )
    def test_reports_key_vault_failure_without_details(self, _read_secret):
        status, body = self._get("/secret-check")

        self.assertEqual(status, 503)
        self.assertEqual(
            json.loads(body),
            {"status": "error", "reason": "secret_unavailable"},
        )
        self.assertNotIn(b"network unavailable", body)


if __name__ == "__main__":
    unittest.main()
