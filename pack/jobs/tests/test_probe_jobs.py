# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""启动器剃刀 H4 / H5：只读探测不落任务记录；心跳只给标准输出；进度节流重写任务记录、阶段照旧 fsync。期望按规则手写。"""
import json
import os
import time
import unittest
from unittest.mock import patch

from jobcase import JobCase

import core
import main
from core import Context, atomic


class ProbeJobTests(JobCase):
    def run_op(self, op, task):
        path = self.root / (task + ".request.json")
        atomic(path, self.request | dict(taskId=task, operation=op))
        with patch("embedded.install"), patch("library.store_meta_background"):
            self.assertEqual(main.run_request(path, operation_overrides={op: lambda c: {"ok": True}}), 0)
        return [json.loads(line) for line in self.output.getvalue().splitlines() if line.startswith("{") and task in line]

    def test_probe_writes_no_job_files_but_reports_on_stdout(self):
        # installCheck / targetDevice / catalog / locations：jobs/ 下没有这个任务的任何文件；结果照样从标准输出回来（终态 succeeded、result 原样）
        jobs = self.c.library / "logs" / "jobs"   # 库建好后任务记录在 <库>/logs/jobs（core.logs_root）
        for op in ("installCheck", "targetDevice", "catalog", "locations"):
            with self.subTest(op=op):
                events = self.run_op(op, "probe-" + op)
                self.assertEqual(sorted(p.name for p in jobs.glob("probe-" + op + "*")), [])
                self.assertEqual((events[-1]["type"], events[-1]["state"], events[-1]["result"]), ("result", "succeeded", {"ok": True}))

    def test_real_job_still_writes_its_three_files(self):
        self.run_op("keys", "real-keys")
        self.assertEqual(sorted(p.name for p in (self.c.library / "logs" / "jobs").glob("real-keys*")),
                         ["real-keys.events.jsonl", "real-keys.json", "real-keys.request.json"])


class JournalCadenceTests(JobCase):
    def test_heartbeat_stdout_only_progress_throttled_stage_durable(self):
        # 一个出包作业：1 次阶段 + 3 次心跳 + 6 次进度（打桩时钟：每次进度相隔 1 秒、共 6 秒）+ 1 次阶段。
        #   期望：心跳 3 条都在标准输出、0 条进事件文件；进度 6 条都进事件文件，任务记录因进度只重写 2 次（第 0 秒距上次阶段 < 5 秒不写，第 5 秒写一次……按
        #   「距上次写 ≥ 5 秒」：阶段在 t=0 写过，进度 t=1..6 里只有 t=5 满足 → 1 次；加两次阶段各 1 次 = 3 次）；
        #   事件文件的 fsync 只在两次阶段（t=0、t=6），任务记录每次原子写自带一次 fsync（core.atomic）→ fsync 共 3 + 2 = 5 次
        c = Context(dict(self.request, taskId="cadence", operation="build"))
        clock = [1000.0]
        writes, syncs = [], []
        real_atomic = core.atomic
        def counting_atomic(path, data, *a, **k):
            if path == c.jobpath:
                writes.append(clock[0])
            return real_atomic(path, data, *a, **k)
        with patch.object(core.time, "monotonic", lambda: clock[0]), patch.object(core, "atomic", counting_atomic), \
                patch.object(core.os, "fsync", lambda fd: syncs.append(clock[0])):
            c.begin("出包")
            for _ in range(3):
                c.emit("heartbeat")
            for i in range(1, 7):
                clock[0] = 1000.0 + i
                c.emit("progress", "进度", done=i, total=10)
            c.begin("收尾", 2, 2)
        lines = [json.loads(l) for l in c.events.read_text(encoding="utf-8").splitlines()]
        out = [json.loads(l) for l in self.output.getvalue().splitlines() if l.startswith("{") and '"cadence"' in l]
        self.assertEqual([e["type"] for e in lines], ["stage"] + ["progress"] * 6 + ["stage"])
        self.assertEqual(sum(e["type"] == "heartbeat" for e in out), 3)
        self.assertEqual(writes, [1000.0, 1005.0, 1006.0])
        self.assertEqual(syncs, sorted(writes + [1000.0, 1006.0]))
        seqs = [e["seq"] for e in out]
        self.assertEqual(seqs, sorted(set(seqs)))   # 标准输出上 seq 仍严格递增（Windows 协议只要求递增，不要求连续）


if __name__ == "__main__":
    unittest.main()
