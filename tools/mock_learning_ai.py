"""Local-only AI acceptance endpoint; no credential or prompt logging.
Run: python3 tools/mock_learning_ai.py --port 8769
Model: mock, slow, unauthorized, unavailable, limited, malformed.
Use any nonempty dummy key. Never use a real credential with this simulator.
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.send_response(200 if self.path.endswith('/models') else 404)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        names = ['mock', 'slow', 'unauthorized', 'unavailable', 'limited', 'malformed']
        if 'gemini' in self.path:
            result = {'models': [{'name': 'models/' + name,
                'supportedGenerationMethods': ['generateContent']} for name in names]}
        else:
            result = {'data': [{'id': name} for name in names], 'has_more': False}
        self.wfile.write(json.dumps(result).encode())

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            model = body.get('model')
            if self.path.endswith(':generateContent'):
                model = self.path.rsplit('/', 1)[1].split(':')[0]
            if model == 'slow':
                time.sleep(60)
            status = {'unauthorized': 401, 'unavailable': 404, 'limited': 429}.get(model, 200)
            if 'tools' in body:
                status = 400
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            if model == 'malformed':
                self.wfile.write(b'not json')
                return
            content = '模拟连接成功。请检查报错行使用的变量和值，结合实际执行顺序理解原因。此回复来自本机模拟端点。'
            if self.path.endswith('/messages'):
                result = {'content': [{'type': 'text', 'text': content}]}
            elif self.path.endswith('/responses'):
                result = {'status': 'completed', 'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': content}]}]}
            elif self.path.endswith(':generateContent'):
                result = {'candidates': [{'content': {'parts': [{'text': content}]}}]}
            else:
                result = {'choices': [{'message': {'content': content}}]}
            if status != 200:
                result = {'error': 'mock failure'}
            self.wfile.write(json.dumps(result, ensure_ascii=False).encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8769)
    args = parser.parse_args()
    print(f'Local mock endpoint: http://127.0.0.1:{args.port}/v1', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
