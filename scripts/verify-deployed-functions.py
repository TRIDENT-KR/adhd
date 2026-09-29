#!/usr/bin/env python3
"""Read-only source verification. Version timestamps can change without new code."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FUNCTIONS = ('analyze-task', 'delete-account', 'storekit-sync', 'app-store-notifications')


def command(args):
    run = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if run.returncode:
        raise RuntimeError(f'{args[1]} operation failed (exit {run.returncode})')
    return run.stdout


def dependencies(entry):
    pending, seen = [entry], set()
    while pending:
        path = pending.pop().resolve()
        if path in seen:
            continue
        if not path.is_relative_to(ROOT / 'supabase/functions'):
            raise RuntimeError('Local import leaves function directory')
        seen.add(path)
        for name in re.findall(r'(?:from|import)\s*[\"\'](\.[^\"\']+)[\"\']', path.read_text()):
            pending.append(path.parent / name)
    return sorted(seen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project_ref')
    parser.add_argument('--json-output', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9]{20}', args.project_ref):
        parser.error('Expected a Supabase project reference')
    deployed = {x['slug']: x for x in json.loads(command([
        'supabase', 'functions', 'list', '--project-ref', args.project_ref, '-o', 'json'
    ]))}
    report = []
    for name in FUNCTIONS:
        info = deployed.get(name)
        item = {'function': name, 'version': info.get('version') if info else None,
                'passed': False, 'files': []}
        if not info:
            item['error'] = 'not_deployed'
        elif info.get('status') != 'ACTIVE' or info.get('verify_jwt') is not False:
            item['error'] = 'gateway_or_function_not_ready'
        else:
            try:
                with tempfile.TemporaryDirectory(prefix='mora-source-verify-') as directory:
                    command(['supabase', 'functions', 'download', name, '--project-ref', args.project_ref,
                             '--use-api', '--workdir', directory])
                    for local in dependencies(ROOT / 'supabase/functions' / name / 'index.ts'):
                        relative = local.relative_to(ROOT)
                        remote = Path(directory) / relative
                        local_hash = hashlib.sha256(local.read_bytes()).hexdigest()
                        remote_hash = hashlib.sha256(remote.read_bytes()).hexdigest() if remote.exists() else None
                        item['files'].append({'path': str(relative), 'local_sha256': local_hash,
                                              'deployed_sha256': remote_hash, 'match': local_hash == remote_hash})
                    item['passed'] = bool(item['files']) and all(x['match'] for x in item['files'])
            except (OSError, RuntimeError) as error:
                item['error'] = str(error)
        report.append(item)
        print(('PASS' if item['passed'] else 'FAIL') + f' {name} v{item["version"]}: source + gateway')
    if args.json_output:
        args.json_output.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if all(x['passed'] for x in report) else 1


if __name__ == '__main__':
    sys.exit(main())
