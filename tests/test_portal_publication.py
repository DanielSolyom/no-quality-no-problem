"""Verify the real portal publisher with only its HTTP boundary replaced."""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class PortalPublication(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy2(ROOT / "publish.sh", self.root / "publish.sh")
        mod = self.root / "no-quality-no-problem"
        mod.mkdir()
        info = {"name": "no-quality-no-problem", "version": "1.0.5"}
        (mod / "info.json").write_text(json.dumps(info))
        (self.root / "portal.json").write_text(json.dumps({"title": "Test mod"}))
        self.archive = self.root / "no-quality-no-problem_1.0.5.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("no-quality-no-problem_1.0.5/info.json", json.dumps(info))
            archive.writestr(
                "no-quality-no-problem_1.0.5/data.lua", "-- tested source\n"
            )
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        # Rebuilding must never occur when an already-tested zip is supplied.
        build = self.root / "build.sh"
        build.write_text('#!/bin/sh\ntouch "$TEST_ROOT/rebuilt"\nexit 99\n')
        build.chmod(0o755)
        tools = self.root / "bin"
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(
            """#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith("https://"))
with open(os.environ["TEST_ROOT"] + "/requests", "a") as log:
    if url.startswith("https://mods.factorio.com/api/mods/no-quality-no-problem/full?"):
        log.write("metadata\\n")
        print(json.dumps({"releases": [{"version": "1.0.5"}] if os.environ.get("EXISTS") else []}))
    elif url.endswith("/releases/init_upload"):
        log.write("init\\n")
        print(json.dumps({"upload_url": "https://example.invalid/upload"}))
    elif url == "https://example.invalid/upload":
        form = args[args.index("-F") + 1]
        archive = pathlib.Path(form.removeprefix("file=@").split(";", 1)[0])
        log.write("upload:" + hashlib.sha256(archive.read_bytes()).hexdigest() + "\\n")
        print(json.dumps({"success": True}))
    elif url.endswith("/edit_details"):
        log.write("details\\n")
        print(json.dumps({"success": True}))
    else:
        raise SystemExit("Unexpected HTTP request: " + url)
"""
        )
        curl.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "FACTORIO_API_KEY": "test-only-no-real-credentials",
            "TEST_ROOT": str(self.root),
        }

    def publish(self, **env):
        return subprocess.run(
            ["bash", "publish.sh", "--zip", str(self.archive), "--sync-details"],
            cwd=self.root,
            env={**self.env, **env},
            text=True,
            capture_output=True,
            check=False,
        )

    def test_uploads_exact_validated_bytes_without_rebuilding(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "requests").read_text().splitlines(),
            ["metadata", "init", "upload:" + self.digest, "details"],
        )
        self.assertFalse((self.root / "rebuilt").exists())

    def test_retry_skips_existing_version_but_finishes_page_sync(self):
        result = self.publish(EXISTS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.root / "requests").read_text().splitlines(), ["metadata", "details"]
        )
        self.assertFalse((self.root / "rebuilt").exists())

    def test_wrong_archive_version_stops_before_http(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr(
                "no-quality-no-problem_1.0.5/info.json",
                json.dumps({"name": "no-quality-no-problem", "version": "1.0.6"}),
            )
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "requests").exists())


if __name__ == "__main__":
    unittest.main()
