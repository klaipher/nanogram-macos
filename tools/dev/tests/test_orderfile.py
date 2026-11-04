import importlib.util
import os
import plistlib
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location('orderfile', os.path.join(HERE, '..', 'orderfile.py'))
orderfile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(orderfile)

FIXTURE = os.path.join(HERE, 'fixtures', 'time-profile.xml')
APP_UUID = 'AAAA0000-0000-0000-0000-000000000001'
NM_OUTPUT = """\
0000000100000000 (__TEXT,__text) [referenced dynamically] external __mh_execute_header
0000000100000100 (__TEXT,__text) external _main
0000000100000180 (__TEXT,__text) non-external _$s7Postbox0A0CACycfc
0000000100000200 (__TEXT,__text) weak external _$s8Telegram11AppDelegateC4doneyyF
0000000100000200 (__TEXT,__text) weak private external _$s8Telegram11AppDelegateC4doneyyFTm
0000000100000280 (__TEXT,__text) non-external (was a private external) -[MMMenuItem initWithCoder:]
0000000100900000 (__DATA,__data) non-external _someData
"""


class ParseTests(unittest.TestCase):
    def test_samples_resolve_refs_addresses_binaries_and_both_time_columns(self):
        samples = dict(orderfile.parse_time_profile(FIXTURE))
        self.assertEqual(sorted(samples), [5000000, 10000000, 12000000, 15000000])
        self.assertEqual(samples[10000000][0], orderfile.Frame('Postbox.init()', 0x104000181, APP_UUID, 0x104000000))
        self.assertEqual(samples[10000000][1].name, 'main')
        self.assertEqual(samples[15000000][0].uuid, 'EEEE0000-0000-0000-0000-000000000003')

    def test_missing_or_empty_export_has_no_samples(self):
        with tempfile.NamedTemporaryFile(suffix='.xml') as empty:
            self.assertEqual(orderfile.parse_time_profile(empty.name), [])
        self.assertEqual(orderfile.parse_time_profile('/nonexistent.xml'), [])

    def test_offsets_keep_only_the_traced_binary_outermost_first_from_its_first_sample(self):
        rows = orderfile.binary_offsets(orderfile.parse_time_profile(FIXTURE), APP_UUID.lower())
        self.assertEqual(sorted(rows), [(0, [0x101, 0x181]), (2000000, [0x101, 0x201]), (5000000, [0x101, 0x201])])


class MergeTests(unittest.TestCase):
    def test_runs_merge_by_time_since_their_own_start(self):
        first = [(0, [1, 2]), (900, [7])]
        second = [(0, [1, 3]), (100, [4]), (950, [2])]
        self.assertEqual(orderfile.first_seen_offsets([first, second]), [1, 2, 3, 4, 7])


class SymbolTests(unittest.TestCase):
    def table(self):
        return orderfile.SymbolTable(orderfile.parse_nm(NM_OUTPUT.splitlines()), 0x100000000)

    def test_nm_keeps_text_names_with_aliases_and_objc_spaces(self):
        entries = dict(orderfile.parse_nm(NM_OUTPUT.splitlines()))
        self.assertEqual(sorted(entries), [0x100000100, 0x100000180, 0x100000200, 0x100000280])
        self.assertEqual(entries[0x100000200],
                         ['_$s8Telegram11AppDelegateC4doneyyF', '_$s8Telegram11AppDelegateC4doneyyFTm'])
        self.assertEqual(entries[0x100000280], ['-[MMMenuItem initWithCoder:]'])

    def test_an_offset_maps_to_the_symbol_that_contains_it(self):
        table = self.table()
        self.assertEqual(table.names_at(0x100), ['_main'])
        self.assertEqual(table.names_at(0x17f), ['_main'])
        self.assertEqual(table.names_at(0x181), ['_$s7Postbox0A0CACycfc'])
        self.assertEqual(table.names_at(0x10), [])

    def test_order_dedups_and_skips_symbols_already_in_the_file(self):
        table = self.table()
        symbols = orderfile.order_symbols([0x101, 0x181, 0x110, 0x201], table, known=['_$s7Postbox0A0CACycfc'])
        self.assertEqual(symbols, ['_main', '_$s8Telegram11AppDelegateC4doneyyF',
                                   '_$s8Telegram11AppDelegateC4doneyyFTm'])

    def test_the_fixture_trace_orders_callers_first_in_launch_order(self):
        rows = orderfile.binary_offsets(orderfile.parse_time_profile(FIXTURE), APP_UUID)
        symbols = orderfile.order_symbols(orderfile.first_seen_offsets([rows]), self.table())
        self.assertEqual(symbols, ['_main', '_$s7Postbox0A0CACycfc', '_$s8Telegram11AppDelegateC4doneyyF',
                                   '_$s8Telegram11AppDelegateC4doneyyFTm'])


