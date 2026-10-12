"""Synthetic adversarial regressions; never read real sessions or start agents."""
import json
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bridge"))
from common import atomic_json, read_decision, request
from connect import configure
from harnesses import Registry, register
from mission_commands import apply
from peek import checkpoint


class ReviewHardeningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def test_missing_checkpoint_mission_has_a_clear_error_and_no_partial_record(self):
        state = self.directory / 'state.json'
        atomic_json(state, {'missions': [], 'agents': [{'id': 'a', 'missionId': 'gone'}]})
        with self.assertRaisesRegex(SystemExit, 'Mission not found'):
            checkpoint(SimpleNamespace(state=str(state), agent='a', checkpoint='c'))
        self.assertFalse((self.directory / 'missions').exists())
        self.assertFalse((self.directory / 'progress').exists())

    def test_demo_review_already_rejects_a_missing_mission(self):
        state = self.directory / 'state.json'
        atomic_json(state, {'demo': True, 'missions': [], 'agents': []})
        with self.assertRaisesRegex(ValueError, 'mission is no longer available'):
            apply(state, 'review-evidence', {'missionId': 'gone'})

    def test_malformed_existing_copilot_hook_is_rejected_without_overwriting(self):
        project = self.directory / 'project'
        target = project / '.github/hooks/sneakpeek.json'
        for handler in [None, 'bad', [], {'args': 'not-an-array'}, {'args': [17]}]:
            with self.subTest(handler=handler):
                atomic_json(target, {'version': 1, 'hooks': {'sessionStart': [handler]}})
                before = target.read_bytes()
                with self.assertRaises(ValueError):
                    configure('copilot', project, self.directory / 'state.json')
                self.assertEqual(target.read_bytes(), before)
                self.assertFalse(target.with_suffix('.json.before-sneakpeek').exists())

    def test_pre_request_future_and_nonfinite_decision_dates_fail_closed(self):
        pending = request('Synthetic permission', 'DO NOT EXECUTE')
        issued = pending['issuedAt']
        path = self.directory / 'decisions' / (pending['id'] + '.json')
        for created in [issued - 3300, issued - 0.001, issued + 7, True, float('nan'), float('inf')]:
            with self.subTest(created=created):
                atomic_json(path, {'requestId': pending['id'], 'agentId': 'a', 'choiceId': 'accept', 'createdAt': created})
                with patch('common.time.time', return_value=issued + 1):
                    self.assertIsNone(read_decision(path.parent, pending, 'a', trusted_local_inline=True))
        atomic_json(path, {'requestId': pending['id'], 'agentId': 'a', 'choiceId': 'accept', 'createdAt': issued + 0.5})
        with patch('common.time.time', return_value=issued + 1):
            self.assertEqual(read_decision(path.parent, pending, 'a', trusted_local_inline=True), 'accept')
            legacy = dict(pending)
            legacy.pop('issuedAt')
            self.assertIsNone(read_decision(path.parent, legacy, 'a', trusted_local_inline=True))

    def test_root_home_and_symlink_root_scans_never_reach_glob(self):
        home = self.directory / 'home'; home.mkdir()
        (home / 'root-link').symlink_to('/', target_is_directory=True)
        registry = Registry(home, self.directory / 'state')
        for pattern in ['/**/*.jsonl', str(home / '**/*.jsonl'), str(home / 'root-link/**/*.jsonl')]:
            with self.subTest(pattern=pattern), patch('harnesses.glob.iglob', side_effect=AssertionError('Must not scan')):
                files, info = registry.discover({'id': 'x', 'name': 'X', 'provider': 'X', 'format': 'sneakpeek',
                    'enabled': True, 'builtin': False, 'logs': [pattern]})
                self.assertEqual(files, [])
                self.assertEqual(info['status'], 'error')

    def test_disabled_harness_does_not_scan_and_registration_requires_one_file(self):
        registry = Registry(self.directory / 'home', self.directory / 'state')
        with patch('harnesses.glob.iglob', side_effect=AssertionError('Must not scan')):
            files, info = registry.discover({'id': 'x', 'name': 'X', 'provider': 'X', 'format': 'sneakpeek',
                'enabled': False, 'builtin': False, 'logs': ['/**/*.jsonl']})
        self.assertEqual(files, [])
        self.assertEqual(info['status'], 'disabled')
        with self.assertRaisesRegex(ValueError, 'without wildcard'):
            register(self.directory, 'New', '/**/*.jsonl')
        self.assertFalse((self.directory / 'harnesses.json').exists())

    def test_narrow_scans_and_explicit_files_remain_available(self):
        home = self.directory / 'home'; folder = home / '.logs'; folder.mkdir(parents=True)
        path = folder / 'one.jsonl'; path.write_text('{}\n')
        registry = Registry(home, self.directory / 'state')
        definition = {'id': 'x', 'name': 'X', 'provider': 'X', 'format': 'sneakpeek',
                      'enabled': True, 'builtin': False, 'logs': [str(folder / '*.jsonl')]}
        self.assertEqual(registry.discover(definition)[0], [path])
        definition['logs'] = [str(path)]
        self.assertEqual(registry.discover(definition)[0], [path])


    def test_malformed_request_fields_are_rejected_without_a_traceback(self):
        pending = request('Synthetic permission', 'DO NOT EXECUTE')
        for field, value in [('id', 17), ('id', None), ('issuedAt', True), ('expiresAt', float('inf'))]:
            with self.subTest(field=field, value=value):
                changed = dict(pending, **{field: value})
                self.assertIsNone(read_decision(self.directory, changed, 'a', trusted_local_inline=True))

    def test_symlink_loops_and_null_paths_report_a_discovery_error(self):
        home = self.directory / 'home'; home.mkdir()
        (home / 'loop').symlink_to(home / 'loop', target_is_directory=True)
        registry = Registry(home, self.directory / 'state')
        for pattern in [str(home / 'loop/**/*.jsonl'), '/bad\0path/*.jsonl']:
            with self.subTest(pattern=pattern), patch('harnesses.glob.iglob', side_effect=AssertionError('Must not scan')):
                files, info = registry.discover({'id': 'x', 'name': 'X', 'provider': 'X', 'format': 'sneakpeek',
                    'enabled': True, 'builtin': False, 'logs': [pattern]})
                self.assertEqual(files, [])
                self.assertEqual(info['status'], 'error')
