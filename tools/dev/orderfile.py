#!/usr/bin/env python3
"""Generate the launch order file for the Nanogram for macOS executable (runtime spec M31).

Telegram-Mac/OrderFiles/ holds two lists and the file the Release link uses:
    signed-in.order    launches of the owner's signed-in release app to the chat list (the main source)
    signed-out.order   isolated launches to the login screen (baseline: login-only code, no account needed)
    Telegram.order     signed-in.order, then the signed-out symbols it does not have; rewritten on every run

Signed-in launches (the main source; the owner is signed in to the installed release):
    python3 tools/dev/orderfile.py --signed-in --app /Applications/Nanogram.app \
        --archive build-output/direct/<build>/Nanogram.xcarchive [--runs 5]

    The app must be the archive's build (the executable UUID must match the archive's dSYM) and must not be
    running. Each run drops the executable from the page cache, launches the app with your data under
    Instruments ("App Launch") for --seconds (default 8), then asks it to quit like Cmd-Q. Nothing else is done
    in the app: no chat is opened and only the samples of the app's own binary are kept.

Signed-out baseline (needs no account and leaves a running Nanogram and its data alone):
    python3 tools/dev/orderfile.py --archive build-output/direct/<build>/Nanogram.xcarchive [--runs 3]

    Each run launches an isolated copy of the archived app to the login screen: the copy is ad-hoc signed under
    its own executable name and bundle ID, and tools/dev/orderfile-isolate.m (injected with
    DYLD_INSERT_LIBRARIES) puts its app group container in a fresh temporary folder and lets it run beside an
    open Nanogram. The executable is dropped from the page cache before each run, so the trace also sees the
    functions that fault in.

Disk: a 5-8 s App Launch trace writes 1-3 GB of raw kernel trace to the user temp folder. Each run deletes its
trace, its export and the raw files it created, and no run starts below --min-free-gb (default 18), so at
least 15 GB stays free for a build running beside it.

How a list is built: the samples of the traced binary (matched by UUID) are merged across runs by time since
that run's first sample; each backtrace counts outermost frame first, so callers come before callees. Every
sampled address maps to the linker symbol that contains it (nm on the dSYM or unstripped binary), and the
list keeps them in order of first appearance. Release passes Telegram.order with ORDER_FILE; a symbol the
linker cannot find is ignored, so a stale list never breaks the build.

Check a Release build (exit 1 unless at least 90% of the listed functions found lead __text, in list order):
    python3 tools/dev/orderfile.py --check <archive>/dSYMs/Nanogram.app.dSYM/Contents/Resources/DWARF/Nanogram
    (or --check <link map> from a link with LD_GENERATE_MAP_FILE=YES)
"""
import argparse
import bisect
import collections
import ctypes
import mmap
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ORDER_DIR = os.path.join(ROOT, 'Telegram-Mac', 'OrderFiles')
ORDER_FILE = 'Telegram.order'
SIGNED_IN = 'signed-in.order'
SIGNED_OUT = 'signed-out.order'
ISOLATE_SOURCE = os.path.join(ROOT, 'tools', 'dev', 'orderfile-isolate.m')
TRACE_EXECUTABLE = 'NanogramLaunchTrace'
TRACE_BUNDLE_ID = 'org.klaipher.Nanogram.launchtrace'
NM_TEXT_LINE = re.compile(r'^([0-9a-f]+) \(__TEXT,__text\) (.*)$')
NM_ATTRIBUTES = re.compile(r'^(\[[^\]]*\] |weak |private |non-external |external |\(was a private external\) )+')
MS_INVALIDATE = 0x2
SAMPLE_SCHEMAS = ('time-profile', 'context-switch-sample')
LINK_MAP_SECTION = re.compile(r'^0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)\s+(\S+)\s+(\S+)\s*$')
LINK_MAP_SYMBOL = re.compile(r'^0x([0-9A-Fa-f]+)\s+0x[0-9A-Fa-f]+\s+\[\s*\d+\]\s(.*)$')
LAID_OUT = 0.9

Frame = collections.namedtuple('Frame', 'name addr uuid load_addr')


def run(args, **kwargs):
    return subprocess.run(args, check=False, capture_output=True, text=True, **kwargs)


