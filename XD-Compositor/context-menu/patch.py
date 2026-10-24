"""Patch XD resources while preserving every original local ZIP record and offset."""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import plistlib
import re
import struct
import tempfile
import zipfile
import zlib


ROOT = Path(__file__).resolve().parent
ARCHIVE_PATH = Path('Contents/Resources/data/.resources.app.data')


def open_archive(data):
    return zipfile.ZipFile(io.BytesIO(data[:-22] + b'PK\x05\x06' + data[-18:]))


def central_records(data):
    if len(data) < 22 or data[-22:-18] != bytes(4):
        raise ValueError('Unexpected XD archive footer')
    _, disk, directory_disk, disk_count, count, size, offset, comment = struct.unpack_from(
        '<4s4H2IH', data, len(data) - 22)
    if disk or directory_disk or disk_count != count or comment or offset + size != len(data) - 22:
        raise ValueError('Unsupported ZIP directory layout')
    records = {}
    cursor = offset
    for _ in range(count):
        fields = struct.unpack_from('<4s6H3I5H2I', data, cursor)
        if fields[0] != b'PK\x01\x02' or fields[13] or fields[16] == 0xffffffff:
            raise ValueError('Unsupported ZIP central record')
        name_size, extra_size, comment_size = fields[10:13]
        end = cursor + 46 + name_size + extra_size + comment_size
        name = data[cursor + 46:cursor + 46 + name_size].decode(
            'utf-8' if fields[3] & 0x800 else 'cp437')
        if name in records or end > offset + size:
            raise ValueError('Duplicate or truncated ZIP entry')
        records[name] = data[cursor:end]
        cursor = end
    if cursor != offset + size:
        raise ValueError('Unexpected bytes in ZIP central directory')
    return offset, records


def replacement_contents(data):
    changes = {}
    with open_archive(data) as source:
        command_name = 'commands/PhotoshopCommands.js'
        current_command = source.read(command_name)
        replacement_command = (ROOT / 'PhotoshopCommands.js').read_bytes()
        if current_command != replacement_command:
            if 'this.photoshopBridge.createAndWatchPsdFile' not in current_command.decode('utf-8'):
                raise ValueError('Unexpected Photoshop command; archive left unchanged')
            changes[command_name] = replacement_command
        for locale in ['zh-Hans', 'en']:
            name = 'locale/' + locale + '.js'
            content = source.read(name).decode('utf-8')
            for key in ['CMD_EDIT_IN_PHOTOSHOP', 'EDIT_IN_PHOTOSHOP']:
                pattern = r'(?<![A-Z_])(' + key + r':)(["\x27])([^"\x27]*)\2'

                def replace(match):
                    old = match.group(3)
                    if 'Photoshop' not in old and 'PhotoCraft' not in old:
                        raise ValueError('Unexpected editor label: ' + key)
                    return match.group(1) + match.group(2) + old.replace('Photoshop', 'PhotoCraft') + match.group(2)

                content, count = re.subn(pattern, replace, content)
                if count != 1:
                    raise ValueError('Expected one locale entry: ' + key)
            replacement = content.encode('utf-8')
            if replacement != source.read(name):
                changes[name] = replacement
    return changes


def local_record(data, info, content):
    start = info.header_offset
    header_fields = struct.unpack_from('<4s5H3I2H', data, start)
    if header_fields[0] != b'PK\x03\x04' or header_fields[2:4] != (info.flag_bits, info.compress_type):
        raise ValueError('Unexpected local header: ' + info.filename)
    if info.flag_bits & 1 or info.file_size >= 0xffffffff or info.compress_size >= 0xffffffff:
        raise ValueError('Encrypted/ZIP64 entries are unsupported')
    header_size = 30 + header_fields[-2] + header_fields[-1]
    header = bytearray(data[start:start + header_size])
    if info.compress_type == zipfile.ZIP_DEFLATED:
        compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
        compressed = compressor.compress(content) + compressor.flush()
    elif info.compress_type == zipfile.ZIP_STORED:
        compressed = content
    else:
        raise ValueError('Unsupported ZIP compression')
    values = (zlib.crc32(content) & 0xffffffff, len(compressed), len(content))
    descriptor = b''
    if info.flag_bits & 8:
        descriptor_offset = start + header_size + info.compress_size
        signed = data[descriptor_offset:descriptor_offset + 4] == b'PK\x07\x08'
        old_values = struct.unpack_from('<3I', data, descriptor_offset + (4 if signed else 0))
        if old_values != (info.CRC, info.compress_size, info.file_size):
            raise ValueError('Unexpected data descriptor: ' + info.filename)
        if header_fields[6:9] != (0, 0, 0):
            struct.pack_into('<3I', header, 14, *values)
        descriptor = (b'PK\x07\x08' if signed else b'') + struct.pack('<3I', *values)
    else:
        struct.pack_into('<3I', header, 14, *values)
    return bytes(header) + compressed + descriptor, values


