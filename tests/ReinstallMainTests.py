"""Exercise the real updater transaction with a local Git remote and fake apps/tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


WORKER = Path(__file__).resolve().parents[1] / "scripts/reinstall-main.sh"
REMOTE = "https://github.com/eimerreis/eimerrail.git"


class ReinstallMainTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rail updater ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / "cache"
        self.run = self.root / "run"
        self.run.mkdir()
        self.app = self.root / "Installed Rail.app"
        self.app.mkdir()
        (self.app / "version").write_text("old")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", TEST_ROOT=str(self.root))
        self.tool("codesign", '[[ "${TEST_FAILURE:-}" != signature ]]')
        self.tool("ditto", '[[ "${TEST_FAILURE:-}" != copy ]] || exit 1\n/bin/cp -R "$1" "$2"')
        self.tool("open", '''
printf '%s\\n' "$@" >> "$TEST_ROOT/opened"
if [[ "$1" == -n && "${TEST_FAILURE:-}" == launch && "$(cat "$2/version")" == new ]]; then exit 1; fi
''')
        self.tool("mv", '''
if [[ "${TEST_FAILURE:-}" == replace && "$1" == */Eimerrail.app ]]; then exit 1; fi
/bin/mv "$@"
''')
        self.repo = self.root / "remote"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/build.sh").write_text('''#!/bin/bash
set -eu
[[ "${TEST_FAILURE:-}" != build ]] || exit 1
printf '%s\\n' "$@" > "$TEST_ROOT/build-arguments"
mkdir -p "$(dirname "$0")/../build/Release/Eimerrail.app"
echo -n new > "$(dirname "$0")/../build/Release/Eimerrail.app/version"
''')
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Fixture")
        # Fetch the exact production URL using Git's ordinary URL rewriting.
        config = self.root / "gitconfig"
        config.write_text(f'[url "{self.repo}"]\n\tinsteadOf = {REMOTE}\n')
        self.env.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_NOSYSTEM="1")
        self.parent = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(self.stop_parent)

    def git(self, *args):
        subprocess.run(["/usr/bin/git", "-C", str(self.repo), *args], check=True, capture_output=True)

    def tool(self, name, source):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + source + "\n")
        path.chmod(0o755)

    def stop_parent(self):
        if self.parent.poll() is None:
            self.parent.terminate()
        self.parent.wait()

    def start(self, failure=""):
        self.env["TEST_FAILURE"] = failure
        log = (self.run / "update.log").open("w")
        self.addCleanup(log.close)
        worker = subprocess.Popen([
            "/bin/bash", str(WORKER), str(self.cache), str(self.run), str(self.app),
            str(self.parent.pid), "signing identity & spaces", "client-id",
            "--data-dir=/profile with spaces", "--literal=$(touch nope)",
        ], env=self.env, stdout=log, stderr=log)
        self.addCleanup(lambda: worker.wait() if worker.poll() is not None else self.kill_worker(worker))
        return worker

    @staticmethod
    def kill_worker(worker):
        worker.kill()
        worker.wait()

    def ready(self, worker):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if (self.run / "ready").exists():
                return
            if worker.poll() is not None:
                self.fail((self.run / "update.log").read_text())
            time.sleep(0.02)
        self.fail("Worker never signalled readiness")

    def version(self):
        return (self.app / "version").read_text()

    def assert_clean(self):
        self.assertFalse((self.cache / "lock").exists())
        self.assertFalse((self.run / "ready").exists())
        self.assertEqual(list(self.root.glob(".eimerrail-update.*")), [])

    def test_waits_for_exit_then_installs_and_preserves_arguments(self):
        worker = self.start()
        self.ready(worker)
        self.assertEqual(self.version(), "old")
        self.assertIsNone(worker.poll())
        self.stop_parent()
        self.assertEqual(worker.wait(timeout=10), 0)
        self.assertEqual(self.version(), "new")
        self.assertEqual((self.root / "build-arguments").read_text().splitlines(), [
            "-DEIMERRAIL_SIGN_IDENTITY=signing identity & spaces", "-DEIMERRAIL_GITHUB_CLIENT_ID=client-id"])
        self.assertEqual((self.root / "opened").read_text().splitlines(), [
            "-n", str(self.app), "--args", "--data-dir=/profile with spaces", "--literal=$(touch nope)"])
        self.assert_clean()

    def test_preparation_failures_keep_running_app(self):
        for failure in ("build", "signature", "copy"):
            with self.subTest(failure=failure):
                worker = self.start(failure)
                self.assertNotEqual(worker.wait(timeout=10), 0)
                self.assertEqual(self.version(), "old")
                self.assertFalse((self.root / "opened").exists())
                self.assert_clean()

    def test_replace_or_launch_failure_restores_and_reopens_previous_app(self):
        for failure in ("replace", "launch"):
            with self.subTest(failure=failure):
                worker = self.start(failure)
                self.ready(worker)
                self.stop_parent()
                self.assertNotEqual(worker.wait(timeout=10), 0)
                self.assertEqual(self.version(), "old")
                opened = (self.root / "opened").read_text()
                self.assertIn(str(self.run / "update.log"), opened)
                self.assertTrue(opened.endswith("--literal=$(touch nope)\n"))
                self.assert_clean()
                # A fresh process stands in for the reopened original app.
                self.parent = subprocess.Popen(["/bin/sleep", "30"])

    def test_cancelled_shutdown_leaves_original_installed(self):
        self.tool("sleep", "exit 0")
        worker = self.start()
        self.assertNotEqual(worker.wait(timeout=10), 0)
        self.assertEqual(self.version(), "old")
        self.assertFalse((self.root / "opened").exists())
        self.assertIn("Save any unsaved pages", (self.run / "update.log").read_text())
        self.assert_clean()

    def test_concurrent_reinstall_does_not_remove_other_workers_lock(self):
        (self.cache / "lock").mkdir(parents=True)
        worker = self.start()
        self.assertNotEqual(worker.wait(timeout=10), 0)
        self.assertEqual(self.version(), "old")
        self.assertTrue((self.cache / "lock").exists())

    def test_fetch_failure_keeps_current_app(self):
        self.tool("git", "exit 1")
        worker = self.start()
        self.assertNotEqual(worker.wait(timeout=10), 0)
        self.assertEqual(self.version(), "old")
        self.assert_clean()

    def test_repeated_reinstall_fetches_new_main(self):
        for expected in ("new", "newer"):
            if expected == "newer":
                build = self.repo / "scripts/build.sh"
                build.write_text(build.read_text().replace("echo -n new >", "echo -n newer >"))
                self.git("add", ".")
                self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "New main")
                self.parent = subprocess.Popen(["/bin/sleep", "30"])
            worker = self.start()
            self.ready(worker)
            self.stop_parent()
            self.assertEqual(worker.wait(timeout=10), 0)
            self.assertEqual(self.version(), expected)
            self.assert_clean()
        self.assertEqual(subprocess.check_output(["/usr/bin/git", "-C", str(self.repo), "status", "--porcelain"]), b"")


if __name__ == "__main__":
    unittest.main()