def parse_time_profile(xml_path):
    """[(sample time ns, [Frame, leaf first])] from an exported time-profile table."""
    if not os.path.exists(xml_path) or os.path.getsize(xml_path) == 0:
        return []
    root = ET.parse(xml_path).getroot()
    ids = {el.get('id'): el for el in root.iter() if el.get('id') is not None}

    def resolve(el):
        ref = el.get('ref')
        return ids[ref] if ref is not None else el

    samples = []
    for row in root.iter('row'):
        sample_time, frames = None, []
        for column in row:
            column = resolve(column)
            if column.tag in ('sample-time', 'event-time'):
                sample_time = int(column.text)
            elif column.tag in ('backtrace', 'tagged-backtrace'):
                for frame in column:
                    frame = resolve(frame)
                    if frame.tag != 'frame':
                        continue
                    binary = next((resolve(child) for child in frame if child.tag == 'binary'), None)
                    addr = frame.get('addr')
                    load_addr = binary.get('load-addr') if binary is not None else None
                    frames.append(Frame(frame.get('name') or '', int(addr, 16) if addr else None,
                                        binary.get('UUID') if binary is not None else None,
                                        int(load_addr, 16) if load_addr else None))
        if sample_time is not None:
            samples.append((sample_time, frames))
    return samples


def binary_offsets(samples, uuid):
    """[(time since the binary's first sample, [offsets into the binary, outermost first])]."""
    uuid = uuid.upper()
    rows = []
    for sample_time, frames in samples:
        offsets = [f.addr - f.load_addr for f in reversed(frames)
                   if f.uuid and f.uuid.upper() == uuid and f.addr is not None and f.load_addr is not None]
        if offsets:
            rows.append((sample_time, offsets))
    if not rows:
        return []
    start = min(sample_time for sample_time, _ in rows)
    return [(sample_time - start, offsets) for sample_time, offsets in rows]


def first_seen_offsets(runs):
    """Offsets in order of first appearance, merging runs by time since each run's start."""
    merged = sorted((row for rows in runs for row in rows), key=lambda row: row[0])
    seen = collections.OrderedDict()
    for _, offsets in merged:
        for offset in offsets:
            seen.setdefault(offset, None)
    return list(seen)


def parse_nm(lines):
    """Sorted [(address, [names])] of the __TEXT,__text symbols in `nm -m -n -U` output."""
    by_address = collections.OrderedDict()
    for line in lines:
        match = NM_TEXT_LINE.match(line)
        if not match:
            continue
        name = NM_ATTRIBUTES.sub('', match.group(2))
        if name.startswith('__mh_'):
            continue
        by_address.setdefault(int(match.group(1), 16), []).append(name)
    return sorted(by_address.items())


def parse_link_map(lines):
    """Sorted [(address, [names])] of the __TEXT,__text symbols in an ld link map (LD_GENERATE_MAP_FILE=YES)."""
    text, section, by_address = None, None, collections.OrderedDict()
    for line in lines:
        if line.startswith('# ') and line.rstrip().endswith(':'):
            section = line[2:].rstrip().rstrip(':')
            continue
        if section == 'Sections':
            match = LINK_MAP_SECTION.match(line)
            if match and match.group(3, 4) == ('__TEXT', '__text'):
                start = int(match.group(1), 16)
                text = (start, start + int(match.group(2), 16))
        elif section == 'Symbols' and text:
            match = LINK_MAP_SYMBOL.match(line)
            if match and text[0] <= int(match.group(1), 16) < text[1]:
                by_address.setdefault(int(match.group(1), 16), []).append(match.group(2))
    return sorted(by_address.items())


def ambiguous_names(entries):
    """Names the linker would place at several addresses (per-module helpers, outlined functions): a list entry
    for one moves every copy and says nothing about which one launch ran, so lists must not hold them."""
    seen = collections.Counter(name for _, names in entries for name in set(names))
    return {name for name, count in seen.items() if count > 1 or name.startswith('_OUTLINED_FUNCTION_')}


def prune_ambiguous(order, entries):
    ambiguous = ambiguous_names(entries)
    return [name for name in order if name not in ambiguous]


def layout_report(entries, order):
    """How the listed functions sit in __text: (listed, found, leading, in_order, functions).

    found: listed functions the binary has (aliases at one address count once, at their first mention); leading:
    how many of them are among the first `found` functions of __text; in_order: how many follow the previous one."""
    ambiguous = ambiguous_names(entries)
    address_of = {name: address for address, names in entries for name in names if name not in ambiguous}
    addresses = list(collections.OrderedDict.fromkeys(address_of[n] for n in order if n in address_of))
    first = {address for address, _ in entries[:len(addresses)]}
    leading = sum(1 for address in addresses if address in first)
    in_order = sum(1 for a, b in zip(addresses, addresses[1:]) if b > a) + (1 if addresses else 0)
    return len(order), len(addresses), leading, in_order, len(entries)