LINK_MAP = """\
# Path: /tmp/Nanogram
# Arch: arm64
# Object files:
[  0] linker synthesized
[  1] /tmp/AppDelegate.o
# Sections:
# Address\tSize    \tSegment\tSection
0x100004000\t0x00000300\t__TEXT\t__text
0x100004300\t0x00000020\t__TEXT\t__stubs
# Symbols:
# Address\tSize    \tFile  Name
0x100004000\t0x00000080\t[  1] _main
0x100004080\t0x00000080\t[  1] -[MMMenuItem initWithCoder:]
0x100004100\t0x00000080\t[  1] _$s8Telegram11AppDelegateC4doneyyF
0x100004100\t0x00000080\t[  1] _$s8Telegram11AppDelegateC4doneyyFTm
0x100004180\t0x00000080\t[  1] _unlisted
0x100004300\t0x0000000C\t[  0] _objc_msgSend
# Dead Stripped Symbols:
<<dead>> \t0x00000018\t[  1] _gone
"""


class LayoutTests(unittest.TestCase):
    def test_link_map_keeps_text_symbols_with_aliases(self):
        self.assertEqual(orderfile.parse_link_map(LINK_MAP.split('\n')), [
            (0x100004000, ['_main']), (0x100004080, ['-[MMMenuItem initWithCoder:]']),
            (0x100004100, ['_$s8Telegram11AppDelegateC4doneyyF', '_$s8Telegram11AppDelegateC4doneyyFTm']),
            (0x100004180, ['_unlisted'])])

    def test_listed_functions_leading_text_in_list_order_are_laid_out(self):
        entries = orderfile.parse_link_map(LINK_MAP.split('\n'))
        order = ['_main', '-[MMMenuItem initWithCoder:]', '_$s8Telegram11AppDelegateC4doneyyFTm',
                 '_$s8Telegram11AppDelegateC4doneyyF', '_missing']
        self.assertEqual(orderfile.layout_report(entries, order), (5, 3, 3, 3, 4))

    def test_an_unordered_link_is_not_laid_out(self):
        entries = orderfile.parse_nm(NM_OUTPUT.split('\n'))
        order = ['-[MMMenuItem initWithCoder:]', '_$s8Telegram11AppDelegateC4doneyyF']
        self.assertEqual(orderfile.layout_report(entries, order), (2, 2, 0, 1, 4))
        with tempfile.TemporaryDirectory() as tmp:
            link_map, listed = os.path.join(tmp, 'map.txt'), os.path.join(tmp, 'Telegram.order')
            with open(link_map, 'w') as f:
                f.write(LINK_MAP)
            orderfile.write_lines(listed, ['_unlisted', '_main'])
            self.assertFalse(orderfile.check_layout(link_map, listed))
            orderfile.write_lines(listed, ['_main', '-[MMMenuItem initWithCoder:]'])
            self.assertTrue(orderfile.check_layout(link_map, listed))


class AmbiguousNameTests(unittest.TestCase):
    ENTRIES = [(0x100, ['_main']), (0x180, ['_OUTLINED_FUNCTION_3']), (0x200, ['_$sURLWOhTm']),
               (0x280, ['_$sURLWOhTm']), (0x300, ['_unique', '_alias'])]

    def test_names_at_several_addresses_and_outlined_functions_are_ambiguous(self):
        self.assertEqual(orderfile.ambiguous_names(self.ENTRIES), {'_OUTLINED_FUNCTION_3', '_$sURLWOhTm'})

    def test_order_skips_ambiguous_names(self):
        table = orderfile.SymbolTable(self.ENTRIES, 0)
        self.assertEqual(orderfile.order_symbols([0x100, 0x180, 0x200, 0x300], table, ambiguous=orderfile.ambiguous_names(self.ENTRIES)),
                         ['_main', '_unique', '_alias'])

    def test_prune_keeps_unique_and_non_text_names(self):
        self.assertEqual(orderfile.prune_ambiguous(['_main', '_OUTLINED_FUNCTION_3', '_$sURLWOhTm', '_data', '_unique'], self.ENTRIES),
                         ['_main', '_data', '_unique'])

    def test_check_ignores_ambiguous_names_instead_of_picking_one_copy(self):
        order = ['_main', '_$sURLWOhTm', '_unique']
        entries = [(0x100, ['_main']), (0x180, ['_unique']), (0x200, ['_$sURLWOhTm']), (0x280, ['_$sURLWOhTm']), (0x300, ['_x'])]
        self.assertEqual(orderfile.layout_report(entries, order), (3, 2, 2, 2, 5))


