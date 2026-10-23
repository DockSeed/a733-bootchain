#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only OR MIT
# SPDX-FileCopyrightText: the authors of this repository
#
# Read a built u-boot-sunxi-with-spl.bin (eGON SPL, then a FIT) for the
# post-build assertions in scripts/build.sh. Reads only; never writes. Only
# our own build output is read: the vendor DRAM blob inside the SPL is
# located by comparing bytes with the pinned file, nothing more.
#
# Usage:
#   sunxi-spl-image.py layout <image>
#       spl_length=0x...       eGON length field (offset 0x10)
#       fit_offset=0x...       first FDT at or after spl_length with /images
#       image <node> type=<t> load=0x.. entry=0x.. size=<n> desc=<text>
#       config <node> default=<0|1> firmware=<x> loadables=<a,b> fdt=<x>
#       timestamp=<n>          the FIT root `timestamp`
#   sunxi-spl-image.py env <image> <name>
#       the value of <name> in U-Boot's default environment (NUL-separated
#       "name=value" strings); fails unless exactly one value is found
#   sunxi-spl-image.py find <image> <file>
#       every offset at which the bytes of <file> occur in <image>
#   sunxi-spl-image.py epoch <image> <epoch>
#       every U-Boot banner, TF-A `Built :` string and FIT root `timestamp`
#       must read <epoch>, and each kind must be found at least once
import re
import struct
import sys
import time

FDT_MAGIC = b'\xd0\x0d\xfe\xed'


def fdt_nodes(data, base):
    """Walk the FDT at base; yield (path, props) for every node."""
    magic, total, off_struct, off_strings = struct.unpack_from('>4I', data, base)
    if base + total > len(data):
        raise ValueError('truncated FDT')
    p, stack, props = base + off_struct, [], {}
    out = []
    while True:
        tag = struct.unpack_from('>I', data, p)[0]
        p += 4
        if tag == 1:
            end = data.index(b'\0', p)
            stack.append((data[p:end].decode(), props))
            props = {}
            p = (end + 1 + 3) & ~3
        elif tag == 2:
            name, parent = stack.pop()
            path = '/'.join([n for n, _ in stack] + [name]) or '/'
            out.append((path, props))
            props = parent
            if not stack:
                return out
        elif tag == 3:
            length, name_off = struct.unpack_from('>II', data, p)
            p += 8
            start = base + off_strings + name_off
            pname = data[start:data.index(b'\0', start)].decode()
            props[pname] = data[p:p + length]
            p = (p + length + 3) & ~3
        elif tag == 4:
            pass
        elif tag == 9:
            return out
        else:
            raise ValueError('bad FDT tag %#x' % tag)


def s(v):
    return v.rstrip(b'\0').decode(errors='replace')


def u32(v):
    return struct.unpack('>I', v)[0] if v is not None and len(v) == 4 else None


def strlist(v):
    return ','.join(x.decode() for x in v.rstrip(b'\0').split(b'\0')) if v else ''


def find_fit(data, start):
    for m in re.finditer(re.escape(FDT_MAGIC), data[start:]):
        base = start + m.start()
        try:
            nodes = fdt_nodes(data, base)
        except (struct.error, ValueError, IndexError):
            continue
        if any(path == '/images' for path, _ in nodes):
            return base, nodes
    return None, None


def egon_length(data):
    if data[4:12] != b'eGON.BT0':
        sys.exit('::error:: no eGON.BT0 magic at offset 4')
    return struct.unpack_from('<I', data, 0x10)[0]


