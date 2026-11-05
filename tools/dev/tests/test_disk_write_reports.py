"""The Mac reads the shared Postbox write counters like the iOS app does (parity lane, 2026-11-05).

Source-text checks only (nothing is compiled): the ledger file name agrees between the runtime package and the
MetricKit export, and the app delegate starts the reporter and reports on focus changes.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from nanogram import config  # noqa: E402

ROOT = config.ROOT


def read(relative: str) -> str:
    return (ROOT / relative).read_text(errors="replace")


class DiskWriteReportsWiringTests(unittest.TestCase):
    def test_ledger_name_matches_between_runtime_and_export(self):
        runtime = read("packages/NanogramRuntime/Sources/NanogramRuntime/DiskWriteReports.swift")
        export = read("packages/NanogramDebug/Sources/NanogramLogExport/NanogramLogExportSpec.swift")
        self.assertEqual(re.search(r'ledgerFileName = "([^"]+)"', runtime).group(1), "disk-writes.json")
        self.assertEqual(re.search(r'diskWriteLedgerFileName = "([^"]+)"', export).group(1), "disk-writes.json")

    def test_runtime_package_depends_on_the_core_accounting_module(self):
        manifest = read("packages/NanogramRuntime/Package.swift")
        self.assertIn('path: "../../submodules/telegram-ios/submodules/DiskWriteAccounting"', manifest)
        self.assertEqual(manifest.count('.product(name: "DiskWriteAccounting"'), 2)

    def test_app_delegate_starts_and_reports_on_focus_changes(self):
        delegate = read("Telegram-Mac/app/AppDelegate.swift")
        self.assertIn("DiskWriteReports(ledgerPath: DiskWriteReportSchedule.ledgerPath(containerPath: containerPath)", delegate)
        self.assertIn("reports.start()", delegate)
        self.assertIn('self.diskWriteReports?.report(reason: "foreground")', delegate)
        self.assertIn('self.diskWriteReports?.report(reason: "background")', delegate)
        # After the crash recovery, which can wipe the container and the ledger with it.
        self.assertLess(delegate.index("recoverFromCrashOnLaunchIfNeeded(containerPath: containerUrl.path)"),
                        delegate.index("startDiskWriteReports(containerPath: containerUrl.path)"))

    def test_metrickit_export_collects_the_ledger(self):
        hooks = read("Telegram-Mac/packages-integration/hooks/NanogramLogExportHooksInstall.swift")
        self.assertIn("ledgerSources(logsDirectory:", hooks)


if __name__ == "__main__":
    unittest.main()
