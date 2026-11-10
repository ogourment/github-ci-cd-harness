#!/usr/bin/env python3
"""Bound derived thumbnail entries, leaving unrelated paths and originals untouched."""
import argparse
from pathlib import Path
import re
import time


def prune(root, max_bytes, max_age_days):
    entries = []
    if root.is_symlink():
        raise ValueError('Thumbnail cache root must not be a symlink')
    for directory in root.iterdir():
        if directory.is_symlink() or not directory.is_dir() or not re.fullmatch('[0-9a-f]{64}', directory.name):
            continue
        for image in directory.glob('*.webp'):
            if image.is_symlink() or not image.is_file() or not re.fullmatch('[0-9a-f]{64}\\.webp', image.name):
                continue
            checksum = image.with_suffix('.webp.sha256')
            paths = [path for path in (image, checksum) if path.is_file() and not path.is_symlink()]
            if not paths:
                continue
            try:
                entries.append((max(path.stat().st_mtime for path in paths), paths,
                                sum(path.stat().st_size for path in paths)))
            except FileNotFoundError:
                continue  # Another cache writer may have already retired the entry.
    total = sum(size for _, _, size in entries)
    cutoff = time.time() - max_age_days * 86400
    removed = 0
    for modified, paths, size in sorted(entries, key=lambda entry: entry[0]):
        if modified >= cutoff and total <= max_bytes:
            break
        for path in paths:
            path.unlink(missing_ok=True)
        total -= size
        removed += 1
    return removed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--max-bytes', type=int, default=256 * 1024 * 1024)
    parser.add_argument('--max-age-days', type=int, default=7)
    args = parser.parse_args()
    if args.max_bytes < 0 or args.max_age_days < 0:
        parser.error('Cache bounds must be nonnegative')
    print(f'ATDD thumbnail cache pruned_entries={prune(args.root, args.max_bytes, args.max_age_days)}')
