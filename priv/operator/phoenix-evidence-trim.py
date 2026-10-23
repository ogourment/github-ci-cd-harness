#!/usr/bin/env python3
"""Bound screenshot payloads while preserving every acceptance run manifest.

Dry run by default. Old runs become metadata-only, like evidence whose thumbnails
have expired. Never touches application databases, release files or review bundles.
Caller must serialize this operation with other evidence maintenance.
"""
import argparse
import json
from pathlib import Path
import re
import stat


def payloads(run):
    files=[]
    for folder in ['screenshots','thumbnails']:
        directory=run/folder
        if not directory.exists():continue
        if directory.is_symlink() or not directory.is_dir():raise ValueError('unsafe payload directory')
        for path in directory.rglob('*'):
            mode=path.lstat().st_mode
            if stat.S_ISLNK(mode):raise ValueError('unsafe payload symlink')
            if stat.S_ISREG(mode):files.append(path)
            elif not stat.S_ISDIR(mode):raise ValueError('unsupported payload type')
    return files


def plan(root, max_bytes, keep_recent=2):
    root=Path(root)
    if root.is_symlink() or not root.is_dir() or max_bytes < 0 or keep_recent < 2:
        raise ValueError('invalid evidence policy')
    runs=[]
    for run in root.iterdir():
        if run.is_symlink() or not run.is_dir() or not re.fullmatch(r'run-[a-zA-Z0-9._-]+',run.name):
            raise ValueError('unexpected evidence root entry')
        manifest=run/'evidence.json'
        if manifest.is_symlink():raise ValueError('unsafe manifest')
        data=json.loads(manifest.read_text())
        if data['run']['id'] != run.name:raise ValueError('manifest identity mismatch')
        timestamp=data['run'].get('finalized_at') or data.get('generated_at')
        if not isinstance(timestamp,str):raise ValueError('missing run timestamp')
        files=payloads(run)
        runs.append((timestamp,run,files,sum(p.stat().st_size for p in files)))
    runs.sort(key=lambda x:x[0],reverse=True)
    retained=0;evict=[]
    for i,(_,run,files,size) in enumerate(runs):
        if i < keep_recent or retained+size <= max_bytes:
            retained+=size
        else:evict.append((run,files,size))
    if retained > max_bytes:raise ValueError('protected recent runs exceed evidence budget')
    return retained,evict


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',required=True)
    p.add_argument('--max-bytes',type=int,required=True)
    p.add_argument('--keep-recent',type=int,default=2)
    p.add_argument('--apply',action='store_true')
    a=p.parse_args();retained,evict=plan(a.root,a.max_bytes,a.keep_recent)
    print(json.dumps({'dry_run':not a.apply,'retained_payload_bytes':retained,
        'metadata_only_runs':len(evict),'reclaim_bytes':sum(row[2] for row in evict)}),flush=True)
    if a.apply:
        for run,files,_ in evict:
            for file in files:file.unlink()
            (run/'.acceptance-harness-screenshots-archived').write_text('archived: metadata-only by host capacity policy\n')


if __name__=='__main__':main()
