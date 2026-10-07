#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""NCHD v1: 原尺寸 RGBA keyframe / 前一唯一帧 XOR + zlib，时间轴复用索引。

LE header: magic[4], version, width, height, display_count, unique_count (u32).
随后是 display_count 个 u32 索引。每个唯一帧为 mode(u32), size(u32),
sha256[32], zlib bytes。RGBA 在编码前补零到 8 字节边界，hash 不含补零。
mode 0 是完整帧，mode 1 是与前一个唯一帧的 XOR。没有色彩量化或重采样。
"""
from __future__ import annotations

import hashlib
import struct
import zlib
from pathlib import Path

MAGIC = b'NCHD'
VERSION = 1
MAX_DIMENSION = 2048
MAX_FRAMES = 4096
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_DECODED_BYTES = 256 * 1024 * 1024
HEADER = struct.Struct('<4s5I')
RECORD = struct.Struct('<2I32s')


def _validate(width, height, count, unique):
    if not (1 <= width <= MAX_DIMENSION and 1 <= height <= MAX_DIMENSION
            and 1 <= unique <= count <= MAX_FRAMES):
        raise ValueError('Invalid hdelta dimensions or frame counts')
    raw_size = width * height * 4
    if raw_size * unique > MAX_DECODED_BYTES:
        raise ValueError('hdelta decoded data exceeds memory limit')
    return raw_size, (raw_size + 7) // 8 * 8


def encode_frames(frames: list[bytes], width: int, height: int) -> bytes:
    """完整帧输入；返回可由 Godot HoverDelta 解码的紧凑容器。"""
    timeline, unique, known = [], [], {}
    for raw in frames:
        if len(raw) != width * height * 4:
            raise ValueError('Frame byte length does not match dimensions')
        digest = hashlib.sha256(raw).digest()
        if digest not in known:
            known[digest] = len(unique)
            unique.append(raw)
        timeline.append(known[digest])
    raw_size, padded_size = _validate(width, height, len(timeline), len(unique))
    out = bytearray(HEADER.pack(MAGIC, VERSION, width, height, len(timeline), len(unique)))
    out.extend(struct.pack(f'<{len(timeline)}I', *timeline))
    previous = 0
    for index, raw in enumerate(unique):
        padded = raw + bytes(padded_size - raw_size)
        current = int.from_bytes(padded, 'little')
        compressed = zlib.compress(padded, 9)
        mode = 0
        if index:
            delta = zlib.compress((current ^ previous).to_bytes(padded_size, 'little'), 9)
            if len(delta) < len(compressed):
                mode, compressed = 1, delta
        out.extend(RECORD.pack(mode, len(compressed), hashlib.sha256(raw).digest()))
        out.extend(compressed)
        previous = current
    return bytes(out)


def decode_bytes(data: bytes) -> dict:
    """严格校验后返回唯一完整帧。损坏输入抛 ValueError。"""
    if len(data) < HEADER.size or len(data) > MAX_FILE_BYTES:
        raise ValueError('Truncated hdelta header')
    magic, version, width, height, count, unique = HEADER.unpack_from(data)
    if magic != MAGIC or version != VERSION:
        raise ValueError('Unsupported hdelta format/version')
    raw_size, padded_size = _validate(width, height, count, unique)
    offset = HEADER.size
    if len(data) < offset + count * 4:
        raise ValueError('Truncated hdelta timeline')
    timeline = list(struct.unpack_from(f'<{count}I', data, offset))
    offset += count * 4
    if timeline[0] != 0 or any(i >= unique for i in timeline):
        raise ValueError('Invalid hdelta timeline index')
    frames, previous = [], 0
    for index in range(unique):
        if len(data) < offset + RECORD.size:
            raise ValueError('Truncated hdelta record')
        mode, size, digest = RECORD.unpack_from(data, offset)
        offset += RECORD.size
        if mode not in (0, 1) or (index == 0 and mode != 0):
            raise ValueError('Invalid hdelta frame mode')
        if not (0 < size <= padded_size + 65536) or offset + size > len(data):
            raise ValueError('Invalid hdelta compressed size')
        decoder = zlib.decompressobj()
        try:
            decoded = decoder.decompress(data[offset:offset + size], padded_size + 1)
        except zlib.error as exc:
            raise ValueError('Invalid hdelta zlib stream') from exc
        offset += size
        if (len(decoded) != padded_size or not decoder.eof or decoder.unused_data
                or decoder.unconsumed_tail):
            raise ValueError('Invalid hdelta decompressed size or trailing data')
        current = int.from_bytes(decoded, 'little')
        if mode == 1:
            current ^= previous
        padded = current.to_bytes(padded_size, 'little')
        raw = padded[:raw_size]
        if any(padded[raw_size:]) or hashlib.sha256(raw).digest() != digest:
            raise ValueError('hdelta frame checksum mismatch')
        frames.append(raw)
        previous = current
    if offset != len(data):
        raise ValueError('Trailing hdelta bytes')
    return {'width': width, 'height': height, 'timeline': timeline, 'frames': frames}


def decode_file(path: Path) -> dict:
    if path.stat().st_size > MAX_FILE_BYTES:
        raise ValueError('hdelta file exceeds size limit')
    return decode_bytes(path.read_bytes())
