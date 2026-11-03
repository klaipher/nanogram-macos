from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = (root / 'packages/TelegramMedia/Sources/HLSCodecSelection.swift').read_text()
fixture = Path(__file__).with_name('CodecTests.swift').read_text().replace('__SOURCE__', source)
with tempfile.TemporaryDirectory(prefix='hls-av1-codec-') as directory:
    directory = Path(directory)
    (directory / 'main.swift').write_text(fixture)
    binary = directory / 'tests'
    subprocess.run(['swiftc', '-module-cache-path', str(Path(tempfile.gettempdir()) / 'hls-av1-codec-module-cache'), str(directory / 'main.swift'), '-o', str(binary)], check=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)
