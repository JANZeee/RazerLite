#!/usr/bin/env python3
"""Exercise installation transactions using signed fixtures in a temporary tree.

Never changes HOME, the real Applications folder, app preferences or login items.
The copied /usr/bin/true executable is signed as fixture content but never run.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().with_name("install-local.sh")


class InstallTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="RazerLite-install-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.bundle(self.root / "source/RazerLite.app", "new")
        self.destination = self.root / "Applications/RazerLite.app"
        self.backups = self.root / "InstallBackups"

    def bundle(self, path, marker, identifier="local.RazerLite", configuration="release"):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Resources").mkdir()
        shutil.copyfile("/usr/bin/true", path / "Contents/MacOS/RazerLite")
        (path / "Contents/MacOS/RazerLite").chmod(0o755)
        (path / "Contents/Resources/version.txt").write_text(marker)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "RazerLite",
            "CFBundlePackageType": "APPL", "CFBundleName": "RazerLite",
            "RazerLiteBuildConfiguration": configuration,
        }))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)],
                       check=True, capture_output=True, text=True)
        return path

    def run_install(self, replace=False, fault=""):
        env = os.environ.copy()
        if fault:
            commands = self.root / "test-commands"
            commands.mkdir(exist_ok=True)
            wrapper = commands / "mv"
            wrapper.write_text('''#!/bin/bash
set -euo pipefail
promoting=false
case "$1" in */.RazerLite-install.*/RazerLite.app) promoting=true ;; esac
if [ "$promoting" = true ] && [ "$RAZERLITE_TEST_FAULT" = move ]; then exit 73; fi
if [ "$RAZERLITE_TEST_FAULT" = restore ] && [ "$2" = "$RAZERLITE_TEST_DEST" ]; then exit 74; fi
/bin/mv "$@"
if [ "$RAZERLITE_TEST_FAULT" = term-backup ] && [ "$1" = "$RAZERLITE_TEST_DEST" ]; then
    # PPID is the actual installer shell, unlike $$ inside a Bash subshell.
    kill -TERM "$PPID"
fi
if [ "$promoting" = true ] && [ "$RAZERLITE_TEST_FAULT" = term-promote ]; then
    kill -TERM "$PPID"
fi
if [ "$promoting" = true ] && [ "$RAZERLITE_TEST_FAULT" = term-other-destination ]; then
    /bin/mv "$2" "$2.displaced"
    printf 'third-party content' > "$2"
    kill -TERM "$PPID"
fi
if [ "$promoting" = true ] && [ "$RAZERLITE_TEST_FAULT" = signature ]; then
    printf 'tampered' >> "$2/Contents/Resources/version.txt"
fi
''')
            wrapper.chmod(0o755)
            env["PATH"] = str(commands) + os.pathsep + env["PATH"]
            env["RAZERLITE_TEST_FAULT"] = fault
            env["RAZERLITE_TEST_DEST"] = str(self.destination)
        return subprocess.run([
            "/bin/bash", "-c", 'source "$1"; install_razerlite_release "$2" "$3" "$4" "$5"',
            "test-install", str(INSTALLER), str(self.source), str(self.destination),
            str(self.backups), "--replace" if replace else "",
        ], env=env, capture_output=True, text=True)

    def marker(self, path):
        return (path / "Contents/Resources/version.txt").read_text()

    def assert_no_staging(self):
        self.assertEqual(list(self.destination.parent.glob(".RazerLite-install.*")), [])

    def test_first_install_and_update_keep_previous_app(self):
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.marker(self.destination), "new")
        self.assertFalse(self.backups.exists())
        # A separately signed old app makes preserving content observable.
        shutil.rmtree(self.destination)
        self.bundle(self.destination, "old")
        updated = self.run_install(replace=True)
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertEqual(self.marker(self.destination), "new")
        saved = list(self.backups.glob("previous.*/RazerLite.app"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(self.marker(saved[0]), "old")
        self.assert_no_staging()

    def test_existing_installation_requires_explicit_replace(self):
        self.bundle(self.destination, "old")
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertFalse(self.backups.exists())

    def test_existing_transaction_lock_blocks_overlapping_installation(self):
        self.bundle(self.destination, "old")
        lock = self.destination.parent / ".RazerLite-install.lock"
        lock.mkdir()
        result = self.run_install(replace=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertTrue(lock.exists())
        self.assertFalse(self.backups.exists())

    def test_source_identifier_and_configuration_are_checked(self):
        for identifier, configuration in [("local.Other", "release"), ("local.RazerLite", "debug")]:
            with self.subTest(identifier=identifier, configuration=configuration):
                shutil.rmtree(self.source)
                self.bundle(self.source, "new", identifier, configuration)
                result = self.run_install()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.destination.exists())

    def test_unrelated_destination_and_symlink_are_preserved(self):
        self.bundle(self.destination, "unrelated", identifier="local.Other")
        self.assertNotEqual(self.run_install(replace=True).returncode, 0)
        self.assertEqual(self.marker(self.destination), "unrelated")
        shutil.rmtree(self.destination)
        self.destination.symlink_to(self.source, target_is_directory=True)
        self.assertNotEqual(self.run_install(replace=True).returncode, 0)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(self.marker(self.source), "new")

    def test_failed_promotion_restores_previous_installation(self):
        self.bundle(self.destination, "old")
        result = self.run_install(replace=True, fault="move")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertIn("previous installation restored", result.stderr)
        self.assert_no_staging()

    def test_final_signature_failure_restores_previous_installation(self):
        self.bundle(self.destination, "old")
        result = self.run_install(replace=True, fault="signature")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertIn("previous installation restored", result.stderr)
        self.assert_no_staging()

    def test_first_install_signature_failure_leaves_no_app(self):
        result = self.run_install(fault="signature")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())
        self.assertIn("unverified new app was removed", result.stderr)
        self.assert_no_staging()

    def test_failed_restore_retains_and_reports_backup(self):
        self.bundle(self.destination, "old")
        result = self.run_install(replace=True, fault="restore")
        self.assertNotEqual(result.returncode, 0)
        saved = list(self.backups.glob("previous.*/RazerLite.app"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(self.marker(saved[0]), "old")
        self.assertIn(str(saved[0]), result.stderr)
        self.assert_no_staging()

    def test_sigterm_after_old_app_move_restores_previous_installation(self):
        self.bundle(self.destination, "old")
        result = self.run_install(replace=True, fault="term-backup")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertIn("previous installation restored", result.stderr)
        self.assert_no_staging()

    def test_sigterm_after_new_app_move_removes_it_and_restores_previous_app(self):
        first = self.run_install(fault="term-promote")
        self.assertEqual(first.returncode, 143, first.stderr)
        self.assertFalse(self.destination.exists())
        self.assertIn("unverified new app was removed", first.stderr)
        self.assert_no_staging()
        self.bundle(self.destination, "old")
        update = self.run_install(replace=True, fault="term-promote")
        self.assertEqual(update.returncode, 143, update.stderr)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertIn("previous installation restored", update.stderr)
        self.assert_no_staging()

    def test_sigterm_does_not_delete_third_party_replacement(self):
        self.bundle(self.destination, "old")
        result = self.run_install(replace=True, fault="term-other-destination")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(self.destination.read_text(), "third-party content")
        saved = list(self.backups.glob("previous.*/RazerLite.app"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(self.marker(saved[0]), "old")
        self.assertIn(str(saved[0]), result.stderr)
        self.assert_no_staging()

    def test_extra_cli_arguments_are_rejected_before_installation(self):
        result = subprocess.run(["/bin/bash", str(INSTALLER), "--replace", "unexpected"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
