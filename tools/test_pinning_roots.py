"""يتحقق أن كل جذر PEM في secure_http.dart يطابق بصمة SHA-256 المكتوبة فوقه، وأن الإعدادات الأمنية موجودة."""
from __future__ import annotations

import hashlib
import re
import ssl
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "secure_http.dart"


def main() -> int:
    text = SRC.read_text(encoding="utf-8")
    pattern = re.compile(
        r"// SHA-256: ([0-9A-F:]{95})\n\s*'''(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)\n'''",
        re.S,
    )
    entries = pattern.findall(text)
    if len(entries) < 6:
        print(f"FAIL: expected at least 6 roots, found {len(entries)}")
        return 1
    for fp, pem in entries:
        der = ssl.PEM_cert_to_DER_cert(pem)
        actual = hashlib.sha256(der).hexdigest().upper()
        actual = ":".join(actual[i : i + 2] for i in range(0, 64, 2))
        if actual != fp:
            print(f"FAIL: fingerprint mismatch\n  comment: {fp}\n  actual:  {actual}")
            return 1
    for needle in (
        "withTrustedRoots: false",
        "badCertificateCallback",
        "=> false",
        "bayan-storage-api.aaro3498.workers.dev",
    ):
        if needle not in text:
            print(f"FAIL: missing '{needle}' in secure_http.dart")
            return 1
    if "HttpOverrides.global" in text.replace("لا HttpOverrides.global", ""):
        print("FAIL: HttpOverrides.global must not be used")
        return 1
    print(f"OK: {len(entries)} pinned roots match their SHA-256 fingerprints")
    return 0


if __name__ == "__main__":
    sys.exit(main())
