import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("export_ddi", Path(__file__).parents[1] / "scripts/export_ddi.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExportDDITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.restore = self.root / "Restore"
        self.restore.mkdir()
        entries = {}
        for key, name, data in [("PersonalizedDMG", "022-test.dmg", b"image"),
                                ("LoadableTrustCache", "test.trustcache", b"trust")]:
            (self.restore / name).write_bytes(data)
            entries[key] = {"Digest": hashlib.sha384(data).digest(), "Info": {"Path": name}}
        self.manifest = {"ProductBuildVersion": "27A266a", "BuildIdentities": [{"Manifest": entries}]}
        self.save_manifest()
        self.output = self.root / "Export"

    def save_manifest(self):
        (self.restore / "BuildManifest.plist").write_bytes(plistlib.dumps(self.manifest))

    def test_export_normalizes_paths_and_preserves_digests(self):
        module.export(self.restore, self.output)
        exported = plistlib.loads((self.output / "BuildManifest.plist").read_bytes())
        for key, name in [("PersonalizedDMG", "Image.dmg"), ("LoadableTrustCache", "Image.dmg.trustcache")]:
            entry = exported["BuildIdentities"][0]["Manifest"][key]
            self.assertEqual(entry["Info"]["Path"], name)
            self.assertEqual(entry["Digest"], hashlib.sha384((self.output / name).read_bytes()).digest())

    def test_corruption_leaves_no_output(self):
        (self.restore / "test.trustcache").write_bytes(b"wrong")
        with self.assertRaises(ValueError):
            module.export(self.restore, self.output)
        self.assertFalse(self.output.exists())

    def test_old_xcode_is_rejected(self):
        self.manifest["ProductBuildVersion"] = "17E192"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "too old"):
            module.export(self.restore, self.output)

    def test_manifest_cannot_escape_restore_folder(self):
        self.manifest["BuildIdentities"][0]["Manifest"]["PersonalizedDMG"]["Info"]["Path"] = "../outside"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "escapes"):
            module.export(self.restore, self.output)

    def test_cannot_overwrite_existing_export(self):
        self.output.mkdir()
        sentinel = self.output / "keep"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            module.export(self.restore, self.output)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_recent_build_without_target_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no identity for chip 0x8160, board 0xa"):
            module.export(self.restore, self.output, required_identity=(0x8160, 0xA))
        self.assertFalse(self.output.exists())

    def test_target_identity_payloads_are_verified(self):
        identity = self.manifest["BuildIdentities"][0]
        identity.update(ApChipID="0x8160", ApBoardID="0x0A")
        self.save_manifest()
        module.export(self.restore, self.output, required_identity=(0x8160, 0xA))
        self.assertTrue(self.output.exists())

    def test_other_identity_cannot_hide_corrupt_target_payload(self):
        import copy
        target = copy.deepcopy(self.manifest["BuildIdentities"][0])
        target.update(ApChipID=0x8160, ApBoardID=0xA)
        target["Manifest"]["PersonalizedDMG"]["Digest"] = b"wrong"
        self.manifest["BuildIdentities"].append(target)
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "No personalized build identity"):
            module.export(self.restore, self.output, required_identity=(0x8160, 0xA))
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
