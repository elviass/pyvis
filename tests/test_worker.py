import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


class WorkerTests(unittest.TestCase):
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
