#!/usr/bin/env python3
"""Check CLI release selection without building, pushing, or deleting real images.

Usage: python3 tests/test-release-selection.py
Requires PyYAML (CI installs the pinned version in an isolated environment).
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CLI = ["base", "node", "python", "rust", "go"]
MICROVM = ["base", "node", "python"]
DEFERRED = re.compile(r"devcontainer|desktop", re.IGNORECASE)
SPY = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["SELECTION_LOG"], "a") as log:
    log.write(json.dumps([Path(sys.argv[0]).name, *args]) + "\n")
if Path(sys.argv[0]).name == "npm":
    sys.exit(99)
if args and args[0] == "build":
    sys.exit(int(os.environ.get("BUILD_EXIT", "0")))
if args and args[0] == "info":
    sys.exit(1)
if args and args[0] == "inspect":
    print(os.environ.get("INSPECT_ARCH", "arm64"))
if args and args[0] == "images":
    for tag in ["base", "node", "python", "rust", "go", "microvm-base", "microvm-node", "microvm-python", "devcontainer", "desktop"]:
        print(f"sixways-sandbox:{tag} 1MB")
if args[:3] == ["buildx", "imagetools", "inspect"]:
    print("sha256:" + "a" * 64)
"""


def workflow(path):
    return yaml.safe_load((ROOT / ".forgejo/workflows" / path).read_text())


def steps(path):
    return [step for job in workflow(path)["jobs"].values() for step in job["steps"]]


