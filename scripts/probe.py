import asyncio, sys
from bleak import BleakClient, BleakScanner

async def probe(addr):
    print(f"== {addr}", flush=True)
    dev = await BleakScanner.find_device_by_address(addr, timeout=10)
    if not dev:
        print("  not seen"); return
    try:
        async with BleakClient(dev, timeout=15) as c:
            for s in c.services:
                print(f"  [{s.uuid}]")
                for ch in s.characteristics:
                    print(f"    {ch.uuid} {','.join(ch.properties)}")
    except Exception as e:
        print("  error:", e)

async def main():
    for a in sys.argv[1:]:
        await probe(a)
asyncio.run(main())
