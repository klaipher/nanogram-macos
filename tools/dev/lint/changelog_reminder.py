"""Thin wrapper: the pre-push changelog reminder lives in the shared tools (klaipher/nanogram-deps), one copy for iOS, Mac and Android.

The Mac reaches it through the core: submodules/telegram-ios/shared/tools/changelog_reminder.py. tglint imports this
module by its old name. Without the core checked out the reminder is skipped (it only prints a note).
"""
import importlib.util
import os

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..',
                     'submodules', 'telegram-ios', 'shared', 'tools', 'changelog_reminder.py')

if os.path.isfile(_PATH):
    _spec = importlib.util.spec_from_file_location('nanogram_shared_changelog_reminder', _PATH)
    _module = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_module)
    globals().update({name: value for name, value in vars(_module).items() if not name.startswith('__')})
else:
    def reminder(paths):
        return None
