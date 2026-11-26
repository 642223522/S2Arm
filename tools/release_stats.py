#!/usr/bin/env python3
"""发版数字（README、官网、发版海报、发版说明共用）：release_stats.py <发版提交> [--since-tag v0.5.0] [--json]

口径（一句话）：以上一个大版本标签（缺省 v0.5.0）为起点、到发版提交为止——
  修复：这段范围内 main 上标题以 fix 开头的非合并提交数；
  反馈：上一个大版本在 GitHub 发布之后、到发版提交的提交时刻之间关闭的 Issue 数（不含 PR）；
  社区贡献：这段范围内经 contrib/pr<号> 分支合进 main 的不同 PR 数。
只读：读本地 git 与 GitHub（gh api），不改任何东西。"""
import argparse, json, re, subprocess
from datetime import datetime, timezone

REPO = 'jhaizhou-ops/S2Arm'

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('commit')
    ap.add_argument('--since-tag', default='v0.5.0')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    commit = sh('git', 'rev-parse', '--verify', a.commit + '^{commit}').strip()
    rng = f'{a.since_tag}..{commit}'
    fixes = sum(1 for s in sh('git', 'log', '--no-merges', '--format=%s', rng).splitlines() if s.startswith('fix'))
    prs = set(re.findall(r'contrib/pr(\d+)', sh('git', 'log', '--merges', '--format=%s', rng)))
    start = json.loads(sh('gh', 'release', 'view', a.since_tag, '-R', REPO, '--json', 'publishedAt'))['publishedAt']
    end_utc = datetime.fromtimestamp(int(sh('git', 'show', '-s', '--format=%ct', commit)), timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    q = f'repo:{REPO} is:issue is:closed closed:{start}..{end_utc}'
    issues = json.loads(sh('gh', 'api', '-X', 'GET', 'search/issues', '-f', f'q={q}', '-f', 'per_page=1'))['total_count']
    out = {'commit': commit[:9], 'since': a.since_tag, 'fixes': fixes, 'issues_closed': issues,
           'community_prs': len(prs), 'window': [start, end_utc]}
    if a.json:
        print(json.dumps(out, ensure_ascii=False))
    else:
        print(f'{a.since_tag} → {commit[:9]}（{start} ～ {end_utc}）')
        print(f'修复提交 {fixes} · 关闭反馈帖 {issues} · 社区 PR {len(prs)}')

if __name__ == '__main__':
    main()
