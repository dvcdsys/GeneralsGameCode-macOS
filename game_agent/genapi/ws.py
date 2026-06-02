"""Minimal RFC 6455 WebSocket client for the game's /events stream.

Python ships no WebSocket client, so this implements just enough of the protocol (handshake +
client->server masking + server frame decode + ping/pong/close) to read the localhost text stream.
Exposes a single generator, stream_events(), that yields individual game-event dicts.
"""

import base64
import json
import os
import socket
import struct
import time


def _handshake(sock, host, port, path):
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    req = (
        "GET {path} HTTP/1.1\r\n"
        "Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        "Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).format(path=path, host=host, port=port, key=key)
    sock.sendall(req.encode("ascii"))
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(1024)
        if not chunk:
            raise ConnectionError("server closed during handshake")
        buf += chunk
    header, _, rest = buf.partition(b"\r\n\r\n")
    if b"101" not in header.split(b"\r\n", 1)[0]:
        raise ConnectionError("handshake failed: " + header.decode("latin1", "replace"))
    return rest


class _FrameReader:
    def __init__(self, sock, leftover=b""):
        self.sock = sock
        self.buf = bytearray(leftover)

    def _need(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("server closed")
            self.buf += chunk

    def read_frame(self):
        self._need(2)
        b0, b1 = self.buf[0], self.buf[1]
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        length = b1 & 0x7F
        offset = 2
        if length == 126:
            self._need(offset + 2)
            length = struct.unpack(">H", bytes(self.buf[offset:offset + 2]))[0]
            offset += 2
        elif length == 127:
            self._need(offset + 8)
            length = struct.unpack(">Q", bytes(self.buf[offset:offset + 8]))[0]
            offset += 8
        mask = b""
        if masked:
            self._need(offset + 4)
            mask = bytes(self.buf[offset:offset + 4])
            offset += 4
        self._need(offset + length)
        payload = bytes(self.buf[offset:offset + length])
        del self.buf[:offset + length]
        if mask:
            payload = bytes(p ^ mask[i % 4] for i, p in enumerate(payload))
        return opcode, payload


def _send_frame(sock, opcode, payload=b""):
    b0 = 0x80 | opcode
    n = len(payload)
    header = bytearray([b0])
    if n < 126:
        header.append(0x80 | n)
    elif n < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", n)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", n)
    mask = os.urandom(4)
    header += mask
    sock.sendall(bytes(header) + bytes(p ^ mask[i % 4] for i, p in enumerate(payload)))


def stream_events(host="127.0.0.1", port=3460, path="/events", duration=None):
    """Connect to ws://host:port/path and yield each game-event dict as it arrives.

    Yields the individual event objects inside the server's batched {"type":"events"} messages
    (each already carries seq + frame). Also yields the {"type":"hello"} greeting once. Stops after
    `duration` seconds if given, or when the server closes / KeyboardInterrupt.
    """
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(1.0)
    reader = _FrameReader(sock, _handshake(sock, host, port, path))
    deadline = (time.monotonic() + duration) if duration else None
    try:
        while True:
            if deadline and time.monotonic() >= deadline:
                return
            try:
                opcode, payload = reader.read_frame()
            except socket.timeout:
                continue
            if opcode == 0x8:                       # close
                return
            if opcode == 0x9:                       # ping -> pong
                _send_frame(sock, 0xA, payload)
                continue
            if opcode not in (0x1, 0x2):            # only text/binary carry json
                continue
            try:
                msg = json.loads(payload.decode("utf-8"))
            except Exception:  # noqa: BLE001
                continue
            if msg.get("type") == "events":
                for ev in msg.get("events", []):
                    yield ev
            else:
                yield msg                            # hello / other
    finally:
        try:
            _send_frame(sock, 0x8)
        except OSError:
            pass
        sock.close()
