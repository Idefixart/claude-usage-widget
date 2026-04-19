#!/usr/bin/env python3
"""Fetches Claude plan usage from claude.ai using Claude Desktop's session cookies."""

import sqlite3, hashlib, os, json, sys, subprocess


def _ensure_deps():
    """First-run auto-install of pip deps so the app is airdrop-friendly."""
    missing = []
    try:
        import cryptography  # noqa: F401
    except ImportError:
        missing.append("cryptography")
    try:
        import curl_cffi  # noqa: F401
    except ImportError:
        missing.append("curl_cffi")
    if not missing:
        return
    try:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--user", "--quiet", *missing],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        # Make user site-packages importable in this process
        import site
        user_site = site.getusersitepackages()
        if user_site and user_site not in sys.path:
            sys.path.insert(0, user_site)
    except Exception as e:
        print(json.dumps({"error": f"Python-Dependencies fehlen ({', '.join(missing)}). Install: pip3 install --user {' '.join(missing)}. Details: {e}"}))
        sys.exit(1)


_ensure_deps()

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding as sym_padding
from curl_cffi import requests as cffi_requests


def get_safe_storage_key():
    """Get the Electron Safe Storage key from macOS Keychain."""
    import subprocess
    result = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Safe Storage", "-w"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip().encode()
    # Fallback names
    for name in ["Electron Safe Storage", "Chrome Safe Storage"]:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", name, "-w"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            return result.stdout.strip().encode()
    return None


def decrypt_cookies():
    """Decrypt Claude Desktop's Chromium cookies."""
    safe_key = get_safe_storage_key()
    if not safe_key:
        return None, "Keychain-Key nicht gefunden"

    aes_key = hashlib.pbkdf2_hmac('sha1', safe_key, b'saltysalt', 1003, dklen=16)
    cookie_path = os.path.expanduser("~/Library/Application Support/Claude/Cookies")

    if not os.path.exists(cookie_path):
        return None, "Claude Desktop Cookies nicht gefunden"

    conn = sqlite3.connect(cookie_path)
    cursor = conn.cursor()

    def decrypt_one(encrypted):
        iv = b' ' * 16
        cipher = Cipher(algorithms.AES(aes_key), modes.CBC(iv))
        dec = cipher.decryptor()
        padded = dec.update(encrypted[3:]) + dec.finalize()
        unp = sym_padding.PKCS7(128).unpadder()
        raw = unp.update(padded) + unp.finalize()
        return (raw[32:] if len(raw) > 32 else raw).decode('ascii', errors='ignore').strip()

    cursor.execute(
        "SELECT name, encrypted_value FROM cookies WHERE host_key LIKE '%claude.ai%'"
    )
    cookies = {}
    for name, enc in cursor.fetchall():
        try:
            v = decrypt_one(enc)
            if v:
                cookies[name] = v
        except Exception:
            pass
    conn.close()
    return cookies, None


def fetch_usage(cookies):
    """Fetch usage data from claude.ai API."""
    org_id = cookies.get('lastActiveOrg', '')
    if not org_id:
        return None, "Keine Organisation gefunden"

    try:
        headers = {"Accept": "application/json"}
        # Main usage
        r = cffi_requests.get(
            f"https://claude.ai/api/organizations/{org_id}/usage",
            cookies=cookies, impersonate="chrome", headers=headers, timeout=15
        )
        if r.status_code == 401 or r.status_code == 403:
            return None, "Session abgelaufen - bitte Claude Desktop neu starten"
        if r.status_code != 200:
            return None, f"HTTP {r.status_code}"
        data = r.json()

        # Prepaid balance (Current Balance)
        try:
            rp = cffi_requests.get(
                f"https://claude.ai/api/organizations/{org_id}/prepaid/credits",
                cookies=cookies, impersonate="chrome", headers=headers, timeout=10
            )
            if rp.status_code == 200:
                data["prepaid"] = rp.json()
        except Exception:
            pass

        return data, None
    except Exception as e:
        return None, str(e)


def main():
    cookies, err = decrypt_cookies()
    if err:
        print(json.dumps({"error": err}))
        sys.exit(1)

    data, err = fetch_usage(cookies)
    if err:
        print(json.dumps({"error": err}))
        sys.exit(1)

    print(json.dumps(data))


if __name__ == "__main__":
    main()
