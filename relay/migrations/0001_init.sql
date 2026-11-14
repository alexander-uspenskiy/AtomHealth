-- Devices paired with the relay. Only a hash of the device secret is stored.
CREATE TABLE devices(
  device_id  TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  cursor     INTEGER NOT NULL DEFAULT 0,   -- highest seq the device has acknowledged
  created_at INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL,
  revoked    INTEGER NOT NULL DEFAULT 0
);

-- Append-only log of end-to-end encrypted records. The relay never sees plaintext.
CREATE TABLE changes(
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id  TEXT NOT NULL,
  record_id  TEXT NOT NULL,
  nonce      TEXT NOT NULL,       -- base64
  ciphertext TEXT NOT NULL,       -- base64
  created_at INTEGER NOT NULL,
  UNIQUE(device_id, record_id)    -- makes push idempotent
);
CREATE INDEX changes_created ON changes(created_at);
