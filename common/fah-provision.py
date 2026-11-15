#!/usr/bin/env python3
"""Enable every supported GPU and start folding on a local fah-client.

A fresh Folding@home v8 client starts paused with an empty GPU list in its
default resource group (src/resources/group.json); the supported way to
change that is the websocket API served on the client's http-addresses, the
same one app.foldingathome.org and `fahctl` use.

Usage: fah-provision [--no-gpus] [HOST:PORT]   (default 127.0.0.1:7396)
  --no-gpus: start folding but explicitly CLEAR the group's GPU list — the
  inverse of the default, for a host whose GPU must not take fold load
  (hp-z240 SFF PSU brown-outs; see hosts/hp-z240-xeon-1240v6-nixos).

Exits 0 once the client is configured, 1 when it never answered. The long
horizon is NOT this script's job: the fah-client-configure oneshot in
common/folding-at-home-native.nix keeps the retry loop, because only it can
tell "the client has not opened its port yet" from "the client is stopped on
purpose" (the peak-hours pause window) — see open_socket().
"""

import json
import sys
import time

import websocket


def open_socket(addr, wait_secs=15):
    """Connect to the client's websocket API, waiting quietly for it to listen.

    Connection-refused is the EXPECTED first answer, not a crash: the unit's
    startDelay parks fah-client in ExecStartPre (`sleep 90` on the hp-z240)
    so the port is still cold, and the pause window stops the client outright
    between pauseStart and pauseEnd. An uncaught ConnectionRefusedError here
    printed a 25-line websocket-client traceback per attempt, which buried
    the one interesting line in the journal (hp-z240-xeon-1240v6, boot inside
    the pause window 2026-11-15: 70 tracebacks, then the real reason,
    "fah-client did not come up", at the end of it).

    So: one line per attempt, then re-raise for the caller to report.
    """
    deadline = time.time() + wait_secs
    while True:
        try:
            return websocket.create_connection(f"ws://{addr}/api/websocket", timeout=10)
        except (OSError, websocket.WebSocketException) as err:
            if time.time() >= deadline:
                raise
            print(f"waiting for fah-client on {addr}", file=sys.stderr, flush=True)
            time.sleep(5)


def configure(addr, wait_gpu_secs=60, no_gpus=False):
    deadline = time.time() + wait_gpu_secs
    enable = {}
    while True:
        ws = open_socket(addr)
        state = json.loads(ws.recv())
        gpus = state.get("info", {}).get("gpus", {})
        enable = {} if no_gpus else {
            gid: {"enabled": True}
            for gid, gpu in gpus.items()
            if gpu.get("supported")
        }
        # No GPUs yet right after start is normal; give the client's OpenCL
        # detection a minute, then fold with whatever we found.
        if enable or no_gpus or time.time() >= deadline:
            ws.send(
                json.dumps(
                    {
                        "cmd": "config",
                        "config": {
                            "groups": {"": {"gpus": enable, "paused": False}}
                        },
                    }
                )
            )
            ws.close()
            return enable
        ws.close()
        time.sleep(5)


def main():
    args = [a for a in sys.argv[1:] if a != "--no-gpus"]
    no_gpus = "--no-gpus" in sys.argv[1:]
    addr = args[0] if args else "127.0.0.1:7396"
    try:
        enable = configure(addr, no_gpus=no_gpus)
    except (OSError, websocket.WebSocketException) as err:
        # The end of the retry wait: one line naming the address, never a
        # traceback (see open_socket).
        print(f"could not reach fah-client on {addr}: {err}", file=sys.stderr)
        return 1
    print(
        "folding enabled; GPUs forced OFF"
        if no_gpus
        else "folding enabled; GPUs on: " + (", ".join(enable) if enable else "none")
    )


if __name__ == "__main__":
    sys.exit(main())
