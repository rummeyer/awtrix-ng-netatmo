#!/usr/bin/env python3
"""Install the LaMetric icons the Netatmo app's rooms name on a clock that cannot draw them from
LaMetric's address itself, as the TC001.

    python3 install-icons.py <clock-ip> [<clock-ip> ...]

Reads the rooms from the app's settings on each clock, and every icon number not yet in its /ICONS
is fetched from LaMetric, a still PNG turned into a GIF, and uploaded under its number. Icons
already there are left alone, so it can run as often as you like, from cron for instance.
Only the Python standard library.
"""
import json
import re
import struct
import sys
import urllib.request
import uuid
import zlib

LAMETRIC = "https://developer.lametric.com/content/apps/icon_thumbs/"


def get(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return r.read()


def png_pixels(data):
    """The RGBA pixels of a PNG, row by row; 8-bit grey, RGB, palette, grey+alpha or RGBA."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, palette, trns = 8, b"", None, None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += n + 12
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            palette = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat += body
    if depth != 8 or interlace:
        raise ValueError("only 8-bit, non-interlaced PNGs")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(idat)
    stride = w * channels
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prev[x]
            c = prev[x - channels] if x >= channels else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    px = []
    for line in rows:
        for x in range(w):
            v = line[x * channels:(x + 1) * channels]
            if ctype == 0:
                px.append((v[0], v[0], v[0], 255))
            elif ctype == 2:
                px.append((v[0], v[1], v[2], 255))
            elif ctype == 3:
                alpha = trns[v[0]] if trns and v[0] < len(trns) else 255
                px.append(palette[v[0]] + (alpha,))
            elif ctype == 4:
                px.append((v[0], v[0], v[0], v[1]))
            else:
                px.append(tuple(v))
    return w, h, px


def gif(w, h, px):
    """A still GIF of RGBA pixels, transparent ones black, as the clock shows black as off."""
    colours = [(0, 0, 0)]
    index = []
    for r, g, b, a in px:
        c = (r, g, b) if a >= 128 else (0, 0, 0)
        if c not in colours:
            colours.append(c)
        index.append(colours.index(c))
    if len(colours) > 256:
        raise ValueError("more than 256 colours")
    bits = max(2, (len(colours) - 1).bit_length())
    table = colours + [(0, 0, 0)] * ((1 << bits) - len(colours))
    # LZW without compression: a clear code before the table would grow a bit, so every code keeps
    # bits + 1 bits.
    clear, end, width = 1 << bits, (1 << bits) + 1, bits + 1
    codes, run = [clear], 0
    for i in index:
        if run == (1 << bits) - 2:
            codes.append(clear)
            run = 0
        codes.append(i)
        run += 1
    codes.append(end)
    acc = nbits = 0
    stream = bytearray()
    for c in codes:
        acc |= c << nbits
        nbits += width
        while nbits >= 8:
            stream.append(acc & 255)
            acc >>= 8
            nbits -= 8
    if nbits:
        stream.append(acc & 255)
    out = bytearray(b"GIF89a" + struct.pack("<HHBBB", w, h, 0x80 | (bits - 1), 0, 0))
    for c in table:
        out += bytes(c)
    out += b"," + struct.pack("<HHHHB", 0, 0, w, h, 0) + bytes([bits])
    for i in range(0, len(stream), 255):
        chunk = stream[i:i + 255]
        out += bytes([len(chunk)]) + chunk
    out += b"\x00;"
    return bytes(out)


def upload(clock, name, data):
    boundary = uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
            f"Content-Type: image/gif\r\n\r\n").encode() + data + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"http://{clock}/api/v1/files?dir=/ICONS", data=body, method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def install(clock):
    # The TC002 draws them from LaMetric's address; nothing to install there.
    platform = json.loads(get(f"http://{clock}/api/v1/capabilities"))["platform"]["id"]
    if platform == "tc002":
        print(f"{clock}: a TC002 draws the icons from LaMetric, nothing to install")
        return
    config = json.loads(get(f"http://{clock}/api/v1/apps/Netatmo/config"))
    rooms = next(f["value"] for f in config["fields"] if f["key"] == "rooms")
    wanted = sorted(set(re.findall(r":\s*(\d+)", rooms)), key=int)
    files = json.loads(get(f"http://{clock}/api/v1/files?dir=%2FICONS"))["files"]
    have = {re.sub(r"\.[^.]+$", "", f["name"]) for f in files}
    for number in wanted:
        if number in have:
            print(f"{clock}: {number} is there")
            continue
        data = get(LAMETRIC + number)
        if data[:3] != b"GIF":
            data = gif(*png_pixels(data))
        answer = upload(clock, number + ".gif", data)
        print(f"{clock}: {number} installed" if answer.get("ok") else f"{clock}: {number} failed: {answer}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for clock in sys.argv[1:]:
        install(clock)