def check_layout(path, order_path):
    with open(path, errors='replace') as f:
        is_link_map = f.readline().startswith('# Path:')
    if is_link_map:
        with open(path, errors='replace') as f:
            entries = parse_link_map(f)
    else:
        entries = parse_nm(run(['nm', '-m', '-n', '-U', path]).stdout.split('\n'))
    listed, found, leading, in_order, functions = layout_report(entries, read_lines(order_path))
    print(f'{order_path}: {listed} symbols, {found} functions in {path} (of {functions} in __text)')
    print(f'leading __text: {leading} of {found}; in list order: {in_order} of {found}')
    ok = found > 0 and leading >= LAID_OUT * found and in_order >= LAID_OUT * found
    print('laid out by the order file' if ok else 'NOT laid out by the order file')
    return ok


class SymbolTable:
    def __init__(self, entries, text_vmaddr):
        self.addresses = [address for address, _ in entries]
        self.names = [names for _, names in entries]
        self.text_vmaddr = text_vmaddr

    def names_at(self, offset):
        index = bisect.bisect_right(self.addresses, self.text_vmaddr + offset) - 1
        return self.names[index] if index >= 0 else []


def text_vmaddr_of(binary):
    lines = run(['otool', '-l', binary]).stdout.split('\n')
    for i, line in enumerate(lines):
        if line.strip() == 'segname __TEXT':
            return int(lines[i + 1].split()[1], 16)
    sys.exit(f'{binary}: no __TEXT segment')


def uuid_of(binary):
    match = re.search(r'UUID: ([0-9A-F-]+)', run(['dwarfdump', '--uuid', binary]).stdout)
    if not match:
        sys.exit(f'{binary}: no UUID')
    return match.group(1)


def load_symbols(binary):
    entries = parse_nm(run(['nm', '-m', '-n', '-U', binary]).stdout.split('\n'))
    if len(entries) < 1000:
        sys.exit(f'{binary} has {len(entries)} function symbols; pass the dSYM or an unstripped binary')
    return SymbolTable(entries, text_vmaddr_of(binary))


def order_symbols(offsets, table, known=(), ambiguous=()):
    known = set(known) | set(ambiguous)
    symbols = collections.OrderedDict()
    for offset in offsets:
        for name in table.names_at(offset):
            if name not in known:
                symbols.setdefault(name, None)
    return list(symbols)


def executable_name_of(app):
    with open(os.path.join(app, 'Contents', 'Info.plist'), 'rb') as f:
        return plistlib.load(f)['CFBundleExecutable']


def archive_paths(archive):
    apps = [name for name in os.listdir(os.path.join(archive, 'Products', 'Applications')) if name.endswith('.app')]
    if len(apps) != 1:
        sys.exit(f'{archive}: expected one app, found {apps}')
    app = os.path.join(archive, 'Products', 'Applications', apps[0])
    dsym = os.path.join(archive, 'dSYMs', f'{apps[0]}.dSYM', 'Contents', 'Resources', 'DWARF', executable_name_of(app))
    return app, dsym


def default_symbols(app):
    macos = os.path.join(app, 'Contents', 'MacOS')
    debug_dylib = os.path.join(macos, executable_name_of(app) + '.debug.dylib')
    return debug_dylib if os.path.exists(debug_dylib) else os.path.join(macos, executable_name_of(app))


def isolated_copy(app, directory):
    copy = os.path.join(directory, f'{TRACE_EXECUTABLE}.app')
    subprocess.run(['cp', '-Rc', app, copy], check=True)
    shutil.rmtree(os.path.join(copy, 'Contents', 'PlugIns'), ignore_errors=True)
    macos = os.path.join(copy, 'Contents', 'MacOS')
    os.rename(os.path.join(macos, executable_name_of(app)), os.path.join(macos, TRACE_EXECUTABLE))
    info_path = os.path.join(copy, 'Contents', 'Info.plist')
    with open(info_path, 'rb') as f:
        info = plistlib.load(f)
    info['CFBundleExecutable'] = TRACE_EXECUTABLE
    info['CFBundleIdentifier'] = TRACE_BUNDLE_ID
    with open(info_path, 'wb') as f:
        plistlib.dump(info, f)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', copy], check=True, capture_output=True)
    return os.path.join(macos, TRACE_EXECUTABLE)


def build_isolation(directory):
    dylib = os.path.join(directory, 'isolate.dylib')
    subprocess.run(['clang', '-arch', 'arm64', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    '-o', dylib, ISOLATE_SOURCE], check=True)
    return dylib