def build_archive(data, changes):
    offset, records = central_records(data)
    if not set(changes).issubset(records):
        raise ValueError('Replacement entry is missing from source archive')
    output = bytearray(data[:offset])
    with open_archive(data) as source:
        for name, content in changes.items():
            replacement, values = local_record(data, source.getinfo(name), content)
            record = bytearray(records[name])
            struct.pack_into('<3I', record, 16, *values)
            struct.pack_into('<I', record, 42, len(output))
            records[name] = bytes(record)
            output.extend(replacement)
    new_offset = len(output)
    output.extend(b''.join(records.values()))
    footer = bytearray(data[-22:])
    struct.pack_into('<I', footer, 16, new_offset)
    output.extend(footer)
    return bytes(output)


def verify_archive(original, packed, changes):
    old_offset, old_records = central_records(original)
    new_offset, new_records = central_records(packed)
    if packed[:old_offset] != original[:old_offset] or list(old_records) != list(new_records):
        raise ValueError('Original local records or entry order changed')
    expected_footer = bytearray(original[-22:])
    struct.pack_into('<I', expected_footer, 16, new_offset)
    if packed[-22:] != expected_footer:
        raise ValueError('Unexpected ZIP footer changes')
    with open_archive(original) as source, open_archive(packed) as result:
        for name, old_record in old_records.items():
            expected = changes[name] if name in changes else source.read(name)
            if result.read(name) != expected:
                raise ValueError('Unexpected resource content: ' + name)
            old_info, new_info = source.getinfo(name), result.getinfo(name)
            if name in changes:
                record = bytearray(new_records[name])
                record[16:28] = old_record[16:28]
                record[42:46] = old_record[42:46]
                if record != old_record or new_info.header_offset < old_offset:
                    raise ValueError('Unexpected replacement metadata: ' + name)
            elif old_record != new_records[name] or old_info.header_offset != new_info.header_offset:
                raise ValueError('Unchanged entry metadata moved: ' + name)
    return {'entryCount': len(old_records), 'unchangedEntries': len(old_records) - len(changes),
            'preservedLocalBytes': old_offset, 'originalDirectoryOffset': old_offset,
            'newDirectoryOffset': new_offset, 'changedEntries': list(changes)}


def apply(app):
    archive = app / ARCHIVE_PATH
    version = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
    if version != '59.0.12.2':
        raise ValueError('This patch is verified for XD 59.0.12.2 only')
    original = archive.read_bytes()
    before_hash = hashlib.sha256(original).hexdigest()
    changes = replacement_contents(original)
    packed = build_archive(original, changes) if changes else original
    report = verify_archive(original, packed, changes)
    if changes:
        with tempfile.NamedTemporaryFile(dir=archive.parent, prefix='.photocraft-', delete=False) as temp:
            temporary = Path(temp.name)
            temp.write(packed)
        try:
            verify_archive(original, temporary.read_bytes(), changes)
            temporary.chmod(archive.stat().st_mode & 0o777)
            os.replace(temporary, archive)
        finally:
            temporary.unlink(missing_ok=True)
    report.update({'app': str(app), 'version': version, 'sourceArchive': str(archive),
                   'alreadyApplied': not bool(changes), 'beforeSHA256': before_hash,
                   'afterSHA256': hashlib.sha256(packed).hexdigest()})
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    apply(parser.parse_args().app)
