"""Exercise the actual embedded Compose transformer without a Docker daemon."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CODE = (ROOT / "install.sh").read_text(encoding="utf-8").split("compose_edit() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]


class ComposeTests(unittest.TestCase):
    def transform(self, document, action, argument="", success=True):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "in.yml", Path(directory) / "out.yml"
            original = json.dumps(document)
            source.write_text(original, encoding="utf-8")
            args = [str(source), str(output), action, "custom-node", "nginx:alpine", "0", "0", "0", argument,
                    "/usr/local/share/xray", "roscom-geosite.dat", "roscom-geoip.dat"]
            result = subprocess.run([sys.executable, "-c", CODE, *args], capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(source.read_text(encoding="utf-8"), original)
            if not success:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
                return None
            self.assertEqual(result.returncode, 0, result.stderr)
            return yaml.safe_load(output.read_text(encoding="utf-8"))

    def base(self):
        return {"services": {"custom-node": {"image": "remnawave/node:latest", "environment": {"SECRET_KEY": "test"},
                  "volumes": ["/srv/custom:/custom:ro"]}, "unrelated": {"image": "redis:alpine"}}, "networks": {"existing": {}}}

    def test_add_and_remove_core_preserve_other_settings(self):
        original = self.base()
        changed = self.transform(original, "core-add", "/opt/remnanode/rnm-cores/vtest/xray")
        self.assertEqual(changed["services"]["unrelated"], original["services"]["unrelated"])
        self.assertEqual(changed["networks"], original["networks"])
        self.assertEqual(changed["services"]["custom-node"]["environment"], {"SECRET_KEY": "test"})
        self.assertEqual(len(changed["services"]["custom-node"]["volumes"]), 2)
        self.assertEqual(self.transform(changed, "core-remove"), original)

    def test_refuse_foreign_core_mount(self):
        original = self.base()
        original["services"]["custom-node"]["volumes"].append({"type": "bind", "source": "/srv/foreign-xray", "target": "/usr/local/bin/xray"})
        self.transform(original, "core-add", "/opt/remnanode/rnm-cores/vtest/xray", success=False)
        self.transform(original, "core-remove", success=False)

    def test_replace_managed_short_mount(self):
        original = self.base()
        original["services"]["custom-node"]["volumes"].append("/opt/remnanode/rnm-cores/old/xray:/usr/local/bin/xray:ro")
        changed = self.transform(original, "core-add", "/opt/remnanode/rnm-cores/new/xray")
        self.assertEqual(len(changed["services"]["custom-node"]["volumes"]), 2)
        self.assertEqual(changed["services"]["custom-node"]["volumes"][-1]["source"], "/opt/remnanode/rnm-cores/new/xray")

    def test_selfsteal_add_preserves_services(self):
        original = self.base()
        changed = self.transform(original, "selfsteal-add")
        nginx = changed["services"]["nginx-selfsteal"]
        self.assertEqual(nginx["network_mode"], "host")
        self.assertEqual(changed["services"]["custom-node"]["depends_on"]["nginx-selfsteal"]["condition"], "service_healthy")
        self.assertEqual(changed["services"]["unrelated"], original["services"]["unrelated"])


if __name__ == "__main__":
    unittest.main()
