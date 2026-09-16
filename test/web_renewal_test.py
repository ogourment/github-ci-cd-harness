"""Exercise the rendered web role against real, unprivileged nginx."""
import http.client
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

from jinja2 import Environment, StrictUndefined

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "priv/ansible/roles/web/templates/app.nginx.j2"

def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

class WebRenewalTest(unittest.TestCase):
    def test_existing_webroot_survives_http_and_https_provisioning(self):
        nginx = os.environ.get("NGINX_BINARY") or shutil.which("nginx")
        self.assertTrue(nginx, "Install nginx or set NGINX_BINARY")
        for tls in (False, True):
            with self.subTest(tls=tls), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                challenge = root / "webroot/.well-known/acme-challenge"
                challenge.mkdir(parents=True)
                (challenge / "token").write_text("expected-proof")
                subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-nodes", "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
                    "-days", "1", "-subj", "/CN=example.test"], check=True, capture_output=True)
                port, tls_port = free_port(), free_port()
                values = dict(server_name="example.test", server_aliases=["www.example.test"],
                    ssl_enabled=tls, nginx_connection_upgrade_var="test_upgrade",
                    certbot_webroot=str(root / "webroot"), nginx_uploads_dir="",
                    nginx_uploads_url_prefix="", nginx_upstream_name="test_app",
                    nginx_proxy_connect_timeout="1s", nginx_proxy_read_timeout="1s",
                    nginx_proxy_send_timeout="1s", nginx_proxy_next_upstream="error timeout",
                    nginx_proxy_next_upstream_tries=2, app_is_production=True,
                    nginx_drop_scanner_probes=True, nginx_https_extra_locations="")
                rendered = Environment(undefined=StrictUndefined).from_string(TEMPLATE.read_text()).render(**values)
                rendered = rendered.replace("listen 80;", f"listen 127.0.0.1:{port};")
                rendered = rendered.replace("listen 443 ssl http2;", f"listen 127.0.0.1:{tls_port} ssl;")
                rendered = rendered.replace("/etc/letsencrypt/live/example.test/fullchain.pem", str(root / "cert.pem"))
                rendered = rendered.replace("/etc/letsencrypt/live/example.test/privkey.pem", str(root / "key.pem"))
                rendered = rendered.replace("/var/log/nginx/", str(root) + "/")
                config = root / "nginx.conf"
                config.write_text(f"daemon off; pid {root}/nginx.pid; error_log {root}/error.log;\n"
                    f"events {{}} http {{ client_body_temp_path {root}/client; proxy_temp_path {root}/proxy; "
                    f"fastcgi_temp_path {root}/fastcgi; uwsgi_temp_path {root}/uwsgi; scgi_temp_path {root}/scgi; "
                    f"access_log off; upstream test_app {{ server 127.0.0.1:1; }}\n{rendered}\n}}")
                proc = subprocess.Popen([nginx, "-p", str(root), "-c", str(config)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    for _ in range(100):
                        if proc.poll() is not None:
                            self.fail(proc.communicate()[1].decode() + (root / "error.log").read_text())
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.05)
                    for host in ("example.test", "www.example.test"):
                        for path, expected in (("/.well-known/acme-challenge/token", 200),
                                               ("/.well-known/acme-challenge/missing", 404)):
                            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                            conn.request("GET", path, headers={"Host": host})
                            response = conn.getresponse()
                            body = response.read()
                            conn.close()
                            self.assertEqual(response.status, expected, body)
                            if expected == 200:
                                self.assertEqual(body, b"expected-proof")
                    if tls:
                        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                        conn.request("GET", "/", headers={"Host": "www.example.test"})
                        response = conn.getresponse()
                        self.assertEqual(response.status, 301)
                        self.assertEqual(response.getheader("Location"), "https://example.test/")
                        response.read()
                        conn.close()
                finally:
                    proc.terminate()
                    proc.communicate(timeout=5)


    def test_renewal_hook_only_reloads_matching_certificate_after_validation(self):
        template = ROOT / "priv/ansible/roles/web/templates/renew-nginx.sh.j2"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            hook = root / "hook.sh"
            hook.write_text(Environment(undefined=StrictUndefined).from_string(
                template.read_text()).render(server_name="example.test"))
            log = root / "calls"
            for name in ("nginx", "systemctl"):
                exe = root / name
                exe.write_text('#!/bin/sh\nprintf "%s\\n" "' + name +
                    ' $*" >> "$CALL_LOG"\n' +
                    ('exit "${NGINX_STATUS:-0}"\n' if name == "nginx" else 'exit 0\n'))
                exe.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       CALL_LOG=str(log))
            for lineage, nginx_status, expected_code, expected in (
                ("/etc/letsencrypt/live/unrelated.test", "0", 0, ""),
                ("/etc/letsencrypt/live/example.test", "0", 0,
                 "nginx -t\nsystemctl reload nginx\n"),
                ("/etc/letsencrypt/live/example.test", "1", 1, "nginx -t\n"),
            ):
                with self.subTest(lineage=lineage, nginx_status=nginx_status):
                    log.write_text("")
                    result = subprocess.run(["sh", str(hook)], env=dict(env,
                        RENEWED_LINEAGE=lineage, NGINX_STATUS=nginx_status), capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    self.assertEqual(log.read_text(), expected)


if __name__ == "__main__":
    unittest.main()