def cmd_layout(img):
    data = open(img, 'rb').read()
    length = egon_length(data)
    print('spl_length=%#x' % length)
    base, nodes = find_fit(data, length)
    if base is None:
        sys.exit('::error:: no FIT after the SPL')
    print('fit_offset=%#x' % base)
    for path, props in nodes:
        parts = path.split('/')
        if path == '/' and 'timestamp' in props:
            print('timestamp=%d' % u32(props['timestamp']))
        if len(parts) == 3 and parts[1] == 'images':
            load, entry = u32(props.get('load')), u32(props.get('entry'))
            print('image %s type=%s load=%s entry=%s size=%d desc=%s' % (
                parts[2], s(props.get('type', b'')),
                '%#x' % load if load is not None else '-',
                '%#x' % entry if entry is not None else '-',
                len(props.get('data', b'')), s(props.get('description', b''))))
    default = ''
    for path, props in nodes:
        if path == '/configurations':
            default = s(props.get('default', b''))
    for path, props in nodes:
        parts = path.split('/')
        if len(parts) == 3 and parts[1] == 'configurations':
            print('config %s default=%d firmware=%s loadables=%s fdt=%s' % (
                parts[2], parts[2] == default, strlist(props.get('firmware')),
                strlist(props.get('loadables')), strlist(props.get('fdt'))))


def cmd_env(img, name):
    data = open(img, 'rb').read()
    vals = set(m.group(1) for m in re.finditer(
        rb'\0' + re.escape(name.encode()) + rb'=([^\0]*)\0', data))
    if len(vals) != 1:
        sys.exit('::error:: %d values of %s in the default environment: %r' % (len(vals), name, sorted(vals)))
    print(vals.pop().decode())


def cmd_find(img, blob):
    data, b = open(img, 'rb').read(), open(blob, 'rb').read()
    i = data.find(b)
    while i >= 0:
        print('%#x' % i)
        i = data.find(b, i + 1)


def cmd_epoch(img, epoch):
    data = open(img, 'rb').read()
    epoch = int(epoch)
    MON = 'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split()
    g = time.gmtime(epoch)
    # U-Boot: U_BOOT_DATE "%b %d %C%y", U_BOOT_TIME "%T", U_BOOT_TZ "%z" under date -u.
    uboot = '%s %02d %d - %02d:%02d:%02d +0000' % (MON[g.tm_mon - 1], g.tm_mday, g.tm_year, g.tm_hour, g.tm_min, g.tm_sec)
    # TF-A: __TIME__ ", " __DATE__ -> "hh:mm:ss, Mmm dd yyyy", the day space-padded.
    tfa = '%02d:%02d:%02d, %s %2d %d' % (g.tm_hour, g.tm_min, g.tm_sec, MON[g.tm_mon - 1], g.tm_mday, g.tm_year)
    bad = 0

    def kind(what, found, want):
        nonlocal bad
        if not found:
            print('::error:: no %s found in %s -- the banner format changed? this check cannot read it' % (what, img))
            bad += 1
            return
        wrong = sorted(set(found) - {want})
        print('%d %s, expected "%s"%s' % (len(found), what, want, ': WRONG: %s' % wrong if wrong else ': all match'))
        if wrong:
            bad += 1

    kind('U-Boot banner(s)',
         [m.decode() for m in re.findall(rb'U-Boot (?:SPL )?\d{4}\.\d\d[^\x00()]*\(([^)\x00]*)\)', data)], uboot)
    kind('TF-A "Built :" string(s)',
         [m.decode() for m in re.findall(rb'Built : ([^\x00\n]*)', data)], tfa)
    stamps = []
    for m in re.finditer(re.escape(FDT_MAGIC), data):
        try:
            nodes = fdt_nodes(data, m.start())
        except (struct.error, ValueError, IndexError):
            continue
        for path, props in nodes:
            if path == '/' and 'timestamp' in props and len(props['timestamp']) == 4:
                stamps.append(str(u32(props['timestamp'])))
    kind('FIT timestamp(s)', stamps, str(epoch))
    sys.exit(1 if bad else 0)


def main(argv):
    cmds = {'layout': (cmd_layout, 1), 'env': (cmd_env, 2), 'find': (cmd_find, 2), 'epoch': (cmd_epoch, 2)}
    if len(argv) < 2 or argv[1] not in cmds or len(argv) - 2 != cmds[argv[1]][1]:
        sys.exit(__doc__ or 'usage: see the header of this file')
    cmds[argv[1]][0](*argv[2:])


if __name__ == '__main__':
    main(sys.argv)
