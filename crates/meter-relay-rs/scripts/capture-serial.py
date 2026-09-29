#!/usr/bin/env python3
"""Capture Modbus RTU traffic on one meter line and print its fingerprint.

Startup discovery tells one inverter's meter line from another's by the
registers the inverter asks for, so each driver needs its request patterns
written down (`driver_meter_poll()` in `src/config.rs`). This is how those
patterns are measured, and how a new make/model is added:

    # on grafton-router, with the relay stopped (it owns these ports):
    sudo systemctl stop meter-relay
    nix shell nixpkgs#python3 --command \\
        python3 crates/meter-relay-rs/scripts/capture-serial.py --port 2001 --seconds 60
    sudo systemctl start meter-relay

Then paste the printed `MR_<ID>_METER_POLL=` line into the host's Nix, and
optionally into `driver_meter_poll()` so the whole deployment knows it.

**It kicks the relay off the port.** ser2net on the inverter-pi has
`kickolduser: true`, so connecting here displaces whoever holds the port — the
running service included. Stop the service first, or accept a reconnect.

The grid meter's own line can be captured the same way with ``--device``.
"""

import argparse
import collections
import socket
import sys
import time

READ_FUNCTION_CODES = (3, 4)
WRITE_FUNCTION_CODES = (6,)
REQUEST_LENGTH = 8


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def parse_requests(buffer: bytes):
    """Yields (frame, consumed) for every request frame at the buffer's start.

    Scans for a frame whose CRC checks out and whose length matches its
    function code; anything else is skipped a byte at a time, exactly as the
    service's own parser recovers from line noise.
    """
    start = 0
    while start < len(buffer):
        function_code = buffer[start + 1] if start + 1 < len(buffer) else None
        if function_code in READ_FUNCTION_CODES or function_code in WRITE_FUNCTION_CODES:
            end = start + REQUEST_LENGTH
            if end <= len(buffer):
                frame = buffer[start:end]
                if crc16(frame[:-2]) == int.from_bytes(frame[-2:], "little"):
                    yield frame, start
                    start = end
                    continue
        start += 1


def open_stream(args):
    if args.device:
        return open(args.device, "rb", buffering=0), f"serial:{args.device}"
    connection = socket.create_connection((args.host, args.port), timeout=5)
    connection.settimeout(0.5)
    return connection, f"tcp://{args.host}:{args.port}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, help="TCP port on the inverter-pi")
    parser.add_argument("--device", help="local serial device instead of a port")
    parser.add_argument("--host", default="192.168.49.30")
    parser.add_argument("--seconds", type=float, default=30.0)
    args = parser.parse_args()

    if bool(args.port) == bool(args.device):
        parser.error("give exactly one of --port or --device")

    stream, label = open_stream(args)
    print(f"capturing {label} for {args.seconds:g} s", file=sys.stderr)

    patterns = collections.Counter()
    slaves = collections.Counter()
    gaps = collections.defaultdict(list)
    last_seen = {}
    frames = 0
    junk = 0
    buffer = b""
    deadline = time.time() + args.seconds

    try:
        while time.time() < deadline:
            try:
                chunk = stream.recv(4096) if hasattr(stream, "recv") else stream.read(4096)
            except (socket.timeout, TimeoutError):
                continue
            if not chunk:
                break
            buffer += chunk
            consumed = 0
            for frame, offset in parse_requests(buffer):
                junk += offset - consumed
                consumed = offset + len(frame)
                key = (frame[1], int.from_bytes(frame[2:4], "big"), int.from_bytes(frame[4:6], "big"))
                patterns[key] += 1
                slaves[frame[0]] += 1
                now = time.time()
                if key in last_seen:
                    gaps[key].append(now - last_seen[key])
                last_seen[key] = now
                frames += 1
            buffer = buffer[consumed:]
    except KeyboardInterrupt:
        pass
    finally:
        stream.close()

    if frames == 0:
        print(f"no request frames seen in {args.seconds:g} s on {label}", file=sys.stderr)
        return 1

    print(f"\n{label}: {frames} request frame(s), {junk} junk byte(s)\n")
    print(f"{'requests':>8}  {'mean gap':>9}  pattern")
    for (function_code, register, count), seen in patterns.most_common():
        mean_gap = gaps.get((function_code, register, count))
        mean = f"{1000 * sum(mean_gap) / len(mean_gap):.0f} ms" if mean_gap else "—"
        print(f"{seen:>8}  {mean:>9}  fc{function_code} reg {register} n{count}")
    print(f"\nslave addresses: {dict(sorted(slaves.items()))}")

    spec = ",".join(
        f"{function_code}:{register}:{count}"
        for function_code, register, count in sorted(patterns)
    )
    print(f'\nfingerprint: MR_<ID>_METER_POLL="{spec}"')
    return 0


if __name__ == "__main__":
    sys.exit(main())
