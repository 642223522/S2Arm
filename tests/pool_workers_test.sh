#!/bin/bash
# 进程池路数单测（#1332：Windows 进程池至多 61 路）：四处真实入口模拟 88 / 128 核 Windows，记下交给进程池的路数
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$H/tests/pool_workers_test.py"
