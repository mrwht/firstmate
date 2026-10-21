#!/usr/bin/env python3
"""Send one narrowly scoped workspace.move request to a Herdr control socket.

This helper is the wire transport for Firstmate's optional presentation-only
workspace ordering. It accepts only an exact workspace id and a non-negative
insert index, sends only the non-destructive ``workspace.move`` method, and
prints the verified JSON response.

Wire protocol verified against Herdr 0.7.4, protocol 16:

  request:  {"id":"fm-workspace-move","method":"workspace.move",
             "params":{"workspace_id":W,"insert_index":N}}\n
  response: {"id":"fm-workspace-move","result":
             {"type":"workspace_list","workspaces":[...]}}\n
Usage: herdr-workspace-move.py <socket_path> <workspace_id> <insert_index>

The socket is reached relative to its own directory, so a canonical path
that resolves through long symlinked parents (for example a home-manager
~/.config/herdr) still connects even when the absolute spelling exceeds the
platform's AF_UNIX sun_path limit. Only a socket file name that is itself too
long for sun_path is refused, with a message naming the limit.

Exit status:
  0  the server returned the matching workspace_list response;
  2  arguments or socket connection were invalid, including a socket name
     too long for AF_UNIX;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.
"""

import json
import os
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
REQUEST_ID = "fm-workspace-move"
# sockaddr_un.sun_path size, including the terminating NUL.
SUN_PATH_MAX = 108 if sys.platform.startswith("linux") else 104


def _connect(sock, socket_path):
    directory, name = os.path.split(socket_path)
    name_bytes = len(os.fsencode(name))
    if not name or name_bytes >= SUN_PATH_MAX:
        sys.stderr.write(
            "herdr-workspace-move: socket name %r is %d bytes; AF_UNIX allows"
            " at most %d even when connecting relative to its directory\n"
            % (name, name_bytes, SUN_PATH_MAX - 1)
        )
        raise OSError("socket name exceeds the AF_UNIX sun_path limit")
    os.chdir(directory)
    sock.connect(name)


def _read_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def main(argv):
    if len(argv) != 4:
        return 2
    socket_path, workspace_id, raw_index = argv[1:]
    if not socket_path.startswith("/") or not workspace_id:
        return 2
    if any(char in workspace_id for char in "\t\r\n"):
        return 2
    try:
        insert_index = int(raw_index)
    except ValueError:
        return 2
    if insert_index < 0 or str(insert_index) != raw_index:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        _connect(sock, socket_path)
    except OSError:
        return 2

    request = {
        "id": REQUEST_ID,
        "method": "workspace.move",
        "params": {"workspace_id": workspace_id, "insert_index": insert_index},
    }
    try:
        sock.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
    except OSError:
        return 3

    line = _read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    result = response.get("result") if isinstance(response, dict) else None
    if (
        response.get("id") != REQUEST_ID
        or response.get("error") is not None
        or not isinstance(result, dict)
        or result.get("type") != "workspace_list"
        or not isinstance(result.get("workspaces"), list)
    ):
        return 4
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
