import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class WorkerTests(unittest.TestCase):
    def test_compact_heap_reuses_only_the_previous_snapshot(self):
        from pyvis_runtime.__main__ import HeapDelta

        delta = HeapDelta()
        before = {'heap': {'o1': {'type': 'list', 'items': []}}}
        after = {'heap': {'o1': {'type': 'list', 'items': [{'type': 'int', 'value': 1}]}}}
        self.assertEqual(delta.event(before), before)
        self.assertEqual(delta.event({**after, 'before': before}),
                         {**after, 'before': {'heap': {'o1': None}}})
        self.assertEqual(delta.event(after), {'heap': {'o1': None}})
        delta.event({'heap': {}})
        self.assertEqual(delta.event(after), after)
        positive = {'heap': {'o1': {'type': 'list', 'items': [{'type': 'float', 'value': 0.0}]}}}
        negative = {'heap': {'o1': {'type': 'list', 'items': [{'type': 'float', 'value': -0.0}]}}}
        delta.event(positive)
        self.assertEqual(delta.event(negative)['heap']['o1']['items'][0]['value'].hex(), '-0x0.0p+0')

    def test_archive_json_can_encode_unpaired_surrogate_in_snapshot(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as folder:
            entry = Path(folder) / 'main.py'
            entry.write_text("value = chr(0xD800)\nprint('ok')\n")
            result = subprocess.run([sys.executable, '-m', 'pyvis_runtime', str(entry)],
                                    capture_output=True, text=True, check=True,
                                    env={**os.environ, 'PYTHONPATH': str(root/'runtime')})
        archive = json.loads(result.stdout)
        self.assertEqual(archive['output']['stdout'], 'ok\n')
        self.assertTrue(any(value.get('value') == chr(0xD800) for event in archive['events']
                            for frame in event['frames'] for value in frame['locals'].values()))

    def test_demo_steps_and_stop(self):
        root = Path(__file__).resolve().parents[1]
        process = subprocess.Popen([sys.executable, '-u', '-m', 'pyvis_runtime',
            str(root/'examples/递归.py'), '--worker', '--mode', 'demo'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env={**os.environ, 'PYTHONPATH': str(root/'runtime')})
        try:
            call = json.loads(process.stdout.readline())
            first = json.loads(process.stdout.readline())
            self.assertEqual(call['kind'], 'call')
            self.assertEqual(first['kind'], 'line')
            process.stdin.write('{"action":"step"}\n'); process.stdin.flush()
            stepped = []
            while True:
                event = json.loads(process.stdout.readline())
                stepped.append(event)
                if event['kind'] == 'line':
                    break
            self.assertNotEqual(first['line'], stepped[-1]['line'])
            process.stdin.write('{"action":"stop"}\n'); process.stdin.flush()
            rest, stderr = process.communicate(timeout=5)
            events = [json.loads(line) for line in rest.splitlines()]
            self.assertEqual(events[-1]['kind'], 'finished')
            self.assertEqual(events[-1]['error']['type'], 'KeyboardInterrupt')
            self.assertEqual(stderr, '')
        finally:
            if process.poll() is None: process.kill()
            process.wait()
            for pipe in (process.stdin, process.stdout, process.stderr):
                pipe.close()


if __name__ == '__main__':
    unittest.main()
