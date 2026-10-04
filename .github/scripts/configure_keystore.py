#!/usr/bin/env python3
"""
Secure Keystore Configuration Script for GitHub Actions CI/CD.
Safely decodes ANDROID_KEYSTORE_BASE64 to android/app/release.jks
and generates android/key.properties with proper Java .properties escaping.
"""

import base64
import os
import sys

def clean_property(value: str) -> str:
    """Strips newlines to ensure single-line property format while preserving all special characters."""
    if not value:
        return ""
    return value.rstrip("\r\n")

def main():
    keystore_base64 = os.environ.get("KEYSTORE_BASE64", "").strip().strip("'\"")
    if not keystore_base64:
        print("Warning: ANDROID_KEYSTORE_BASE64 is empty, fallback to debug signature.")
        return

    # 1. Decode JKS binary
    try:
        jks_bytes = base64.b64decode(keystore_base64)
        os.makedirs("android/app", exist_ok=True)
        with open("android/app/release.jks", "wb") as f:
            f.write(jks_bytes)
        print("Keystore successfully decoded: android/app/release.jks")
    except Exception as err:
        print(f"Error decoding ANDROID_KEYSTORE_BASE64: {err}", file=sys.stderr)
        sys.exit(1)

    # 2. Write android/key.properties with exact literal values
    store_password = clean_property(os.environ.get("KEYSTORE_PASSWORD", ""))
    key_password = clean_property(os.environ.get("KEY_PASSWORD", ""))
    key_alias = clean_property(os.environ.get("KEY_ALIAS", ""))

    with open("android/key.properties", "w", encoding="utf-8") as f:
        f.write(f"storePassword={store_password}\n")
        f.write(f"keyPassword={key_password}\n")
        f.write(f"keyAlias={key_alias}\n")
        f.write("storeFile=release.jks\n")

    print("android/key.properties successfully generated.")

if __name__ == "__main__":
    main()
