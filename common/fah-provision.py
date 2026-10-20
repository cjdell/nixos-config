#!/usr/bin/env python3
"""Enable every supported GPU and start folding on a local fah-client.

A fresh Folding@home v8 client starts paused with an empty GPU list in its
default resource group (src/resources/group.json); the supported way to
change that is the websocket API served on the client's http-addresses, the
same one app.foldingathome.org and `fahctl` use.

Usage: fah-provision [HOST:PORT]   (default 127.0.0.1:7396)
"""

import json
import sys
import time

import websocket


def configure(addr, wait_gpu_secs=60):
    deadline = time.time() + wait_gpu_secs
    enable = {}
    while True:
        ws = websocket.create_connection(f"ws://{addr}/api/websocket", timeout=10)
        state = json.loads(ws.recv())
        gpus = state.get("info", {}).get("gpus", {})
        enable = {
            gid: {"enabled": True}
            for gid, gpu in gpus.items()
            if gpu.get("supported")
        }
        # No GPUs yet right after start is normal; give the client's OpenCL
        # detection a minute, then fold with whatever we found.
        if enable or time.time() >= deadline:
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
    addr = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:7396"
    enable = configure(addr)
    print("folding enabled; GPUs on:", ", ".join(enable) if enable else "none")


if __name__ == "__main__":
    sys.exit(main())
