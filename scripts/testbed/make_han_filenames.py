"""Create synthetic filename fixtures only; never reads user files.

python3 scripts/testbed/make_han_filenames.py <testbed>/han-filenames
Then sync names only with `digup index <folder> --limit 0 --index <isolated-index>`.
Evaluate evals/han-filenames.json with DIGUP_TESTBED=<testbed>.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1])
for name in [
    "general/學生情緒輔導紀錄.txt",
    "exact/輔導.txt",
    "mixed/２０２６ＣＡＦÉ學生輔導紀錄.txt",
    "other/生涯探索規劃.txt",
    "other/期末教學檢討.txt",
    "other/特殊教育課程簡報.txt",
    "other/資料整理會議紀錄.txt",
    "資料夾輔導/無關文件.txt",
]:
    file = root / name
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text("Synthetic filename-search fixture. No personal data.\n", encoding="utf-8")
