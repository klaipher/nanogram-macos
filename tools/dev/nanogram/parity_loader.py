"""Imports tools/dev/parity/parity.py, which is identical in the iOS and macOS repos and so lives outside the package."""
import importlib.util
from pathlib import Path

_PATH = Path(__file__).resolve().parents[1] / "parity" / "parity.py"
_spec = importlib.util.spec_from_file_location("nanogram_parity", _PATH)
parity = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(parity)
