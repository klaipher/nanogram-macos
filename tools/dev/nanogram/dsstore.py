"""A minimal .DS_Store reader and writer (Finder's buddy-allocated B-tree), and a version 2 alias record, enough to
lay out a disk image window without driving Finder. Format notes: https://metacpan.org/dist/Mac-Finder-DSStore."""
from __future__ import annotations

import os
import struct
from dataclasses import dataclass
from pathlib import Path

__all__ = ["Record", "NodeOverflow", "write", "read", "iloc", "alias"]

PAGE_SIZE = 0x1000
HFS_EPOCH_OFFSET = 2082844800


class NodeOverflow(ValueError):
    pass


@dataclass(frozen=True)
class Record:
    filename: str
    code: str
    type: str
    value: object

    def sort_key(self) -> tuple[str, str]:
        return self.filename.lower(), self.code

    def encode(self) -> bytes:
        name = self.filename.encode("utf-16-be")
        head = struct.pack(">I", len(name) // 2) + name + self.code.encode("ascii") + self.type.encode("ascii")
        if self.type in ("long", "shor"):
            return head + struct.pack(">I", self.value)
        if self.type == "bool":
            return head + struct.pack(">?", self.value)
        if self.type == "type":
            return head + self.value.encode("ascii")
        if self.type == "blob":
            return head + struct.pack(">I", len(self.value)) + self.value
        if self.type == "ustr":
            text = self.value.encode("utf-16-be")
            return head + struct.pack(">I", len(text) // 2) + text
        if self.type in ("comp", "dutc"):
            return head + struct.pack(">Q", self.value)
        raise ValueError(f"unsupported .DS_Store record type {self.type!r}")


def iloc(x: int, y: int) -> bytes:
    return struct.pack(">IIII", x, y, 0xFFFFFFFF, 0xFFFF0000)


class _Buddy:
    def __init__(self):
        self.free: dict[int, list[int]] = {width: [] for width in range(32)}
        self.free[31] = [0]

    def allocate(self, size: int) -> int:
        width = max(5, (size - 1).bit_length())
        level = width
        while not self.free[level]:
            level += 1
        offset = self.free[level].pop(0)
        while level > width:
            level -= 1
            self.free[level].append(offset + (1 << level))
            self.free[level].sort()
        return offset | width


def _block_range(address: int) -> tuple[int, int]:
    width = address & 0x1F
    return (address & ~0x1F) + 4, 1 << width


def write(path: Path, records: list[Record]) -> None:
    records = sorted(records, key=Record.sort_key)
    leaf = struct.pack(">II", 0, len(records)) + b"".join(record.encode() for record in records)
    if len(leaf) > PAGE_SIZE:
        raise NodeOverflow(f".DS_Store records take {len(leaf)} bytes, more than one {PAGE_SIZE}-byte node")
    buddy = _Buddy()
    buddy.allocate(32)
    database = buddy.allocate(32)
    root = buddy.allocate(2048)
    node = buddy.allocate(PAGE_SIZE)
    addresses = [root, database, node]
    database_block = struct.pack(">IIIII", 2, 0, len(records), 1, PAGE_SIZE)
    table = struct.pack(">II", len(addresses), 0) + struct.pack(f">{len(addresses)}I", *addresses)
    table += b"\0" * (4 * (256 - len(addresses)))
    table += struct.pack(">IB", 1, 4) + b"DSDB" + struct.pack(">I", 1)
    for width in range(32):
        table += struct.pack(">I", len(buddy.free[width]))
        table += b"".join(struct.pack(">I", offset) for offset in buddy.free[width])
    root_offset, root_size = _block_range(root)
    if len(table) > root_size:
        raise ValueError("the .DS_Store allocator table does not fit its block")
    end = max(sum(_block_range(address)) for address in addresses)
    data = bytearray(end)
    data[0:36] = struct.pack(">I4sIII16s", 1, b"Bud1", root_offset - 4, root_size, root_offset - 4, b"\0" * 16)
    for address, content in ((root, table), (database, database_block), (node, leaf)):
        start, size = _block_range(address)
        data[start:start + len(content)] = content
    Path(path).write_bytes(bytes(data))


def _decode_record(data: bytes, at: int) -> tuple[Record, int]:
    (length,) = struct.unpack_from(">I", data, at)
    at += 4
    filename = data[at:at + 2 * length].decode("utf-16-be")
    at += 2 * length
    code, kind = data[at:at + 4].decode("ascii"), data[at + 4:at + 8].decode("ascii")
    at += 8
    if kind in ("long", "shor"):
        value, at = struct.unpack_from(">I", data, at)[0], at + 4
    elif kind == "bool":
        value, at = bool(data[at]), at + 1
    elif kind == "type":
        value, at = data[at:at + 4].decode("ascii"), at + 4
    elif kind == "blob":
        (size,) = struct.unpack_from(">I", data, at)
        value, at = data[at + 4:at + 4 + size], at + 4 + size
    elif kind == "ustr":
        (size,) = struct.unpack_from(">I", data, at)
        value, at = data[at + 4:at + 4 + 2 * size].decode("utf-16-be"), at + 4 + 2 * size
    elif kind in ("comp", "dutc"):
        value, at = struct.unpack_from(">Q", data, at)[0], at + 8
    else:
        raise ValueError(f"unsupported .DS_Store record type {kind!r}")
    return Record(filename, code, kind, value), at


def read(path: Path) -> list[Record]:
    data = Path(path).read_bytes()
    one, magic, root_offset, root_size, root_copy, _ = struct.unpack_from(">I4sIII16s", data, 0)
    if one != 1 or magic != b"Bud1" or root_offset != root_copy:
        raise ValueError(f"{path} is not a .DS_Store file")
    at = root_offset + 4
    (count,) = struct.unpack_from(">I", data, at)
    addresses = struct.unpack_from(f">{count}I", data, at + 8)
    at += 8 + 4 * ((count + 255) // 256 * 256)
    (entries,) = struct.unpack_from(">I", data, at)
    at += 4
    directory = {}
    for _ in range(entries):
        size = data[at]
        name = data[at + 1:at + 1 + size].decode("ascii")
        (block,) = struct.unpack_from(">I", data, at + 1 + size)
        directory[name] = block
        at += 5 + size
    start, _ = _block_range(addresses[directory["DSDB"]])
    (top,) = struct.unpack_from(">I", data, start)
    records: list[Record] = []

    def walk(block: int) -> None:
        offset, _ = _block_range(addresses[block])
        rightmost, count = struct.unpack_from(">II", data, offset)
        at = offset + 8
        for _ in range(count):
            if rightmost:
                (child,) = struct.unpack_from(">I", data, at)
                walk(child)
                at += 4
            record, at = _decode_record(data, at)
            records.append(record)
        if rightmost:
            walk(rightmost)

    walk(top)
    return records


def _pascal(text: str, size: int) -> bytes:
    raw = text.replace(":", "/").encode("utf-8")[:size - 1]
    return bytes([len(raw)]) + raw.ljust(size - 1, b"\0")


def _tag(tag: int, payload: bytes) -> bytes:
    padded = payload + (b"\0" if len(payload) % 2 else b"")
    return struct.pack(">hH", tag, len(payload)) + padded


def _unicode(text: str) -> bytes:
    raw = text.encode("utf-16-be")
    return struct.pack(">H", len(raw) // 2) + raw


def _hfs_seconds(timestamp: float) -> int:
    return int(timestamp) + HFS_EPOCH_OFFSET


def alias(target: Path, mount_point: Path, volume_name: str) -> bytes:
    """A version 2 alias record of `target` (a file on the volume mounted at `mount_point`), as Finder stores the
    background picture of a window: volume name and creation date, parent and target catalog ids, and paths."""
    target, mount_point = Path(target), Path(mount_point)
    relative = target.relative_to(mount_point)
    info, parent, volume = os.stat(target), os.stat(target.parent), os.stat(mount_point)
    volume_date, target_date = volume.st_birthtime, info.st_birthtime
    body = struct.pack(">h28sI2shI64sII4s4s", 0, _pascal(volume_name, 28), _hfs_seconds(volume_date), b"H+", 0,
                       parent.st_ino, _pascal(target.name, 64), info.st_ino, _hfs_seconds(target_date),
                       b"\0" * 4, b"\0" * 4)
    body += struct.pack(">HHIh10s", 0xFFFF, 0xFFFF, 0, 0, b"\0" * 10)
    cnid_path = []
    folder = target.parent
    while folder != mount_point:
        cnid_path.append(os.stat(folder).st_ino)
        folder = folder.parent
    extras = [
        _tag(0, target.parent.name.encode("utf-8")) if target.parent != mount_point else b"",
        _tag(1, struct.pack(f">{len(cnid_path)}I", *cnid_path)) if cnid_path else b"",
        _tag(2, ":".join([volume_name, *relative.parts]).encode("utf-8")),
        _tag(14, _unicode(target.name)),
        _tag(15, _unicode(volume_name)),
        _tag(16, struct.pack(">Q", int(_hfs_seconds(volume_date) * 65536))),
        _tag(17, struct.pack(">Q", int(_hfs_seconds(target_date) * 65536))),
        _tag(18, f"/{relative.as_posix()}".encode("utf-8")),
        _tag(19, f"/Volumes/{volume_name}".encode("utf-8")),
        struct.pack(">hH", -1, 0),
    ]
    record = body + b"".join(extras)
    return struct.pack(">4sHh", b"\0" * 4, 8 + len(record), 2) + record
