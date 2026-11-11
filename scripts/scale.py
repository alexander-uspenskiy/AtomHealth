"""BLE helper for the Raganet HG007-1 bluetooth scale.

Usage (step on the scale first so it wakes up and advertises):
  .venv/bin/python scripts/scale.py scan [seconds]
  .venv/bin/python scripts/scale.py listen [name-or-address]

`listen` connects, dumps services, subscribes to every notify/indicate
characteristic and appends raw packets to measurements.jsonl so the protocol
can be decoded once real data is captured.
"""
import asyncio
import json
import sys
import time
from pathlib import Path

from bleak import BleakClient, BleakScanner

DATA_DIR = Path(__file__).resolve().parents[1] / "data"
DATA_DIR.mkdir(exist_ok=True)
LOG = str(DATA_DIR / "measurements.jsonl")
HINTS = ("raga", "hg007", "scale", "qn-", "yoda", "fit", "health", "body", "bf")


def looks_like_scale(name):
    return bool(name) and any(h in name.lower() for h in HINTS)


async def scan(seconds=10.0):
    print(f"Scanning {seconds:.0f}s... step on the scale to wake it.")
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    rows = sorted(found.values(), key=lambda x: -x[1].rssi)
    for dev, adv in rows:
        mark = "  <== candidate" if looks_like_scale(adv.local_name or dev.name) else ""
        print(f"{adv.rssi:4d} dBm  {dev.address}  {adv.local_name or dev.name or '(no name)'}{mark}")
        if adv.manufacturer_data:
            for cid, data in adv.manufacturer_data.items():
                print(f"          mfr 0x{cid:04x}: {data.hex()}")
        if adv.service_uuids:
            print(f"          services: {', '.join(adv.service_uuids)}")


async def find(target, timeout=30.0):
    if target:
        t = target.lower()
        return await BleakScanner.find_device_by_filter(
            lambda d, a: t in (d.address or "").lower()
            or t in (a.local_name or d.name or "").lower(),
            timeout=timeout,
        )
    return await BleakScanner.find_device_by_filter(
        lambda d, a: looks_like_scale(a.local_name or d.name), timeout=timeout
    )


def log(kind, **fields):
    rec = {"ts": time.time(), "kind": kind, **fields}
    with open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")
    return rec


async def listen(target=None):
    print("Looking for scale (step on it to wake it)...")
    dev = await find(target)
    if not dev:
        sys.exit("Scale not found. Try `scan` and pass its name/address.")
    print(f"Found {dev.name} {dev.address}; connecting...")

    async with BleakClient(dev) as client:
        print("Connected. Services:")
        notifiable = []
        for svc in client.services:
            print(f"  [{svc.uuid}]")
            for ch in svc.characteristics:
                print(f"    {ch.uuid}  {','.join(ch.properties)}")
                if "notify" in ch.properties or "indicate" in ch.properties:
                    notifiable.append(ch)

        def make_handler(uuid):
            def handler(_, data: bytearray):
                rec = log("notify", char=uuid, hex=data.hex())
                print(f"{time.strftime('%H:%M:%S')} {uuid[:8]} {data.hex()}")
            return handler

        for ch in notifiable:
            try:
                await client.start_notify(ch, make_handler(ch.uuid))
            except Exception as e:
                print(f"  could not subscribe {ch.uuid}: {e}")

        print(f"Listening (Ctrl+C to stop). Raw packets -> {LOG}")
        while client.is_connected:
            await asyncio.sleep(1)
        print("Scale disconnected.")


async def diff():
    print("Step OFF the scale. Baseline scan for 10s...", flush=True)
    base = await BleakScanner.discover(timeout=10, return_adv=True)
    print(">>> STEP ON THE SCALE NOW and stay until it finishes (15s) <<<", flush=True)
    seen = {}
    def cb(dev, adv):
        seen[dev.address] = (dev, adv)
    async with BleakScanner(cb):
        await asyncio.sleep(15)
    new = [v for k, v in seen.items() if k not in base]
    print(f"\n{len(new)} devices appeared only while you were on the scale:")
    for dev, adv in sorted(new, key=lambda x: -x[1].rssi):
        print(f"{adv.rssi:4d} dBm  {dev.address}  {adv.local_name or dev.name or '(no name)'}")
        for cid, data in adv.manufacturer_data.items():
            print(f"          mfr 0x{cid:04x}: {data.hex()}")
        if adv.service_uuids:
            print(f"          services: {', '.join(adv.service_uuids)}")


