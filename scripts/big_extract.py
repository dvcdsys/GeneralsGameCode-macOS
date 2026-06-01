#!/usr/bin/env python3
"""Minimal BIGF/.gib archive extractor for C&C Generals / Zero Hour.

Format (matches StdBIGFileSystem.cpp::openArchiveFile):
  off 0x00  4 bytes   "BIGF" magic
  off 0x04  4 bytes   archive total size (LE in the parser; we don't validate)
  off 0x08  4 bytes   number of files (BE)
  off 0x0C  4 bytes   header/index size (BE)
  off 0x10  per file: 4B offset (BE) + 4B size (BE) + null-terminated path
  raw file payloads at the listed offsets.

Usage:
  big_extract.py list  <archive>                    # list every file
  big_extract.py grep  <archive> <pattern>          # list paths matching substring (case-insensitive)
  big_extract.py cat   <archive> <internal_path>    # write one file to stdout
  big_extract.py find_text <archive> <text>         # find INI/text files containing the text
"""
import struct
import sys
import re


def read_archive(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"BIGF":
        raise SystemExit(f"{path}: not a BIGF archive (magic={data[:4]!r})")
    (num_files,) = struct.unpack(">I", data[8:12])
    pos = 0x10
    entries = []
    for _ in range(num_files):
        offset, size = struct.unpack(">II", data[pos : pos + 8])
        pos += 8
        end = data.index(b"\x00", pos)
        name = data[pos:end].decode("latin-1")
        pos = end + 1
        entries.append((name, offset, size))
    return data, entries


def cmd_list(path):
    _, entries = read_archive(path)
    for name, offset, size in entries:
        print(f"{size:10d}  {name}")


def cmd_grep(path, pattern):
    _, entries = read_archive(path)
    pat = pattern.lower()
    for name, offset, size in entries:
        if pat in name.lower():
            print(f"{size:10d}  {name}")


def cmd_cat(path, internal):
    data, entries = read_archive(path)
    needle = internal.lower().replace("/", "\\")
    for name, offset, size in entries:
        if name.lower() == needle:
            sys.stdout.buffer.write(data[offset : offset + size])
            return
    raise SystemExit(f"not found: {internal}")


def cmd_find_text(path, text):
    data, entries = read_archive(path)
    text_lower = text.lower().encode("latin-1")
    for name, offset, size in entries:
        # Only scan plausibly textual files to stay fast.
        if not re.search(r"\.(ini|str|txt|map)$", name, re.IGNORECASE):
            continue
        chunk = data[offset : offset + size]
        if text_lower in chunk.lower():
            print(f"{size:10d}  {name}")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    op = sys.argv[1]
    arc = sys.argv[2]
    if op == "list":
        cmd_list(arc)
    elif op == "grep":
        cmd_grep(arc, sys.argv[3])
    elif op == "cat":
        cmd_cat(arc, sys.argv[3])
    elif op == "find_text":
        cmd_find_text(arc, sys.argv[3])
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
