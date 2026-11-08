"""Synthetic H02 CLI output fixture. Never used by the application."""
import argparse
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--seen", required=True)
parser.add_argument("--keys", required=True)
args = parser.parse_args()
summary = Path(args.keys).with_name("coverage.fixture").read_text()
print(summary, end="")
sys.exit(0 if summary.startswith("ready=1 ") else 1)