async def watch(seconds=60):
    """Print every new (device, adv payload) combo, skipping Apple noise."""
    seen = set()
    t0 = time.time()
    def cb(dev, adv):
        mfr = {c: d.hex() for c, d in adv.manufacturer_data.items() if c != 0x004C}
        if adv.manufacturer_data and not mfr:
            return  # Apple-only
        key = (dev.address, json.dumps(mfr, sort_keys=True), json.dumps(
            {k: v.hex() for k, v in adv.service_data.items()}, sort_keys=True))
        if key in seen:
            return
        seen.add(key)
        print(f"{time.time()-t0:5.1f}s {adv.rssi:4d} dBm {dev.address} "
              f"{adv.local_name or dev.name or '-'} mfr={mfr} "
              f"svc={list(adv.service_uuids)} sdata={ {k: v.hex() for k, v in adv.service_data.items()} }",
              flush=True)
    print(f"Watching {seconds}s. Step on/off the scale a few times.", flush=True)
    async with BleakScanner(cb):
        await asyncio.sleep(seconds)


CSV = str(DATA_DIR / "weights.csv")
# The scale broadcasts weight in its advertisement (no connection needed):
# manufacturer data = <company id lo=0xC0, hi=counter/flags> + payload where
# payload[0:2] = weight in 0.01 kg (big-endian), payload[2:4] = impedance-ish.
SIG = bytes.fromhex("65f4dd2144")  # trailing bytes seen on this scale


def decode(adv):
    for cid, data in adv.manufacturer_data.items():
        if cid & 0xFF == 0xC0 and len(data) == 13 and data.endswith(SIG):
            return cid, data
    return None


async def weigh(settle=8):
    """Live weight from advertisements; saves a reading once it holds steady."""
    import csv, os
    state = {"w": None, "since": 0.0, "saved": None}
    print("Step on the scale. Ctrl+C to quit.", flush=True)

    def cb(dev, adv):
        hit = decode(adv)
        if not hit:
            return
        cid, data = hit
        w = int.from_bytes(data[0:2], "big") / 100
        imp = int.from_bytes(data[2:4], "big")
        now = time.time()
        if w != state["w"]:
            state["w"], state["since"] = w, now
            print(f"{time.strftime('%H:%M:%S')}  {w:6.2f} kg  (imp {imp}, flags 0x{cid >> 8:02x})", flush=True)
        elif w > 5 and now - state["since"] >= 2 and imp and state["saved"] != (w, imp):
            state["saved"] = (w, imp)
            new = not os.path.exists(CSV)
            with open(CSV, "a", newline="") as f:
                wr = csv.writer(f)
                if new:
                    wr.writerow(["timestamp", "weight_kg", "impedance_raw", "payload_hex"])
                wr.writerow([time.strftime("%Y-%m-%d %H:%M:%S"), w, imp, data.hex()])
            print(f"   saved -> {CSV}: {w:.2f} kg", flush=True)

    async with BleakScanner(cb):
        while True:
            await asyncio.sleep(1)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "scan"
    try:
        if cmd == "scan":
            asyncio.run(scan(float(sys.argv[2]) if len(sys.argv) > 2 else 10.0))
        elif cmd == "weigh":
            asyncio.run(weigh())
        elif cmd == "watch":
            asyncio.run(watch(float(sys.argv[2]) if len(sys.argv) > 2 else 60))
        elif cmd == "diff":
            asyncio.run(diff())
        elif cmd == "listen":
            asyncio.run(listen(sys.argv[2] if len(sys.argv) > 2 else None))
        else:
            sys.exit(__doc__)
    except KeyboardInterrupt:
        pass
