import argparse
import json
from pathlib import Path
import queue
import sys
import threading

from .engine import Recorder


def main():
    parser = argparse.ArgumentParser(description='Record real Python execution for the learning editor')
    parser.add_argument('entry')
    parser.add_argument('--project')
    parser.add_argument('--output')
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--mode', choices=['direct', 'demo'], default='direct')
    args = parser.parse_args()
    wire = sys.stdout
    condition = threading.Condition()
    state = {'paused': args.mode == 'demo', 'steps': 0, 'stopped': False}
    inputs = queue.Queue()

    def send(message):
        wire.write(json.dumps(message, ensure_ascii=False, allow_nan=False) + '\n')
        wire.flush()

    def commands():
        for line in sys.stdin:
            try:
                command = json.loads(line)
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
            except (ValueError, TypeError):
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
                        gate=gate if args.worker else None,
                        input_provider=read_input if args.worker else lambda _: '')
    archive = recorder.run(args.entry, args.project)
    if args.output:
        Path(args.output).write_text(json.dumps(archive, ensure_ascii=False, allow_nan=False), encoding='utf-8')
    if args.worker:
        send({'kind': 'finished', 'status': archive['status'], 'error': archive['error'],
              'sources': archive['sources'], 'output': archive['output']})
    else:
        send(archive)


if __name__ == '__main__':
    main()