def evict_from_page_cache(path):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.restype = ctypes.c_void_p
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
    libc.msync.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    fd = os.open(path, os.O_RDONLY)
    try:
        size = os.fstat(fd).st_size
        address = libc.mmap(None, size, mmap.PROT_READ, mmap.MAP_SHARED, fd, 0)
        if address in (None, ctypes.c_void_p(-1).value):
            return False
        evicted = libc.msync(address, size, MS_INVALIDATE) == 0
        libc.munmap(address, size)
        return evicted
    finally:
        os.close(fd)


def ensure_free_space(path, minimum_gb):
    free_gb = shutil.disk_usage(path).free / 1e9
    if free_gb < minimum_gb:
        sys.exit(f'{free_gb:.1f} GB free: a trace writes up to 3 GB, so no run starts below {minimum_gb:g} GB '
                 f'(--min-free-gb); free space and run it again')


def ktrace_files():
    directory = run(['getconf', 'DARWIN_USER_TEMP_DIR']).stdout.strip() or tempfile.gettempdir()
    return {os.path.join(directory, name) for name in os.listdir(directory)
            if name.startswith('instruments') and name.endswith('.ktrace')}


def remove_ktrace_files_left_since(before):
    for path in ktrace_files() - before:
        if not run(['lsof', path]).stdout.strip():
            os.remove(path)


def export_samples(trace_path, xml_prefix):
    samples = []
    for schema in SAMPLE_SCHEMAS:
        xml_path = f'{xml_prefix}-{schema}.xml'
        with open(xml_path, 'w') as out:
            subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace_path, '--xpath',
                            f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                           stdout=out, stderr=subprocess.DEVNULL, check=False)
        samples.extend(parse_time_profile(xml_path))
        os.remove(xml_path)
    shutil.rmtree(trace_path, ignore_errors=True)
    return samples


def stop_processes_at(executable):
    for pid in run(['pgrep', '-f', '-x', executable]).stdout.split():
        os.kill(int(pid), signal.SIGTERM)
    deadline = time.time() + 5
    while time.time() < deadline and run(['pgrep', '-f', '-x', executable]).stdout.strip():
        time.sleep(0.2)
    for pid in run(['pgrep', '-f', '-x', executable]).stdout.split():
        os.kill(int(pid), signal.SIGKILL)


def record_isolated_launch(executable, dylib, home, tmp, name, seconds):
    evict_from_page_cache(executable)
    trace_path = os.path.join(tmp, f'{name}.trace')
    before = ktrace_files()
    try:
        run(['xcrun', 'xctrace', 'record', '--template', 'App Launch', '--time-limit', f'{seconds}s', '--no-prompt',
             '--output', trace_path,
             '--env', f'DYLD_INSERT_LIBRARIES={dylib}',
             '--env', f'NANOGRAM_CONTAINER_ROOT={os.path.join(home, "GroupContainers")}',
             '--env', f'CFFIXED_USER_HOME={home}',
             '--launch', '--', executable])
        stop_processes_at(executable)
        return export_samples(trace_path, os.path.join(tmp, name))
    finally:
        remove_ktrace_files_left_since(before)


def quit_app(executable, timeout=15):
    """Ask the app to quit like Cmd-Q (by pid, so nothing is launched), then stop what is left."""
    for pid in run(['pgrep', '-f', '-x', executable]).stdout.split():
        run(['osascript', '-l', 'JavaScript', '-e',
             f'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}).terminate'])
    deadline = time.time() + timeout
    while time.time() < deadline and run(['pgrep', '-f', '-x', executable]).stdout.strip():
        time.sleep(0.5)
    stop_processes_at(executable)


def record_signed_in_launch(executable, tmp, name, seconds):
    evict_from_page_cache(executable)
    trace_path = os.path.join(tmp, f'{name}.trace')
    before = ktrace_files()
    try:
        run(['xcrun', 'xctrace', 'record', '--template', 'App Launch', '--time-limit', f'{seconds}s', '--no-prompt',
             '--output', trace_path, '--launch', '--', executable])
        quit_app(executable)
        return export_samples(trace_path, os.path.join(tmp, name))
    finally:
        remove_ktrace_files_left_since(before)


def write_lines(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]


def compose(signed_in, signed_out):
    """The linked list: signed-in launch order first, then the symbols only the login screen runs."""
    listed = set(signed_in)
    return list(signed_in) + [symbol for symbol in signed_out if symbol not in listed]


