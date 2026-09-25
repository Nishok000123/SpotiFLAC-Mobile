"""Reject APKs that silently lose the optional native Discord integration."""

import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

import check_backend_apk as checker


class DiscordApkAuditTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.apk = Path(directory.name) / "release.apk"
        self.entries = {
            "assets/discord-sdk-notices.txt": b"SDK license notices",
            "classes.dex": b"\0".join(checker.DISCORD_CLASSES),
        }
        for abi, (elf_class, machine) in checker.ABI_LAYOUT.items():
            header = bytearray(20)
            header[:6] = b"\x7fELF" + bytes([elf_class, 1])
            struct.pack_into("<H", header, 18, machine)
            for library in checker.CORE_LIBRARIES + checker.DISCORD_LIBRARIES + (
                "libspotiflac_mobile.so", "libjnidispatch.so",
            ):
                self.entries[f"lib/{abi}/{library}"] = bytes(header)

    def audit(self, abis=("arm64-v8a", "armeabi-v7a"), require_discord=True):
        with zipfile.ZipFile(self.apk, "w") as zf:
            for name, data in self.entries.items():
                zf.writestr(name, data)
        return checker.audit(self.apk, "rust", abis, require_discord)

    def test_universal_with_discord_passes(self):
        self.assertEqual(len(self.audit()), 64)

    def test_split_apks_require_discord_for_their_abi(self):
        original = self.entries.copy()
        for abi in checker.ABI_LAYOUT:
            self.entries = {name: data for name, data in original.items()
                            if not name.startswith("lib/") or name.startswith(f"lib/{abi}/")}
            self.assertEqual(len(self.audit((abi,))), 64)

    def test_either_discord_library_missing_in_either_abi_fails(self):
        for abi in checker.ABI_LAYOUT:
            for library in checker.DISCORD_LIBRARIES:
                with self.subTest(abi=abi, library=library):
                    path = f"lib/{abi}/{library}"
                    data = self.entries.pop(path)
                    with self.assertRaisesRegex(checker.AuditError, "missing APK entry"):
                        self.audit()
                    self.entries[path] = data

    def test_wrong_architecture_fails(self):
        self.entries["lib/armeabi-v7a/libdiscord_partner_sdk.so"] = self.entries[
            "lib/arm64-v8a/libdiscord_partner_sdk.so"
        ]
        with self.assertRaisesRegex(checker.AuditError, "ELF class"):
            self.audit()

    def test_missing_or_empty_notices_fail(self):
        self.entries.pop("assets/discord-sdk-notices.txt")
        with self.assertRaisesRegex(checker.AuditError, "missing APK entry"):
            self.audit()
        self.entries["assets/discord-sdk-notices.txt"] = b" "
        with self.assertRaisesRegex(checker.AuditError, "notices are empty"):
            self.audit()

    def test_removed_or_renamed_jni_classes_fail(self):
        for marker in checker.DISCORD_CLASSES:
            self.entries["classes.dex"] = marker
            with self.assertRaisesRegex(checker.AuditError, "classes missing"):
                self.audit()

    def test_multidex_classes_pass(self):
        self.entries["classes.dex"] = checker.DISCORD_CLASSES[0]
        self.entries["classes2.dex"] = checker.DISCORD_CLASSES[1]
        self.assertEqual(len(self.audit()), 64)

    def test_explicit_backend_only_audit_still_works(self):
        self.entries = {name: data for name, data in self.entries.items()
                        if "discord" not in name}
        self.entries["classes.dex"] = b"backend only"
        self.assertEqual(len(self.audit(require_discord=False)), 64)


if __name__ == "__main__":
    unittest.main()
