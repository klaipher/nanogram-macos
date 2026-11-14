"""Imports the parity gate from the shared/ submodule of the core (submodules/telegram-ios/shared/parity.py): one copy for iOS, Mac and Android."""
import importlib.util
from pathlib import Path

_PATH = Path(__file__).resolve().parents[3] / "submodules" / "telegram-ios" / "shared" / "parity.py"
if not _PATH.is_file():
    raise SystemExit(f"parity: {_PATH} is missing; check out the core (submodules/telegram-ios) with its shared/ submodule")
_spec = importlib.util.spec_from_file_location("nanogram_parity", _PATH)
parity = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(parity)
