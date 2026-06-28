#!/usr/bin/env python3
"""
Bind UDP port 1028, strip RTP headers, write raw MPEG-TS to stdout.
Samsung WFD sends RTP PT=33 (MPEG-TS wrapped in RTP over UDP).
"""
import socket
import struct
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('0.0.0.0', 1028))
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)

out = sys.stdout.buffer
while True:
    pkt = sock.recv(2048)
    if len(pkt) < 12:
        continue
    # RTP fixed header: V(2)|P(1)|X(1)|CC(4) in first byte
    cc = pkt[0] & 0x0F
    hlen = 12 + cc * 4
    if pkt[0] & 0x10:  # extension bit set
        if len(pkt) < hlen + 4:  # need the 4-byte extension header
            continue
        ext_words = struct.unpack_from('>H', pkt, hlen + 2)[0]
        hlen += 4 + ext_words * 4
    if len(pkt) <= hlen:  # malformed/truncated packet, no payload
        continue
    try:
        out.write(pkt[hlen:])
        out.flush()
    except (BrokenPipeError, OSError):
        sys.exit(0)
