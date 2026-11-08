"""Run generated JSON through an actual Xray binary and the intended geo assets.

RNM_XRAY_BIN=/path/to/xray RNM_XRAY_ASSETS=/path/to/assets python3 tests/test_xray_runtime.py
RNM_BASH may point to Git Bash on Windows. No live proxies or user credentials needed.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("RNM_BASH") or shutil.which("bash")
XRAY = os.environ.get("RNM_XRAY_BIN")


def generated(body):
    result = subprocess.run(
        [BASH, "-c", 'source install.sh; load_module clients; ' + body],
        cwd=ROOT, check=True, capture_output=True, text=True, encoding="utf-8",
    )
    return json.loads(result.stdout)


@unittest.skipUnless(XRAY and BASH, "Set RNM_XRAY_BIN to run real Xray validation")
class XrayRuntimeTests(unittest.TestCase):
    def validate(self, config):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "config.json"
            target.write_text(json.dumps(config), encoding="utf-8")
            env = os.environ.copy()
            if env.get("RNM_XRAY_ASSETS"):
                env["XRAY_LOCATION_ASSET"] = env["RNM_XRAY_ASSETS"]
            result = subprocess.run(
                [XRAY, "run", "-test", "-config", str(target)],
                env=env, capture_output=True, text=True, encoding="utf-8", errors="replace",
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_single_template(self):
        config = generated("client_template_json")
        stored = json.loads((ROOT / "templates/subscriptions/xray-ru-direct.json").read_text(encoding="utf-8"))
        self.assertEqual(config, stored)
        # Simulate Panel injection without disclosing a real subscriber UUID.
        config.pop("remnawave")
        config["outbounds"].insert(0, {"tag": "proxy", "protocol": "freedom"})
        self.validate(config)

    def test_balancer_template(self):
        config = generated("client_template_json '[\"11111111-1111-4111-8111-111111111111\",\"22222222-2222-4222-8222-222222222222\"]'")
        config.pop("remnawave")
        config["outbounds"] = [
            {"tag": "proxy", "protocol": "freedom"},
            {"tag": "proxy-2", "protocol": "freedom"},
        ] + config["outbounds"]
        self.validate(config)

    def test_server_profile(self):
        config = generated("build_node_profile_json")
        self.validate(config)

    def test_selfsteal_reality_inbounds(self):
        key_output = subprocess.run([XRAY, "x25519"], check=True, capture_output=True, text=True).stdout
        key = re.search(r"Private\s*Key:\s*(\S+)", key_output, re.I).group(1)
        config = generated("""
          RAW_ENABLED=1 XHTTP_ENABLED=1 DOMAIN=node.example.com
          RAW_SHORT_IDS_JSON='["0123456789abcdef"]'
          XHTTP_SHORT_IDS_JSON='["fedcba9876543210"]'
          XHTTP_PATH=/assets/test REALITY_PRIVATE_KEY=""" + key + """
          build_node_profile_json
        """)
        expected = json.loads((ROOT / "tests/fixtures/selfsteal-profile.json").read_text(encoding="utf-8"))
        expected["inbounds"][0]["streamSettings"]["realitySettings"]["privateKey"] = key
        self.assertEqual(config["inbounds"][0], expected["inbounds"][0])
        self.validate(config)


if __name__ == "__main__":
    unittest.main()
