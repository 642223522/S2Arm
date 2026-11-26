"""视觉门禁 ②：基线上屏图逐像素比固定参照真值（tests/visual/gate.sh 调）。

用法：ref_truth_cmp.py <我方 present_<帧>.png> <真值目录> <ref_truth.tsv> <录像文件> <帧>
真值文件 = <真值目录>/<录像去 .rec>_<帧>.png；先核它的 sha256 等于 ref_truth.tsv 里登记的值（真值缺 / 不在登记表 / 内容被换 = 红），
再逐像素比：差异像素 = RGB 任一通道差 > 2，占比 ≤ 0.5% 过；PSNR 按 RGB（全同记 99）。口径与 galplay --ref 的上屏图对拍一致。
退出码 0 = 过；1 = 不过（末行写原因）。
"""
import hashlib
import os
import sys

import numpy as np
from PIL import Image

LIMIT = 0.5   # 差异像素占比上限（%）


def main(a):
    if len(a) != 5:
        print(__doc__.strip().splitlines()[2]); return 1
    ours, tdir, tsv, rec, fr = a
    want = None
    with open(tsv, encoding="utf-8") as f:
        for ln in f:
            c = ln.rstrip("\n").split("\t")
            if len(c) >= 3 and not ln.startswith("#") and c[0] == rec and c[1] == fr:
                want = c[2]
    if want is None:
        print(f"{rec} 帧 {fr} 不在 {tsv}"); return 1
    tp = os.path.join(tdir, f"{rec[:-4] if rec.endswith('.rec') else rec}_{fr}.png")
    if not os.path.isfile(tp):
        print(f"真值缺：{tp}"); return 1
    got = hashlib.sha256(open(tp, "rb").read()).hexdigest()
    if got != want:
        print(f"真值内容与登记不符：{tp} sha256 {got[:16]}…，登记 {want[:16]}…"); return 1
    if not os.path.isfile(ours):
        print(f"我方出图缺：{ours}"); return 1
    x = np.asarray(Image.open(ours).convert("RGB")).astype(np.int32)
    y = np.asarray(Image.open(tp).convert("RGB")).astype(np.int32)
    if x.shape != y.shape:
        print(f"尺寸不同：我方 {x.shape[1]}×{x.shape[0]}，真值 {y.shape[1]}×{y.shape[0]}"); return 1
    d = np.abs(x - y)
    pct = float((d.max(axis=2) > 2).mean() * 100)
    mse = float((d.astype(np.float64) ** 2).mean())
    psnr = 99.0 if mse == 0 else 10 * np.log10(255.0 * 255 / mse)
    print(f"帧 {fr}：差异像素 {pct:.2f}%（通道差 > 2），PSNR {psnr:.2f} dB（门槛 ≤ {LIMIT}%）")
    return 0 if pct <= LIMIT else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
