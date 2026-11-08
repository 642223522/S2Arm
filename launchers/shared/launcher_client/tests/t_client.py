import json
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'launchers/shared'))
from launcher_client.client import Client, Cursor, ProtocolError, Projection, Lines, device_view


class ContractTests(unittest.TestCase):
    def event(self, **kw):
        return dict(schema=1, taskId='job', type='progress', state='running', **kw)

    def test_chunks_and_eof(self):
        data = (json.dumps(self.event(message='中文'), ensure_ascii=False)+'\n').encode()
        for split in range(len(data)+1):
            stream = Lines(); out = stream.feed(data[:split])+stream.feed(data[split:])
            self.assertEqual(out, [self.event(message='中文')]); self.assertEqual(stream.finish(), [])
        stream = Lines(); stream.feed(data[:-1])
        with self.assertRaises(ProtocolError): stream.finish()

    def test_projection_terminal_and_reset(self):
        p = Projection('job'); p.consume(self.event(done=7, total=7))
        self.assertEqual(p.state, 'running')
        p.consume(dict(schema=1, jobId='job', type='stage', state='running'))
        self.assertIsNone(p.done); self.assertIsNone(p.total)
        p.consume(dict(schema=1, taskId='job', type='result', state='succeeded'))
        p.eof(0); self.assertEqual(p.state, 'completed')
        q = Projection('job'); q.eof(0); self.assertEqual(q.state, 'interrupted')

    def test_cancel_ack_is_not_terminal(self):
        p = Projection('job'); p.cancel_ack({'cancelled': True})
        self.assertEqual(p.state, 'running'); self.assertTrue(p.cancel_requested)
        p.consume(dict(schema=1, taskId='job', type='result', state='succeeded'))
        self.assertEqual(p.state, 'completed')

    def test_identity_and_schema(self):
        for e in [dict(schema=2, taskId='job'), dict(schema=1, taskId='other'), dict(schema=True, taskId='job')]:
            with self.assertRaises(ProtocolError): Projection('job').consume(e)

    def test_device_quick_and_unsupported(self):
        old = {'connected': [{'name': 'synthetic'}], 'models': [], 'osChoices': []}
        self.assertEqual(device_view({'connected': [], 'models': [], 'osChoices': [18]}, quick=True, previous=old)['connected'], old['connected'])
        self.assertFalse(device_view(None)['supported'])

    def test_physical_cursor_and_partial(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); (root/'jobs').mkdir(); f = root/'jobs/job.events.jsonl'
            a = self.event(seq=1); b = self.event(seq=2)
            f.write_bytes((json.dumps(a)+'\n\n{bad}\n'+json.dumps(b)+'\n').encode()+b'{')
            calls = []
            class Fake(Client):
                def call(self, command, *args):
                    calls.append((command,args)); return [a,b] if len(calls)==1 else [a]
            c = Fake(ROOT, root); cursor = Cursor()
            self.assertEqual(c.events('job', cursor), [a,b]); self.assertEqual(cursor.line,4)
            f.write_bytes(f.read_bytes()[:-1]+(json.dumps(a)+'\n').encode())
            self.assertEqual(c.events('job',cursor), [a]); self.assertEqual(cursor.line,5)
            self.assertEqual(calls[1][1], ('--task','job','--since','4','--limit','1'))

    def test_append_during_call_does_not_advance_past_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp); (root/'jobs').mkdir(); path=root/'jobs/job.events.jsonl'
            a=self.event(seq=1); b=self.event(seq=2)
            path.write_text(json.dumps(a)+'\n')
            class Appending(Client):
                def call(self, command, *args):
                    with path.open('a') as f: f.write(json.dumps(b)+'\n')
                    return [a]
            cursor=Cursor(); c=Appending(ROOT,root)
            self.assertEqual(c.events('job',cursor),[a]); self.assertEqual(cursor.line,1)
            self.assertEqual(cursor.offset,len((json.dumps(a)+'\n').encode()))

    def test_mutation_during_call_does_not_advance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp); (root/'jobs').mkdir(); path=root/'jobs/job.events.jsonl'
            a=self.event(seq=1); path.write_text(json.dumps(a)+'\n')
            class Mutating(Client):
                def call(self, command, *args):
                    path.write_bytes(b''); return [a]
            cursor=Cursor()
            with self.assertRaises(ProtocolError): Mutating(ROOT,root).events('job',cursor)
            self.assertEqual((cursor.line,cursor.offset),(0,0))

    def test_unknown_operation_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            c = Client(ROOT,pathlib.Path(tmp))
            with self.assertRaises(ProtocolError): c.call('install')

if __name__ == '__main__': unittest.main()
