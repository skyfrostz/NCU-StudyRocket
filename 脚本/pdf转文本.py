#!/usr/bin/env python3
"""批量将智库 PDF 转为可检索文本，存入 PDF提取文本/"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "智库"
DST = ROOT / "PDF提取文本"

# 跳过已确认无文字层的扫描版
SKIP = {"保研200问", "保研蓝皮书", "考研一本通", "全国大学生英语竞赛指南手册", "雅思I段阅读练习册"}


def extract(pdf: Path, out: Path) -> bool:
    result = subprocess.run(
        ["pdftotext", "-layout", str(pdf), str(out)],
        capture_output=True,
    )
    if result.returncode != 0:
        return False
    text = out.read_text(errors="ignore").strip()
    return len(text) > 10


def main():
    DST.mkdir(exist_ok=True)
    extracted, skipped, failed = 0, 0, []

    for pdf in sorted(SRC.rglob("*.pdf")):
        stem = pdf.stem
        if stem in SKIP:
            skipped += 1
            continue
        out = DST / f"{stem}.txt"
        if out.exists():
            skipped += 1
            continue
        if extract(pdf, out):
            extracted += 1
        else:
            failed.append(pdf.name)
            out.unlink(missing_ok=True)

    print(f"提取完成: {extracted} 个, 跳过: {skipped} 个")
    if failed:
        print("以下 PDF 无文字层（扫描版），需要 OCR:")
        for f in failed:
            print(f"  - {f}")


if __name__ == "__main__":
    main()
