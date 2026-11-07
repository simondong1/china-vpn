import hashlib
import json
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'out'
ASSETS = OUT / 'windows-assets'
XRAY_VERSION = 'v26.10.21'
ARCHIVE = OUT / 'Xray-windows-64.zip'


def verify_xray_archive():
    if not ARCHIVE.exists():
        subprocess.run(['gh', 'release', 'download', XRAY_VERSION, '--repo', 'XTLS/Xray-core',
                        '--pattern', ARCHIVE.name, '--dir', str(OUT)], check=True)
    release = json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/XTLS/Xray-core/releases/tags/{XRAY_VERSION}'], text=True, encoding='utf-8'))
    asset = next(item for item in release['assets'] if item['name'] == ARCHIVE.name)
    expected = asset.get('digest')
    if not expected:
        raise RuntimeError('GitHub did not provide a release SHA-256 digest for the Xray archive')
    digest = hashlib.sha256()
    with ARCHIVE.open('rb') as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b''):
            digest.update(chunk)
    if expected != 'sha256:' + digest.hexdigest():
        raise RuntimeError('The Xray archive SHA-256 does not match the GitHub release')


def prepare_assets():
    required = [OUT / 'vpn-link.txt', OUT / 'vpn-hong-kong.vless', OUT / 'hk-control.json']
    missing = [path.name for path in required if not path.is_file()]
    if missing:
        raise RuntimeError('Missing private build inputs in out/: ' + ', '.join(missing))
    control = json.loads(required[2].read_text(encoding='utf-8'))
    if not control.get('url', '').startswith('https://') or not control.get('token'):
        raise RuntimeError('Hong Kong controller settings are invalid')
    ASSETS.mkdir(exist_ok=True)
    (ASSETS / 'oregon.vless').write_text(required[0].read_text(encoding='utf-8').strip() + '\n', encoding='utf-8')
    (ASSETS / 'hong-kong.vless').write_text(required[1].read_text(encoding='utf-8').strip() + '\n', encoding='utf-8')
    shutil.copyfile(required[2], ASSETS / 'hk-control.json')
    with zipfile.ZipFile(ARCHIVE) as archive:
        names = {Path(name).name: name for name in archive.namelist()}
        for name in ('xray.exe', 'geoip.dat', 'geosite.dat', 'LICENSE'):
            if name not in names:
                raise RuntimeError(f'The verified Xray archive is missing {name}')
            with archive.open(names[name]) as source, (ASSETS / name).open('wb') as destination:
                shutil.copyfileobj(source, destination)
    icon = Image.open(ROOT / 'XrayVPN' / 'XrayVPN' / 'Assets.xcassets' / 'AppIcon.appiconset' / 'AppIcon-256.png')
    icon.save(OUT / 'DongVPN.ico', format='ICO', sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])


def build():
    dist = OUT / 'dongvpn-release'
    command = [sys.executable, '-m', 'PyInstaller', '--clean', '--onefile', '--noconsole',
               '--name', 'DongVPN', '--icon', str(OUT / 'DongVPN.ico'), '--distpath', str(dist),
               '--workpath', str(OUT / 'pyinstaller-work'), '--specpath', str(OUT)]
    for filename in ('oregon.vless', 'hong-kong.vless', 'hk-control.json', 'xray.exe',
                     'geoip.dat', 'geosite.dat', 'LICENSE'):
        command.extend(['--add-data', f'{ASSETS / filename};.'])
    command.append(str(ROOT / 'Windows' / 'DongVPN.py'))
    subprocess.run(command, check=True)


if __name__ == '__main__':
    verify_xray_archive()
    prepare_assets()
    build()
    print('Built out/dongvpn-release/DongVPN.exe with verified Xray and private server profiles.')
