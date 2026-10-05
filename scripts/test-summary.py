#!/usr/bin/env python3
"""Summarize terminal XCTest suite totals without maintaining a README count."""
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
# One top-level suite per SwiftPM test target; ignore nested suite repeats.
blocks = re.findall(r"Test Suite 'All tests' (?:passed|failed).*?\n\s*Executed (\d+) tests, with (?:(\d+) tests? skipped and )?(\d+) failures", text)
if not blocks:
    raise SystemExit("No complete XCTest target totals found")
counts = [[int(v or 0) for v in block] for block in blocks]
total, skipped, failed = [sum(row[i] for row in counts) for i in range(3)]
print(f"## XCTest result\n\n{total} tests; {skipped} skipped; {failed} failures across {len(counts)} targets.")
if failed:
    raise SystemExit(1)
