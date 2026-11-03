#!/usr/bin/env python3
"""Generate a launch order file for the Telegram for macOS executable.

Usage (build the app first; the login screen is enough, no account is needed):
    python3 tools/dev/orderfile.py --app <path/to/Telegram.app> [--runs 3] [--out Telegram-Mac/OrderFiles/Telegram.order]

What it does:
1. Records --runs launches with the Instruments "App Launch" template (xctrace, 1 ms samples).
2. Collects every function of the app executable seen in the samples, in order of first
   appearance (outermost frame first, so callers come before callees). The packages are static,
   so TelegramCore, Postbox and all packages live in this one executable.
3. Maps the profiler's simplified names back to linker symbols with nm + swift-demangle.
   Overloads that share a simplified name are all listed; that is harmless.
4. Writes the order file. Release passes it with ORDER_FILE; a symbol the linker cannot find is
   ignored, so a stale list never breaks the build.

For a real cold launch run `sudo purge` before each run (the script does not do it).
Check the layout with LD_GENERATE_MAP_FILE=YES: the listed functions should sit together at the
start of __TEXT,__text.
"""
import argparse
import collections
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_OUT = os.path.join(ROOT, 'Telegram-Mac', 'OrderFiles', 'Telegram.order')
MAX_CANDIDATES = 4


def run(args, **kwargs):
    return subprocess.run(args, check=False, capture_output=True, text=True, **kwargs)


def parse_time_profile(xml_path):
    if not os.path.exists(xml_path) or os.path.getsize(xml_path) == 0:
        return []
    root = ET.parse(xml_path).getroot()
    ids = {el.get('id'): el for el in root.iter() if el.get('id') is not None}

    def resolve(el):
        ref = el.get('ref')
        return ids[ref] if ref is not None else el

    samples = []
    for row in root.iter('row'):
        time, frames = None, []
        for column in row:
            column = resolve(column)
            if column.tag == 'sample-time':
                time = int(column.text)
            elif column.tag in ('backtrace', 'tagged-backtrace'):
                for frame in column:
                    frame = resolve(frame)
                    if frame.tag != 'frame':
                        continue
                    binary = None
                    for child in frame:
                        child = resolve(child)
                        if child.tag == 'binary':
                            binary = child.get('name')
                    frames.append((frame.get('name') or '', binary or ''))
        if time is not None:
            samples.append((time, frames))
    return samples


def first_seen_functions(samples, binary_name):
    seen = collections.OrderedDict()
    for _, frames in sorted(samples, key=lambda sample: sample[0]):
        for name, binary in reversed(frames):
            if binary == binary_name and name:
                seen.setdefault(name, None)
    return list(seen)


def build_symbol_map(names, demangled, simplified):
    mapping = collections.defaultdict(list)
    for name, full, short in zip(names, demangled, simplified):
        keys = [name, full, short, name[1:] if name.startswith('_') else None]
        for key in dict.fromkeys(k for k in keys if k):
            mapping[key].append(name)
    return mapping


def symbol_map(binary_path):
    names = sorted(set(n for n in run(['nm', '-j', '-U', binary_path]).stdout.split('\n') if n))
    joined = '\n'.join(names) + '\n'
    full = run(['xcrun', 'swift-demangle'], input=joined).stdout.split('\n')
    simplified = run(['xcrun', 'swift-demangle', '--simplified'], input=joined).stdout.split('\n')
    return build_symbol_map(names, full, simplified)


def order_symbols(functions, mapping):
    symbols, missed = [], 0
    for name in functions:
        candidates = mapping.get(name)
        if candidates:
            symbols.extend(candidates[:MAX_CANDIDATES])
        else:
            missed += 1
    return list(dict.fromkeys(symbols)), missed


def record_launch(executable, trace_path, xml_path, seconds):
    run(['xcrun', 'xctrace', 'record', '--template', 'App Launch', '--time-limit', f'{seconds}s',
         '--output', trace_path, '--launch', '--', executable])
    with open(xml_path, 'w') as out:
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace_path, '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                       stdout=out, stderr=subprocess.DEVNULL, check=False)
    return parse_time_profile(xml_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, help='path to Telegram.app')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--seconds', type=int, default=8)
    parser.add_argument('--out', default=DEFAULT_OUT)
    args = parser.parse_args()

    executable_name = 'Telegram'
    executable = os.path.join(args.app, 'Contents', 'MacOS', executable_name)
    if not os.path.exists(executable):
        sys.exit(f'{executable} does not exist')

    samples = []
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(args.runs):
            run(['pkill', '-x', executable_name])
            launch = record_launch(executable, os.path.join(tmp, f'launch{i}.trace'),
                                   os.path.join(tmp, f'launch{i}.xml'), args.seconds)
            print(f'launch {i + 1}: {len(launch)} samples')
            offset = i * 10 ** 12
            samples.extend((time + offset, frames) for time, frames in launch)
        run(['pkill', '-x', executable_name])

    functions = first_seen_functions(samples, executable_name)
    symbols, missed = order_symbols(functions, symbol_map(executable))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w') as f:
        f.write('\n'.join(symbols) + '\n')
    print(f'{args.out}: {len(symbols)} symbols ({missed} of {len(functions)} profiled names not found)')


if __name__ == '__main__':
    main()
