"""Generate cross-language crypto test vectors (Python is the reference; Swift must decrypt them)."""
import json, sys
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from atomhealth import relay

KEY = bytes(range(32))
CASES = [
    ("dev-mac-1", "rec-AAAAAAAA", bytes(range(12)), {"v": 1, "type": "weight", "op": "upsert", "id": "w1", "version": 3, "updated_at": 1700000000, "data": {"ts": 1700000000, "weight_kg": 78.4, "fat_pct": 21.0}}),
    ("phone-1", "rec_BBBB-0001", bytes(range(100, 112)), {"v": 1, "type": "meal", "op": "delete", "id": "m9", "version": 7, "updated_at": 1700000100, "data": {"note": "café ☕ über"}}),
]
out = {"key_b64": relay.b64e(KEY), "aad_prefix": relay.AAD_PREFIX.decode(), "cases": []}
for dev, rid, nonce, env in CASES:
    pt = json.dumps(env, separators=(",", ":")).encode()
    ct = ChaCha20Poly1305(KEY).encrypt(nonce, pt, relay._aad(dev, rid))
    assert relay.decrypt(KEY, dev, rid, relay.b64e(nonce), relay.b64e(ct)) == env
    out["cases"].append({"device_id": dev, "record_id": rid, "nonce": relay.b64e(nonce), "ciphertext": relay.b64e(ct), "plaintext": pt.decode()})
Path(sys.argv[1]).write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
print("wrote", sys.argv[1])
