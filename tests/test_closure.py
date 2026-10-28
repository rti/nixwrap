"""Host-side argument checks; tests.nix exercises actual sandbox isolation."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


WRAP = Path(__file__).resolve().parents[1] / "wrap.sh"
ROOT = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-app"
DEP = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-lib"
EXTRA = "/nix/store/cccccccccccccccccccccccccccccccc-extra"


class ClosureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = dict(os.environ, HOME=str(self.directory), TMPDIR=str(self.directory),
                        PATH=f"{self.directory}:/usr/bin:/bin",
                        NIX_PROFILES=str(self.directory / "profile"))
        (self.directory / "profile").mkdir()
        self.script("bwrap", '#!/usr/bin/python3\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
        self.script("readlink", '#!/bin/bash\nif [[ "$3" == /nix/store/* ]]; then\n'
                    'printf "%s\\n" "$3"\nelse\nexec /usr/bin/readlink "$@"\nfi\n')
        self.script("nix-store", '#!/bin/bash\n'
                    '[[ ! -v QUERY_FAIL ]] || exit 1\nshift 2\n'
                    'printf "%s\\n" "$@"\nprintf "%s\\n" ' + DEP + '\n')

    def script(self, name, content):
        path = self.directory / name
        path.write_text(content)
        path.chmod(0o755)

    def launch(self, *args):
        return subprocess.run(["/bin/bash", str(WRAP), "-p", *args, ROOT + "/bin/app"],
                              cwd=self.directory, env=self.env, text=True, capture_output=True)

    def options(self, *args):
        result = self.launch(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def read_only_sources(self, args):
        return [args[index + 1] for index, value in enumerate(args) if value == "--ro-bind"]

    def test_full_store_and_profiles_remain_default(self):
        args = self.options()
        if Path("/nix").is_dir():
            self.assertIn("/nix", self.read_only_sources(args))
        self.assertIn(self.env["NIX_PROFILES"], self.read_only_sources(args))
        self.assertNotIn("--remount-ro", args)

    def test_only_closure_is_mounted(self):
        args = self.options("-s", ROOT)
        self.assertNotIn("/nix", args)
        self.assertNotIn(self.env["NIX_PROFILES"], self.read_only_sources(args))
        start = args.index("--tmpfs", args.index("--tmpfs") + 1)
        self.assertEqual(args[start:start + 10], ["--tmpfs", "/nix/store",
                         "--ro-bind", ROOT, ROOT, "--ro-bind", DEP, DEP,
                         "--remount-ro", "/nix/store"])

    def test_multiple_roots(self):
        args = self.options("-s", ROOT, "-s", EXTRA)
        self.assertIn(EXTRA, args)
        self.assertIn(DEP, args)

    def test_invalid_root_does_not_launch(self):
        result = self.launch("-s", str(self.directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("closure root", result.stderr)

    def test_query_failure_does_not_launch(self):
        self.env["QUERY_FAIL"] = "1"
        result = self.launch("-s", ROOT)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