def executable_text(step):
    script = "\n".join(
        line
        for line in step.get("run", "").splitlines()
        if not line.lstrip().startswith("#")
    )
    return script + json.dumps(step.get("env", {})) + json.dumps(step.get("with", {}))


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sixways-selection-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name in ["docker", "npm"]:
            path = self.bin / name
            path.write_text(SPY)
            path.chmod(0o755)
        self.log = self.directory / "calls.jsonl"
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}:{os.environ['PATH']}",
            SELECTION_LOG=str(self.log),
            INSPECT_ARCH="arm64",
        )

    def run_script(self, path, *args, env=None):
        return subprocess.run(
            ["/bin/bash", str(path), *args],
            cwd=ROOT,
            env=env or self.env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def calls(self):
        return (
            [json.loads(line) for line in self.log.read_text().splitlines()]
            if self.log.exists()
            else []
        )

    def test_local_build_only_builds_cli_chain_on_both_architectures(self):
        for arch in ["arm64", "amd64"]:
            with self.subTest(arch=arch):
                self.log.unlink(missing_ok=True)
                result = self.run_script(
                    ROOT / "build.sh", arch, env=dict(self.env, INSPECT_ARCH=arch)
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls()
                builds = [call for call in calls if call[1:2] == ["build"]]
                self.assertEqual(
                    [call[call.index("-f") + 1] for call in builds],
                    [f"{variant}/Dockerfile" for variant in CLI],
                )
                for call in builds:
                    self.assertEqual(
                        call[call.index("--platform") + 1], f"linux/{arch}"
                    )
                self.assertFalse(any(call[0] == "npm" for call in calls))
                self.assertFalse(DEFERRED.search(result.stdout))
                self.assertIn(
                    [
                        "docker",
                        "inspect",
                        "sixways-sandbox:base",
                        "--format",
                        "{{.Architecture}}",
                    ],
                    calls,
                )

    def test_deferred_build_requests_do_not_run_docker(self):
        for target in ["devcontainer", "desktop"]:
            result = self.run_script(ROOT / "build.sh", target)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])

    def test_failed_base_build_stops_the_chain(self):
        result = self.run_script(
            ROOT / "build.sh", "arm64", env=dict(self.env, BUILD_EXIT="42")
        )
        self.assertEqual(result.returncode, 42)
        self.assertEqual(len(self.calls()), 1)

    def test_architecture_mismatch_fails_verification(self):
        result = self.run_script(
            ROOT / "build.sh", "arm64", env=dict(self.env, INSPECT_ARCH="amd64")
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected arm64 but got amd64", result.stdout)

    def test_default_and_all_image_suites_select_only_cli(self):
        for args in [[], ["all"]]:
            result = self.run_script(ROOT / "tests/test-sandbox-images.sh", *args)
            # Deliberately stop at docker-info so no image or container is used.
            self.assertEqual(result.returncode, 2)
            self.assertIn(f"Variants: {' '.join(CLI)}", result.stdout)
            self.assertFalse(DEFERRED.search(result.stdout))
        self.assertTrue(all(call == ["docker", "info"] for call in self.calls()))

    def test_windows_build_recipes_match_cli_release(self):
        script = (ROOT / "build.bat").read_text()
        executable = "\n".join(
            line
            for line in script.splitlines()
            if not line.lstrip().upper().startswith("REM")
        )
        self.assertEqual(re.findall(r"-f (\w+)/Dockerfile", executable), CLI)
        self.assertFalse(DEFERRED.search(executable))
        self.assertIsNone(re.search(r"^\s*(?:call )?npm ", executable, re.MULTILINE))
        self.assertIn("docker inspect sixways-sandbox:base", executable)

    @unittest.skipUnless(
        (ROOT / ".forgejo/workflows").is_dir(),
        "Private release workflows are omitted from public snapshots",
    )
    def test_workflow_build_sign_verify_promote_and_scan_exclude_deferred_images(self):
        for path in [
            "sandbox-images.yaml",
            "ghcr-publish-signed.yaml",
            "security.yaml",
            "sign-sandbox-manifests.yaml",
            "verify-signatures.yaml",
        ]:
            for step in steps(path):
                with self.subTest(workflow=path, step=step.get("name")):
                    self.assertFalse(DEFERRED.search(executable_text(step)))
        public = steps("ghcr-publish-signed.yaml")
        builds = "\n".join(
            step.get("run", "")
            for step in public
            if step.get("name", "").startswith("Push ")
        )
        self.assertEqual(re.findall(r"-f (\w+)/Dockerfile", builds), CLI)
        for operation in ["sign_attach", "verify", "promote"]:
            tags = []
            for step in public:
                tags.extend(
                    re.findall(
                        rf"^\s*{operation} (\w+) ", step.get("run", ""), re.MULTILINE
                    )
                )
            self.assertEqual([tag for tag in tags if tag != "latest"], CLI)
        dev = "\n".join(step.get("run", "") for step in steps("sandbox-images.yaml"))
        self.assertEqual(re.findall(r"^\s*build_push (\w+) ", dev, re.MULTILINE), CLI)
        self.assertEqual(
            re.findall(r"for variant in ([\w ]+); do", dev),
            [" ".join(CLI), " ".join(CLI)],
        )
        for path in ["sign-sandbox-manifests.yaml", "verify-signatures.yaml"]:
            scripts = "\n".join(step.get("run", "") for step in steps(path))
            required = re.findall(
                r"for tag in ([\w ]+); do\n\s+\w+ \"\$tag\" true", scripts
            )
            self.assertTrue(required)
            self.assertTrue(all(tags.split() == CLI for tags in required))

    @unittest.skipUnless(
        (ROOT / "scripts/build-microvm.sh").is_file(),
        "Premium microVM source is omitted from public snapshots",
    )
    def test_microvm_default_build_variants_are_retained(self):
        # Run the existing helper in a fixture repository with pre-staged binaries.
        fixture = self.directory / "sandbox"
        scripts = fixture / "scripts"
        scripts.mkdir(parents=True)
        helper = scripts / "build-microvm.sh"
        helper.write_text((ROOT / "scripts/build-microvm.sh").read_text())
        artifacts = fixture / "microvm/_artifacts"
        artifacts.mkdir(parents=True)
        for binary in [
            "sixways-sandbox-init",
            "sixways-mcp-proxy",
            "sixways-microvm-ebpf-agent",
        ]:
            path = artifacts / binary
            path.write_text("fixture binary\n")
            path.chmod(0o755)
        result = self.run_script(helper, "--skip-binaries")
        self.assertEqual(result.returncode, 0, result.stderr)
        builds = [call for call in self.calls() if call[1:2] == ["build"]]
        self.assertEqual(
            [call[call.index("-t") + 1] for call in builds],
            [f"sixways-sandbox:microvm-{variant}" for variant in MICROVM],
        )
        for call in builds:
            self.assertEqual(call[call.index("--platform") + 1], "linux/amd64")
        microvm_ci = "\n".join(
            step.get("run", "") for step in steps("microvm-images.yaml")
        )
        self.assertEqual(
            re.findall(r"for variant in ([\w ]+); do", microvm_ci),
            [" ".join(MICROVM), " ".join(MICROVM)],
        )

    @unittest.skipUnless(
        (ROOT / "scripts/publish-public.sh").is_file(),
        "Private publishing tool is omitted from public snapshots",
    )
    def test_public_snapshot_prunes_deferred_source(self):
        script = (ROOT / "scripts/publish-public.sh").read_text()
        prune = re.search(r"PRUNE_PATHS=\((.*?)\n\)", script, re.DOTALL).group(1)
        # Evaluate only the actual prune array, never the publishing tool.
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                f'PRUNE_PATHS=({prune}\n)\nprintf "%s\\n" "${{PRUNE_PATHS[@]}}"',
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        paths = result.stdout.splitlines()
        self.assertIn("devcontainer", paths)
        self.assertIn("desktop", paths)
        self.assertIn("microvm", paths)

    def test_default_freshness_check_does_not_resolve_selkies(self):
        result = self.run_script(ROOT / "scripts/refresh-base-digests.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        resolves = [
            call
            for call in self.calls()
            if call[1:4] == ["buildx", "imagetools", "inspect"]
        ]
        self.assertEqual(len(resolves), 1)
        self.assertIn("cgr.dev/chainguard/wolfi-base:latest", resolves[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
