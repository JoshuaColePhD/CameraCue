#!/usr/bin/env python3
"""Resize the source artwork and package PNG representations into an ICNS file."""

from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def icon_record(kind: bytes, image: bytes) -> bytes:
    return kind + struct.pack(">I", len(image) + 8) + image


def main() -> None:
    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    representations = [
        (16, b"icp4"),
        (32, b"icp5"),
        (64, b"icp6"),
        (128, b"ic07"),
        (256, b"ic08"),
        (512, b"ic09"),
        (1024, b"ic10"),
        (32, b"ic11"),  # 16pt @2x
        (64, b"ic12"),  # 32pt @2x
        (256, b"ic13"),  # 128pt @2x
        (512, b"ic14"),  # 256pt @2x
    ]
    with tempfile.TemporaryDirectory(prefix="cameracue-icon-") as temporary:
        records = []
        for size, kind in representations:
            png = Path(temporary) / f"icon-{size}.png"
            subprocess.run(
                ["sips", "-z", str(size), str(size), str(source), "--out", str(png)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            image = png.read_bytes()
            if not image.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError(f"Invalid PNG representation: {png}")
            width, height = struct.unpack(">II", image[16:24])
            if (width, height) != (size, size):
                raise ValueError(f"Unexpected icon dimensions: {width}x{height}")
            records.append(icon_record(kind, image))
    body = b"".join(records)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    main()
