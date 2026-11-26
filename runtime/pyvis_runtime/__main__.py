import argparse
import json
import os
from pathlib import Path
import queue
import sys
import threading

from .engine import Recorder


class HeapDelta:
    """Reuse unchanged entries from the preceding snapshot on the worker wire."""

    def __init__(self):
        self.previous = {}

    def snapshot(self, snapshot):
        heap = snapshot['heap']
        previous = self.previous
        current = {}
        compact = {}
        for key, value in heap.items():
            # Serialized equality preserves dictionary order and the sign of zero.
            fingerprint = json.dumps(value, separators=(',', ':'), allow_nan=False)
            current[key] = fingerprint
            compact[key] = None if previous.get(key) == fingerprint else value
        self.previous = current
        return {**snapshot, 'heap': compact}

    def event(self, event):
        if event.get('kind') == 'output':
            return event
        if 'before' in event:
            event = {**event, 'before': self.snapshot(event['before'])}
        return self.snapshot(event)


def main():
    parser = argparse.ArgumentParser(description='Record real Python execution for the learning editor')
    parser.add_argument('entry')
    parser.add_argument('--project')
    parser.add_argument('--output')
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--mode', choices=['direct', 'demo'], default='direct')
    args = parser.parse_args()
    wire = sys.stdout
    send_lock = threading.Lock()
    condition = threading.Condition()
    state = {'paused': args.mode == 'demo', 'steps': 0, 'stopped': False}
    inputs = queue.Queue()
    compact = os.environ.pop('PYVIS_COMPACT_HEAP', '') == '1'
    delta = HeapDelta() if args.worker and compact else None

    def send(message):
        with send_lock:
            if delta is not None and 'seq' in message:
                message = delta.event(message)
            data = json.dumps(message, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
            wire.write(data.encode('utf-8', 'backslashreplace').decode('utf-8') + '\n')
            wire.flush()

    def commands():
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if not isinstance(command, dict):
                    raise ValueError('运行控制命令必须是 JSON 对象')
                action = command.get('action')
                with condition:
                    if action == 'continue':
                        state['paused'] = False
                    elif action == 'pause':
                        state['paused'] = True
                    elif action == 'step':
                        state['paused'] = True
                        state['steps'] += 1
                    elif action == 'stop':
                        state['stopped'] = True
                        inputs.put(None)
                    elif action == 'input':
                        inputs.put(str(command.get('text', '')))
                    condition.notify_all()
            except (ValueError, TypeError, RecursionError):
                send({'kind': 'protocol_error', 'message': '无效的运行控制命令'})
        with condition:
            state['stopped'] = True
            inputs.put(None)
            condition.notify_all()

    def gate():
        with condition:
            while state['paused'] and not state['steps'] and not state['stopped']:
                condition.wait()
            if state['stopped']:
                raise KeyboardInterrupt('运行已停止')
            if state['steps']:
                state['steps'] -= 1

    def read_input(prompt):
        response = inputs.get() if args.worker else input(prompt)
        if response is None:
            raise KeyboardInterrupt('运行已停止')
        return response

    if args.worker:
        threading.Thread(target=commands, daemon=True).start()
    recorder = Recorder(retain_events=not args.worker or bool(args.output),
                        on_event=send if args.worker else None,
                        on_source=(lambda file, source: send({'kind': 'source', 'file': file,
                                                              'source': source})) if args.worker else None,
                        gate=gate if args.worker else None,
                        input_provider=read_input if args.worker else lambda _: '')
    archive = recorder.run(args.entry, args.project)
    if args.output:
        Path(args.output).write_text(json.dumps(archive, allow_nan=False), encoding='utf-8')
    if args.worker:
        send({'kind': 'finished', 'status': archive['status'], 'error': archive['error'],
              'output': archive['output'],
              **({'output_truncated': True} if recorder.output_truncated else {})})
    else:
        send(archive)


if __name__ == '__main__':
    main()