def write_order_files(directory, source, symbols):
    write_lines(os.path.join(directory, source), symbols)
    signed_in = read_lines(os.path.join(directory, SIGNED_IN))
    signed_out = read_lines(os.path.join(directory, SIGNED_OUT))
    linked = compose(signed_in, signed_out)
    write_lines(os.path.join(directory, ORDER_FILE), linked)
    return len(signed_in), len(linked) - len(signed_in)


def resolve_inputs(archive, app, symbols):
    """(app, symbols): the archive's app and dSYM, or --app traced with the archive's dSYM or --symbols."""
    archived_app, dsym = archive_paths(archive) if archive else (None, None)
    app = os.path.abspath(app or archived_app or '')
    if not app.endswith('.app') or not os.path.isdir(app):
        sys.exit('pass --archive or --app')
    return app, symbols or dsym or default_symbols(app)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--archive', help='Release .xcarchive: its dSYM gives the symbols (and its app is traced '
                                          'unless --app is given)')
    parser.add_argument('--app', help='app to trace instead of the archive\'s (the installed release for --signed-in)')
    parser.add_argument('--symbols', help='dSYM DWARF file or unstripped binary of the traced code')
    parser.add_argument('--signed-in', action='store_true', help='launch the installed app with your signed-in data')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--seconds', type=int)
    parser.add_argument('--min-free-gb', type=float, default=18)
    parser.add_argument('--out-dir', default=ORDER_DIR)
    parser.add_argument('--check', metavar='DSYM_OR_LINK_MAP',
                        help='only check that a Release link put the listed functions first in __text, in list order')
    parser.add_argument('--prune', metavar='DSYM_OR_BINARY',
                        help='drop names that are not unique in this binary from the lists in --out-dir')
    parser.add_argument('--order', default=os.path.join(ORDER_DIR, ORDER_FILE), help='list to --check')
    args = parser.parse_args()
    if args.prune:
        entries = parse_nm(run(['nm', '-m', '-n', '-U', args.prune]).stdout.split('\n'))
        for name in (SIGNED_IN, SIGNED_OUT, ORDER_FILE):
            path = os.path.join(args.out_dir, name)
            before = read_lines(path)
            if before:
                write_lines(path, prune_ambiguous(before, entries))
                print(f'{path}: {len(before)} -> {len(read_lines(path))} symbols')
        return
    if args.check:
        sys.exit(0 if check_layout(args.check, args.order) else 1)

    app, symbols = resolve_inputs(args.archive, args.app, args.symbols)
    uuid = uuid_of(symbols)
    table = load_symbols(symbols)
    executable = os.path.join(app, 'Contents', 'MacOS', executable_name_of(app))
    if uuid_of(executable) != uuid:
        sys.exit(f'{executable} ({uuid_of(executable)}) is not the build of {symbols} ({uuid}); '
                 'pass the archive the app came from')

    runs = []
    with tempfile.TemporaryDirectory(prefix='nanogram-orderfile-') as tmp:
        tmp = os.path.realpath(tmp)
        if args.signed_in:
            if run(['pgrep', '-f', '-x', executable]).stdout.strip():
                sys.exit(f'{app} is running; quit it first')
            record = lambda i: record_signed_in_launch(executable, tmp, f'launch{i}', args.seconds or 8)
        else:
            dylib = build_isolation(tmp)
            executable = isolated_copy(app, tmp)

            def record(i):
                home = os.path.join(tmp, f'home{i}')
                os.makedirs(home)
                return record_isolated_launch(executable, dylib, home, tmp, f'launch{i}', args.seconds or 5)
        try:
            for i in range(args.runs):
                ensure_free_space(tmp, args.min_free_gb)
                runs.append(binary_offsets(record(i), uuid))
                print(f'launch {i + 1}: {len(runs[-1])} samples in the app', flush=True)
        finally:
            (quit_app if args.signed_in else stop_processes_at)(executable)

    offsets = first_seen_offsets(runs)
    source = SIGNED_IN if args.signed_in else SIGNED_OUT
    symbols_out = order_symbols(offsets, table, ambiguous=ambiguous_names(zip(table.addresses, table.names)))
    signed_in, login_only = write_order_files(args.out_dir, source, symbols_out)
    print(f'{os.path.join(args.out_dir, source)}: {len(symbols_out)} symbols from '
          f'{len(offsets)} sampled addresses in {len(runs)} launches')
    print(f'{os.path.join(args.out_dir, ORDER_FILE)}: {signed_in} signed-in + {login_only} login-only symbols')


if __name__ == '__main__':
    main()
