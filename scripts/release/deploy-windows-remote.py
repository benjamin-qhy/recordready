"""Windows publisher, invoked under RecordReady's existing exclusive deploy lock."""
import base64
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return {'bytes': path.stat().st_size, 'sha256': h.hexdigest()}


def add_windows_link(html):
    if 'id="windows-download"' in html:
        return html
    return html.replace('<main>', '<main><p id="windows-download"><a class="button secondary" href="/windows/">下载 Windows 内测版 / Windows beta</a></p>', 1)


def publish(base, payload):
    deployment = payload['id']
    version = payload['version']
    if not re.fullmatch(r'[a-f0-9-]{36}', deployment) or not re.fullmatch(r'0\.1\.0-windows\.[1-9]\d*', version):
        raise RuntimeError('INVALID_RELEASE_ID')
    stage = base / 'staging' / deployment
    files = payload['files']
    if any('/' in name or '\\' in name or name.startswith('.') for name in files):
        raise RuntimeError('INVALID_FILE_NAME')
    actual = {p.name: digest(p) for p in stage.iterdir() if p.is_file() and not p.is_symlink()}
    if actual != files or len(list(stage.iterdir())) != len(files):
        raise RuntimeError('UPLOAD_HASH_MISMATCH')
    live = base / 'site'
    if not live.is_symlink() or not (live / 'updates/macos/arm64/appcast.xml').is_file():
        raise RuntimeError('EXISTING_MAC_SITE_REQUIRED')
    if base.resolve() not in live.resolve().parents:
        raise RuntimeError('LIVE_SNAPSHOT_OUTSIDE_RECORDREADY')
    feed = live / 'updates/windows/x64/release.json'
    if feed.exists():
        old = json.loads(base64.b64decode(json.loads(feed.read_text())['payload']))
        if int(old['version'].rsplit('.', 1)[1]) >= int(version.rsplit('.', 1)[1]):
            raise RuntimeError('WINDOWS_RELEASE_MUST_INCREASE')
    envelope = json.loads((stage / 'release.json').read_text())
    release = json.loads(base64.b64decode(envelope['payload']))
    name = f'RecordReady-{version}-x64.exe'
    if release['version'] != version or release['platform'] != 'win32' or release['arch'] != 'x64' or release['file']['name'] != name:
        raise RuntimeError('MANIFEST_MISMATCH')
    artifact = stage / name
    h = hashlib.sha512()
    with artifact.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    if artifact.stat().st_size != release['file']['size'] or base64.b64encode(h.digest()).decode() != release['file']['sha512']:
        raise RuntimeError('SIGNED_PAYLOAD_HASH_MISMATCH')
    immutable = base / 'releases/windows' / version
    already_promoted = immutable.exists()
    if already_promoted:
        retained = {p.name: digest(p) for p in immutable.iterdir() if p.is_file() and not p.is_symlink()}
        if retained != files or len(list(immutable.iterdir())) != len(files):
            raise RuntimeError('IMMUTABLE_VERSION_CHANGED')
    immutable.parent.mkdir(parents=True, exist_ok=True)
    # Prepare a new complete site snapshot before changing the live pointer.
    snapshot = base / 'snapshots' / deployment
    shutil.copytree(live.resolve(), snapshot, symlinks=True)
    update = snapshot / 'updates/windows/x64'
    update.mkdir(parents=True, exist_ok=True)
    page = snapshot / 'windows'
    page.mkdir(exist_ok=True)
    shutil.copyfile(stage / 'release.json', update / 'release.json')
    shutil.copyfile(stage / 'index.html', page / 'index.html')
    for filename in (name, name + '.blockmap'):
        (update / filename).symlink_to(immutable / filename)
    for filename in ('index.html', 'download.html'):
        path = snapshot / filename
        if path.exists():
            path.write_text(add_windows_link(path.read_text()), encoding='utf-8')
    for p in stage.iterdir():
        p.chmod(0o644)
    stage.chmod(0o755)
    for p in snapshot.rglob('*'):
        if not p.is_symlink():
            p.chmod(0o755 if p.is_dir() else 0o644)
    snapshot.chmod(0o755)
    if not already_promoted:
        stage.rename(immutable)
    pointer = base / ('site-next-' + deployment)
    pointer.symlink_to(Path('snapshots') / deployment, target_is_directory=True)
    os.replace(pointer, live)
    return version


if __name__ == '__main__':
    print(publish(Path('/srv/recordready'), json.load(sys.stdin)))
