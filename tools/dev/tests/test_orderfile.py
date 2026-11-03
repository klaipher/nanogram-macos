import importlib.util
import os
import plistlib
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location('orderfile', os.path.join(HERE, '..', 'orderfile.py'))
orderfile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(orderfile)


class OrderFileTests(unittest.TestCase):
    def test_samples_resolve_refs_and_binaries(self):
        samples = orderfile.parse_time_profile(os.path.join(HERE, 'fixtures', 'time-profile.xml'))
        self.assertEqual(len(samples), 3)
        by_time = dict(samples)
        self.assertEqual(by_time[1000000][0], ('Postbox.init()', 'Telegram'))
        self.assertEqual(by_time[1000000][1], ('main', 'Telegram'))
        self.assertEqual(by_time[3000000][0], ('objc_msgSend', 'libobjc.A.dylib'))

    def test_first_seen_is_in_time_order_outermost_first_and_only_the_app_binary(self):
        samples = orderfile.parse_time_profile(os.path.join(HERE, 'fixtures', 'time-profile.xml'))
        names = orderfile.first_seen_functions(samples, 'Telegram')
        self.assertEqual(names, ['main', 'Postbox.init()', 'AppDelegate.applicationDidFinishLaunching(_:)'])

    def test_order_maps_to_linker_symbols_dedups_and_counts_misses(self):
        mapping = {
            'main': ['_main'],
            'Postbox.init()': ['_$s7Postbox0A0CACycfc', '_$s7Postbox0A0CACycfC'],
            'AppDelegate.applicationDidFinishLaunching(_:)': ['_$s8Telegram11AppDelegateC'],
        }
        symbols, missed = orderfile.order_symbols(['main', 'Postbox.init()', 'unknown()', 'main'], mapping)
        self.assertEqual(symbols, ['_main', '_$s7Postbox0A0CACycfc', '_$s7Postbox0A0CACycfC'])
        self.assertEqual(missed, 1)

    def test_symbol_keys_cover_raw_unprefixed_and_demangled_names(self):
        mapping = orderfile.build_symbol_map(['_main', '_$sFoo'], ['main', 'Foo.full()'], ['main', 'Foo()'])
        self.assertEqual(mapping['main'], ['_main'])
        self.assertEqual(mapping['Foo()'], ['_$sFoo'])
        self.assertEqual(mapping['Foo.full()'], ['_$sFoo'])
        self.assertEqual(mapping['$sFoo'], ['_$sFoo'])

    def test_executable_name_comes_from_the_app_info_plist(self):
        with tempfile.TemporaryDirectory() as app:
            os.makedirs(os.path.join(app, 'Contents'))
            with open(os.path.join(app, 'Contents', 'Info.plist'), 'wb') as f:
                plistlib.dump({'CFBundleExecutable': 'Nanogram'}, f)
            self.assertEqual(orderfile.executable_name_of(app), 'Nanogram')


if __name__ == '__main__':
    unittest.main()
