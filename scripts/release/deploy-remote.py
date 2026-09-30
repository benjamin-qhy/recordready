"""Invoked under the SSH publisher lock. No network operations or external dependencies."""
import hashlib
import json
import os
import re
import sys
import shutil
from pathlib import Path
import xml.etree.ElementTree as ET


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return {'bytes': path.stat().st_size, 'sha256': h.hexdigest()}


def inventory(folder):
    result = {}
    for p in folder.rglob('*'):
        if p.is_symlink():
            raise RuntimeError('UNEXPECTED_SYMLINK')
        if p.is_file():
            result[p.relative_to(folder).as_posix()] = digest(p)
    return result


def publish(base, deployment_id, files):
    if not re.fullmatch(r'[a-zA-Z0-9-]+', deployment_id):
        raise RuntimeError('INVALID_DEPLOYMENT_PATH')
    stage = base / 'staging' / deployment_id
    live = base / 'site'
    for name in files:
        p = Path(name)
        if p.is_absolute() or '..' in p.parts or p.parts[0] not in ('web', 'releases'):
            raise RuntimeError('INVALID_UPLOAD_PATH')
    if inventory(stage) != files:
        raise RuntimeError('UPLOAD_HASH_MISMATCH')
    catalog = json.loads((stage / 'web/releases.json').read_text())['releases']
    if not catalog:
        raise RuntimeError('EMPTY_CATALOG')
    feed = stage / 'web/updates/macos/arm64/appcast.xml'
    versions = [int(x.text) for x in ET.parse(feed).iter('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')]
    if versions != [catalog[0]['build']]:
        raise RuntimeError('APPCAST_CATALOG_MISMATCH')
    if live.exists():
        if not live.is_symlink():
            raise RuntimeError('LIVE_PATH_MUST_BE_MANAGED_SYMLINK')
        old = json.loads((live / 'releases.json').read_text())['releases']
        if old and old[0]['build'] > catalog[0]['build']:
            raise RuntimeError('REMOTE_NEWER_THAN_LOCAL')
        for release in old:
            if release not in catalog:
                raise RuntimeError('IMMUTABLE_CATALOG_ENTRY_CHANGED')
    # Finish every check before any promotion. Existing release metadata is immutable too.
    for release in catalog:
        version = release['version']
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.[1-9]\d*)?', version):
            raise RuntimeError('INVALID_RELEASE_PATH')
        folder = stage / 'releases' / version
        if not folder.is_dir():
            raise RuntimeError('MISSING_RELEASE')
        target = base / 'releases' / version
        if target.exists() and inventory(target) != inventory(folder):
            raise RuntimeError('IMMUTABLE_RELEASE_CHANGED')
    # mkdtemp-based local artifacts may arrive as 0700. Only verified public
    # distribution content becomes world-readable; no private key enters this tree.
    for root in [stage / 'web', stage / 'releases']:
        root.chmod(0o755)
        for path in root.rglob('*'):
            path.chmod(0o755 if path.is_dir() else 0o644)
    (base / 'releases').mkdir(exist_ok=True)
    (base / 'snapshots').mkdir(exist_ok=True)
    for release in catalog:
        target = base / 'releases' / release['version']
        if not target.exists():
            (stage / 'releases' / release['version']).rename(target)
    # A macOS release must preserve the independently published Windows channel.
    if (live / 'updates/windows').is_dir():
        shutil.copytree(live / 'updates/windows', stage / 'web/updates/windows', symlinks=True, dirs_exist_ok=True)
        shutil.copytree(live / 'windows', stage / 'web/windows', symlinks=True, dirs_exist_ok=True)
        for filename in ('index.html', 'download.html'):
            page = stage / 'web' / filename
            if page.exists():
                html = page.read_text()
                if 'id="windows-download"' not in html:
                    page.write_text(html.replace('<main>', '<main><p id="windows-download"><a class="button secondary" href="/windows/">下载 Windows 内测版 / Windows beta</a></p>', 1))
    snapshot = base / 'snapshots' / deployment_id
    (stage / 'web').rename(snapshot)
    (snapshot / 'releases').symlink_to(Path('..') / '..' / 'releases', target_is_directory=True)
    pointer = base / ('site-next-' + deployment_id)
    pointer.symlink_to(Path('snapshots') / deployment_id, target_is_directory=True)
    # One atomic swap publishes HTML, catalog and feed together; older snapshots remain recoverable.
    os.replace(pointer, live)
    return catalog[0]['version']


if __name__ == '__main__':
    payload = json.load(sys.stdin)
    version = publish(Path('/srv/recordready'), payload['id'], payload['files'])
    print('Published verified RecordReady ' + version)
