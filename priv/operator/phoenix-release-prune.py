#!/usr/bin/env python3
"""Bound a physical host's explicit release roots; always protect both slots.

Dry run is default. Caller must hold each application's deployment operation lock.
No backup, evidence or database directories are eligible.
"""
import argparse
import json
from pathlib import Path
import re
import shutil


def plan(roots, slots, keep=2):
    if keep < 2:
        raise ValueError('keep at least two releases')
    protected=set()
    for slot in slots:
        slot=Path(slot)
        if not slot.is_symlink() or not slot.resolve(strict=True).is_dir():
            raise ValueError('missing slot target: '+str(slot))
        protected.add(slot.resolve().name)
    result=[]
    for root in roots:
        root=Path(root)
        if root.is_symlink() or not root.is_dir() or root.name != 'releases':
            raise ValueError('invalid release root')
        dirs=list(root.iterdir())
        if any(p.is_symlink() or not p.is_dir() or not re.fullmatch(r'[A-Za-z0-9_.-]+-[0-9]+', p.name) for p in dirs):
            raise ValueError('unexpected release root content')
        dirs.sort(key=lambda p:p.stat().st_mtime,reverse=True)
        selected={p.name for p in dirs[:keep]} | protected
        result.extend(str(p) for p in dirs if p.name not in selected)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', action='append', required=True)
    parser.add_argument('--slot', action='append', required=True)
    parser.add_argument('--keep', type=int, default=2)
    parser.add_argument('--apply', action='store_true')
    args=parser.parse_args()
    selected=plan(args.root,args.slot,args.keep)
    print(json.dumps({'dry_run':not args.apply,'remove':selected}),flush=True)
    if args.apply:
        for path in selected:
            shutil.rmtree(path)


if __name__=='__main__':
    main()
