import json
import os
from pathlib import Path
from queue import Queue
import subprocess
import sys
import tempfile
from threading import Thread
import unittest


class WorkerTests(unittest.TestCase):
    def test_request_workers_reject_invalid_messages_and_keep_serving(self):
        root = Path(__file__).resolve().parents[1]
        invalid = ['', '[]', '"text"', 'null', '42', 'true', '{']
        requests = {
            'code_intelligence': (
                {'id': 'missing', 'action': 'decode_source'},
                {'id': 'valid', 'action': 'decode_source', 'data': 'cHJpbnQoMSkK'},
                'source',
            ),
            'blueprint': (
                {'id': 'missing'},
                {'id': 'valid', 'source': 'answer = 42\n'},
                'graph',
            ),
        }
        for module, (missing, valid, result_key) in requests.items():
            with self.subTest(module=module):
                lines = [*invalid, json.dumps(missing), json.dumps(valid), '']
                result = subprocess.run(
                    [sys.executable, '-u', '-m', f'pyvis_runtime.{module}'],
                    input='\n'.join(lines), capture_output=True, encoding='utf-8',
                    check=True, timeout=10,
                    env={**os.environ, 'PYTHONPATH': str(root / 'runtime'),
                         'PYTHONIOENCODING': 'utf-8'})
                replies = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(len(replies), len(invalid) + 2)
                for reply in replies[:len(invalid)]:
                    self.assertIsNone(reply['id'])
                    self.assertIn('error', reply)
                self.assertEqual(replies[-2]['id'], 'missing')
                self.assertIn('error', replies[-2])
                self.assertEqual(replies[-1]['id'], 'valid')
                self.assertIn(result_key, replies[-1])
                self.assertEqual(result.stderr, '')

    def test_run_commands_keep_accepting_input_and_stop_after_invalid_messages(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as folder:
            entry = Path(folder) / 'main.py'
            entry.write_text("print(input('first'), flush=True)\ninput('second')\n")
            with subprocess.Popen(
                [sys.executable, '-u', '-m', 'pyvis_runtime', str(entry), '--worker'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                encoding='utf-8',
                env={**os.environ, 'PYTHONPATH': str(root / 'runtime'),
                     'PYTHONIOENCODING': 'utf-8'},
            ) as process:
                lines = Queue()

                def read_events():
                    for line in process.stdout:
                        lines.put(line)

                def until(kind):
                    events = []
                    while True:
                        event = json.loads(lines.get(timeout=5))
                        events.append(event)
                        if event['kind'] == kind:
                            return events

                reader = Thread(target=read_events, daemon=True)
                reader.start()
                try:
                    self.assertEqual(until('input_request')[-1]['prompt'], 'first')
                    process.stdin.write('[]\nnull\n{\n{"action":"input","text":"OK"}\n')
                    process.stdin.flush()
                    events = until('input_request')
                    self.assertEqual(events[-1]['prompt'], 'second')
                    self.assertEqual(sum(e['kind'] == 'protocol_error' for e in events), 3)
                    self.assertEqual(''.join(e['text'] for e in events if e['kind'] == 'output'), 'OK\n')
                    process.stdin.write('{"action":"stop"}\n')
                    process.stdin.flush()
                    self.assertEqual(until('finished')[-1]['error']['type'], 'KeyboardInterrupt')
                    self.assertEqual(process.wait(timeout=5), 0)
                    self.assertEqual(process.stderr.read(), '')
                finally:
                    if process.poll() is None:
                        process.kill()
                    reader.join(timeout=5)

    def test_compact_heap_reuses_only_the_previous_snapshot(self):
        from pyvis_runtime.__main__ import HeapDelta

        delta = HeapDelta()
        before = {'heap': {'o1': {'type': 'list', 'items': []}}}
        after = {'heap': {'o1': {'type': 'list', 'items': [{'type': 'int', 'value': 1}]}}}
        self.assertEqual(delta.event(before), before)
        output = {'kind': 'output', 'heap': {}, 'text': 'hi\n'}
        self.assertEqual(delta.event(output), output)
        self.assertEqual(delta.event(before), {'heap': {'o1': None}})
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
            source = json.loads(process.stdout.readline())
            call = json.loads(process.stdout.readline())
            first = json.loads(process.stdout.readline())
            self.assertEqual(source['kind'], 'source')
            self.assertEqual(source['file'], call['file'])
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
            self.assertNotIn('sources', events[-1])
            self.assertEqual(stderr, '')
        finally:
            if process.poll() is None: process.kill()
            process.wait()
            for pipe in (process.stdin, process.stdout, process.stderr):
                pipe.close()


if __name__ == '__main__':
    unittest.main()
