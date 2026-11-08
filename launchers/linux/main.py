#!/usr/bin/env python3
"""Linux text-shell prototype: inspect existing Jobs, never build or install."""
import argparse
import json
from pathlib import Path
import sys
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'launchers/shared'))
from launcher_client.client import Client, Cursor, ProtocolError, device_view


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['show', 'watch', 'cancel', 'devices'])
    parser.add_argument('--private-root', type=Path)
    parser.add_argument('--task')
    args = parser.parse_args(argv)
    if args.command == 'devices':
        print(json.dumps(device_view(None), ensure_ascii=False)); return 2
    if args.private_root is None or args.task is None:
        parser.error('--private-root and --task required')
    client = Client(ROOT, args.private_root)
    cursor = Cursor()
    try:
        if args.command == 'cancel':
            response = client.cancel(args.task)
            print('取消请求已发送，等待作业终态。' if response.get('cancelled') else '没有发送取消请求。')
        while True:
            if args.command == 'watch':
                for event in client.events(args.task, cursor):
                    # Historical records never decide current status. Avoid
                    # dumping path-bearing diagnostics/results onto the display.
                    print(json.dumps({'history': True, 'type': event.get('type'),
                                      'seq': event.get('seq'), 'stage': event.get('stage')}, ensure_ascii=False))
            snapshot = client.get(args.task)
            state = 'interrupted' if snapshot.get('interrupted') else snapshot.get('state')
            print(json.dumps({'task': args.task, 'state': state,
                              'attemptNo': snapshot.get('attemptNo'),
                              'stage': snapshot.get('stage'),
                              'terminal': snapshot.get('terminal')}, ensure_ascii=False), flush=True)
            if args.command != 'watch' or snapshot.get('terminal') or snapshot.get('interrupted'):
                return 0
            time.sleep(0.5)
    except (ProtocolError, OSError, TimeoutError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr); return 2
    except KeyboardInterrupt:
        # Closing a viewer does not cancel a job.
        return 130


if __name__ == '__main__':
    sys.exit(main())