class OrderFilesTests(unittest.TestCase):
    def test_signed_in_order_comes_first_then_login_only_symbols(self):
        self.assertEqual(orderfile.compose(['_main', '_b', '_c'], ['_main', '_login', '_c', '_form']),
                         ['_main', '_b', '_c', '_login', '_form'])
        self.assertEqual(orderfile.compose([], ['_main', '_login']), ['_main', '_login'])

    def test_each_source_keeps_its_own_file_and_the_linked_file_is_recomposed(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(orderfile.write_order_files(tmp, orderfile.SIGNED_OUT, ['_main', '_login']), (0, 2))
            self.assertEqual(orderfile.write_order_files(tmp, orderfile.SIGNED_IN, ['_main', '_chats']), (2, 1))
            self.assertEqual(orderfile.read_lines(os.path.join(tmp, orderfile.ORDER_FILE)),
                             ['_main', '_chats', '_login'])
            self.assertEqual(orderfile.write_order_files(tmp, orderfile.SIGNED_OUT, ['_login2']), (2, 1))
            self.assertEqual(orderfile.read_lines(os.path.join(tmp, orderfile.SIGNED_IN)), ['_main', '_chats'])
            self.assertEqual(orderfile.read_lines(os.path.join(tmp, orderfile.ORDER_FILE)),
                             ['_main', '_chats', '_login2'])

    def test_the_linked_file_is_the_one_release_passes(self):
        self.assertEqual(os.path.join(orderfile.ORDER_DIR, orderfile.ORDER_FILE),
                         os.path.join(orderfile.ROOT, 'Telegram-Mac', 'OrderFiles', 'Telegram.order'))


class BundleTests(unittest.TestCase):
    def make_app(self, directory, executable='Nanogram'):
        app = os.path.join(directory, f'{executable}.app')
        os.makedirs(os.path.join(app, 'Contents', 'MacOS'))
        with open(os.path.join(app, 'Contents', 'Info.plist'), 'wb') as f:
            plistlib.dump({'CFBundleExecutable': executable}, f)
        return app

    def test_executable_name_comes_from_the_app_info_plist(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(orderfile.executable_name_of(self.make_app(tmp)), 'Nanogram')

    def test_archive_gives_its_app_and_the_apps_dsym(self):
        with tempfile.TemporaryDirectory() as archive:
            app = self.make_app(os.path.join(archive, 'Products', 'Applications'))
            self.assertEqual(orderfile.archive_paths(archive), (app, os.path.join(
                archive, 'dSYMs', 'Nanogram.app.dSYM', 'Contents', 'Resources', 'DWARF', 'Nanogram')))

    def test_an_installed_app_is_traced_with_the_archives_dsym(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = os.path.join(tmp, 'Nanogram.xcarchive')
            self.make_app(os.path.join(archive, 'Products', 'Applications'))
            installed = self.make_app(os.path.join(tmp, 'Applications'))
            app, symbols = orderfile.resolve_inputs(archive, installed, None)
            self.assertEqual(app, installed)
            self.assertEqual(symbols, orderfile.archive_paths(archive)[1])
            self.assertEqual(orderfile.resolve_inputs(None, installed, None)[1],
                             os.path.join(installed, 'Contents', 'MacOS', 'Nanogram'))

    def test_debug_builds_trace_the_debug_dylib(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.make_app(tmp)
            macos = os.path.join(app, 'Contents', 'MacOS')
            self.assertEqual(orderfile.default_symbols(app), os.path.join(macos, 'Nanogram'))
            open(os.path.join(macos, 'Nanogram.debug.dylib'), 'w').close()
            self.assertEqual(orderfile.default_symbols(app), os.path.join(macos, 'Nanogram.debug.dylib'))

    def test_the_isolation_shim_refuses_to_run_without_a_container_root(self):
        with open(orderfile.ISOLATE_SOURCE) as f:
            source = f.read()
        self.assertIn('getenv("NANOGRAM_CONTAINER_ROOT") == NULL', source)
        self.assertIn('abort()', source)



class CleanupTests(unittest.TestCase):
    def test_only_ktrace_files_that_appeared_during_the_run_are_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            older = os.path.join(tmp, 'instrumentsOLD.ktrace')
            newer = os.path.join(tmp, 'instrumentsNEW.ktrace')
            other = os.path.join(tmp, 'notes.ktrace')
            for path in (older, newer, other):
                open(path, 'w').close()
            original = orderfile.ktrace_files
            orderfile.ktrace_files = lambda: {older, newer}
            try:
                orderfile.remove_ktrace_files_left_since({older})
            finally:
                orderfile.ktrace_files = original
            self.assertTrue(os.path.exists(older))
            self.assertFalse(os.path.exists(newer))
            self.assertTrue(os.path.exists(other))


if __name__ == '__main__':
    unittest.main()
