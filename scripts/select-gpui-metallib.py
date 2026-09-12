#!/usr/bin/env python3
"""Select the current Cargo build's embedded GPUI shader, never scan its cache."""
import json
import mmap
from pathlib import Path
import sys


def select(messages, package_id, executable, build_root):
    outputs = set()
    binaries = []
    finished = []
    for line in messages:
        if not line.startswith('{'):
            continue  # Cargo cannot control output from procedural macros.
        message = json.loads(line)
        reason = message.get('reason')
        if reason == 'build-script-executed' and message.get('package_id') == package_id:
            outputs.add(message['out_dir'])
        if reason == 'compiler-artifact' and message.get('target', {}).get('name') == 'alpine_trace_adapter':
            if message['target'].get('kind') == ['bin'] and not message.get('profile', {}).get('test'):
                binaries.append(message.get('executable'))
        if reason == 'build-finished':
            finished.append(message.get('success'))
    if finished != [True] or len(outputs) != 1 or binaries != [str(executable)]:
        raise ValueError('build must identify one successful sampler and one exact GPUI OUT_DIR')
    shader = Path(outputs.pop()) / 'shaders.metallib'
    shader.resolve(strict=True).relative_to(build_root.resolve(strict=True))
    if shader.is_symlink() or not shader.is_file() or executable.is_symlink():
        raise ValueError('shader and sampler must be regular non-symbolic files')
    data = shader.read_bytes()
    if not data:
        raise ValueError('selected shader is empty')
    # The pinned gpui_macos renderer uses include_bytes! for this OUT_DIR file.
    # Binding the bytes also rejects stale metadata or a replaced sampler.
    with executable.open('rb') as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as binary:
        if binary.find(data) < 0:
            raise ValueError('selected shader is not embedded in the built sampler')
    return shader


if __name__ == '__main__':
    if len(sys.argv) != 5:
        raise SystemExit('expected CARGO_JSON PACKAGE_ID EXECUTABLE RELEASE_BUILD_ROOT')
    try:
        with Path(sys.argv[1]).open() as messages:
            result = select(messages, sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4]))
        print(result)
    except (ValueError, KeyError, OSError, TypeError) as error:
        raise SystemExit(f'GPUI shader selection failed: {error}')
