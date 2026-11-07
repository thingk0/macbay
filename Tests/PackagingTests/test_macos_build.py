import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "verify-macos-build.py"
SPEC = importlib.util.spec_from_file_location("verify_macos_build", SCRIPT)
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


def metadata(minimum="13.0", sdk="27.2"):
    return f"cmd LC_BUILD_VERSION\nplatform MACOS\n    minos {minimum}\n      sdk {sdk}\n   ntools 1\n"


class MacOSBuildTests(unittest.TestCase):
    def test_latest_sdk_keeps_the_existing_deployment_requirement(self):
        self.assertEqual(BUILD.verify_metadata(metadata(), "13.0", "27.2"), 1)

    def test_deployment_version_mistaken_for_sdk_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Linked SDK mismatch"):
            BUILD.verify_metadata(metadata(sdk="13.0"), "13.0", "27.2")

    def test_raised_minimum_os_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Minimum macOS changed"):
            BUILD.verify_metadata(metadata(minimum="27.2"), "13.0", "27.2")

    def test_equivalent_version_spellings_are_accepted(self):
        self.assertEqual(BUILD.verify_metadata(metadata("13", "27.2.0"), "13.0", "27.2"), 1)

    def test_each_architecture_must_match(self):
        with self.assertRaisesRegex(ValueError, "Linked SDK mismatch"):
            BUILD.verify_metadata(metadata() + metadata(sdk="13.0"), "13.0", "27.2")

    def test_missing_macos_metadata_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "No macOS"):
            BUILD.verify_metadata("platform IOS\nminos 13.0\nsdk 27.2", "13.0", "27.2")
