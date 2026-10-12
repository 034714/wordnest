import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from package import apksigner_command, artifact_names, STABLE_NAMES
from release_helpers import ANDROID_APK, ReleaseVersion, parse_apk_version


class SignerCommandTest(unittest.TestCase):
    def test_release_uses_only_three_canonical_names_and_arm64_input(self):
        self.assertEqual(artifact_names(ReleaseVersion('0.3.1', 4), False), list(STABLE_NAMES))
        self.assertEqual(ANDROID_APK.name, 'app-arm64-v8a-release.apk')

    def test_arm64_split_version_offset_and_abi_are_required(self):
        version = ReleaseVersion('0.3.1', 4)
        badging = "package: name='io.wordnest.wordnest' versionCode='2004' versionName='0.3.1'\nnative-code: 'arm64-v8a'\n"
        self.assertEqual(parse_apk_version(badging, version)['version_code'], 2004)
        for invalid in [badging.replace('2004', '4'), badging.replace('arm64-v8a', 'x86_64')]:
            with self.assertRaises(ValueError):
                parse_apk_version(invalid, version)

    def test_metacharacters_remain_literal_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / "sdk & (literal)"
            (sdk / 'lib').mkdir(parents=True)
            signer = sdk / 'apksigner.bat'
            signer.touch()
            (sdk / 'lib/apksigner.jar').touch()
            home = root / 'java'
            (home / 'bin').mkdir(parents=True)
            (home / 'bin/java.exe').touch()
            apk = root / "test & 'quoted'.apk"
            apk.touch()
            with patch.dict(os.environ, {'JAVA_HOME': str(home)}):
                command = apksigner_command(signer, apk)
            self.assertEqual(command[1:3], ['-jar', str((sdk / 'lib/apksigner.jar').resolve())])
            self.assertEqual(command[-1], str(apk.resolve()))
            self.assertNotIn('-Command', command)
            self.assertNotIn('powershell.exe', command)

    def test_arbitrary_script_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'untrusted.cmd'
            script.touch()
            with self.assertRaises(ValueError):
                apksigner_command(script, script)


if __name__ == '__main__':
    unittest.main()
