"""Release validation and source/build receipts; never builds or runs WordNest.

prepare requires a clean build tree. Run Flutter separately, then record. Receipts
are integrity/provenance checks for a local build, not cryptographic attestations.
"""
from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import uuid
import zipfile

ROOT = Path(__file__).resolve().parent.parent
WINDOWS_RELEASE = Path('build/windows/x64/runner/Release')
ANDROID_APK = Path('build/app/outputs/flutter-apk/app-arm64-v8a-release.apk')
PREPARATION = Path('build/release-prepare.json')
RECEIPT = Path('build/release-receipt.json')
PRIVATE_ASSETS = {'cet4-personal.json', 'cet4-source.md'}
PUBLIC_ASSETS = {'assets/ECDICT-LICENSE.txt', 'assets/KYLEBING-LICENSE.txt',
                 'assets/cet4-kylebing.txt', 'assets/cet4-kylebing.provenance.json',
                 'assets/catalog-manifest.json'}
GENERATED_PARTS = {'.gradle', '.kotlin', '.dart_tool', 'build', 'ephemeral',
                   '.plugin_symlinks', '__pycache__'}
GENERATED_NAMES = {'local.properties', 'GeneratedPluginRegistrant.java',
                   'generated_plugin_registrant.cc', 'generated_plugin_registrant.h',
                   'generated_plugins.cmake'}


@dataclass(frozen=True)
class ReleaseVersion:
    name: str
    code: int

    @property
    def full(self) -> str:
        return f'{self.name}+{self.code}'

    @property
    def windows(self) -> str:
        return f'{self.name}.{self.code}'


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_version(root: Path) -> ReleaseVersion:
    text = (root / 'pubspec.yaml').read_text(encoding='utf-8')
    lines = re.findall(r'^version:\s*([^\n#]+)', text, re.M)
    if len(lines) != 1:
        raise ValueError('pubspec.yaml must contain exactly one top-level version.')
    value = lines[0].strip().strip('\"\'')
    match = re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)', value)
    if not match:
        raise ValueError('Stable packaging requires pubspec version MAJOR.MINOR.PATCH+BUILD.')
    if any(int(n) > 65535 for n in match.groups()):
        raise ValueError('Version components must fit Windows 16-bit version fields.')
    return ReleaseVersion('.'.join(match.groups()[:3]), int(match[4]))


def declared_assets(root: Path) -> list[str]:
    text = (root / 'pubspec.yaml').read_text(encoding='utf-8')
    assets = re.findall(r'^    - (assets/[^\s#]+)\s*$', text, re.M)
    if not assets or len(set(assets)) != len(assets):
        raise ValueError('Expected unique, explicit assets/ file entries in pubspec.yaml.')
    for name in assets:
        if '\\' in name or '..' in Path(name).parts or not (root / name).is_file():
            raise ValueError(f'Missing or unsafe declared asset: {name}')
    return sorted(assets)


def check_public_source(root: Path) -> None:
    assets = set(declared_assets(root))
    missing = PUBLIC_ASSETS - assets
    if missing:
        raise ValueError(f'Public build is missing declared licensed resources: {sorted(missing)}')
    for path in (root / 'assets').rglob('*'):
        if path.is_file() and forbidden_public_asset(path.name):
            raise ValueError(f'Private vocabulary asset remains in public source: {path.name}')


def forbidden_public_asset(name: str) -> bool:
    lower = Path(name).name.lower()
    # Jimmy URLs in catalog metadata are attribution, not redistributed vocabulary.
    return lower in PRIVATE_ASSETS or 'jimmy' in lower


def source_snapshot(root: Path) -> dict[str, str]:
    files = [root / 'pubspec.yaml', root / 'pubspec.lock']
    for directory in ('lib', 'assets', 'windows', 'android'):
        for path in (root / directory).rglob('*'):
            rel = path.relative_to(root)
            if any(part in GENERATED_PARTS for part in rel.parts) or path.name in GENERATED_NAMES:
                continue
            if path.is_symlink():
                raise ValueError(f'Source symlinks are refused: {rel}')
            if path.is_file():
                files.append(path)
    if any(not path.is_file() for path in files):
        raise ValueError('pubspec.yaml and pubspec.lock are required for a source receipt.')
    return {path.relative_to(root).as_posix(): sha(path) for path in sorted(files)}


def build_files(root: Path) -> list[Path]:
    release = root / WINDOWS_RELEASE
    required = [release / 'wordnest.exe', release / 'data/app.so', root / ANDROID_APK]
    if any(not path.is_file() for path in required):
        raise ValueError('Existing complete Windows Release bundle and release APK are required.')
    files = sorted(path for path in release.rglob('*') if path.is_file()) + [root / ANDROID_APK]
    if any(path.is_symlink() for path in files):
        raise ValueError('Build artifact symlinks are refused.')
    return files


def build_snapshot(root: Path) -> dict[str, str]:
    return {path.relative_to(root).as_posix(): sha(path) for path in build_files(root)}


def run_checked(argv: list[str]) -> str:
    """Only native executables with argument arrays; never a shell or batch runner."""
    if Path(argv[0]).suffix.lower() in {'.bat', '.cmd', '.ps1'}:
        raise ValueError('Batch/script command execution is not supported.')
    try:
        result = subprocess.run(argv, shell=False, check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        output = (error.stdout or b'').decode('utf-8', errors='replace')
        raise ValueError(f'{Path(argv[0]).name} failed with exit code {error.returncode}\n{output}') from error
    return result.stdout.decode('utf-8', errors='replace')


def native_tool(path: Path, expected_name: str) -> Path:
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or resolved.name.lower() != expected_name.lower():
        raise ValueError(f'Tool path must point to {expected_name}.')
    if any(c in str(resolved) for c in ('\"', '\r', '\n', '\x00')):
        raise ValueError('Tool path contains unsupported characters.')
    return resolved


def find_aapt2(explicit: Path | None = None, signer: Path | None = None) -> Path:
    if explicit is not None:
        return native_tool(explicit, 'aapt2.exe')
    candidates = []
    found = shutil.which('aapt2.exe')
    if found:
        candidates.append(Path(found))
    if signer:
        parent = signer.parent.parent if signer.suffix.lower() == '.jar' else signer.parent
        candidates.append(parent / 'aapt2.exe')
    for variable in ('ANDROID_SDK_ROOT', 'ANDROID_HOME'):
        base = os.environ.get(variable)
        if base:
            tools = Path(base) / 'build-tools'
            candidates.extend(sorted(tools.glob('*/aapt2.exe'), reverse=True))
    for candidate in candidates:
        if candidate.is_file():
            return native_tool(candidate, 'aapt2.exe')
    raise ValueError('aapt2.exe is required; pass --aapt2 or set ANDROID_SDK_ROOT.')


def apk_version_command(aapt2: Path, apk: Path) -> list[str]:
    return [str(native_tool(aapt2, 'aapt2.exe')), 'dump', 'badging', str(apk.resolve(strict=True))]


def parse_apk_version(badging: str, expected: ReleaseVersion) -> dict:
    packages = re.findall(r'^package: (.+)$', badging, re.M)
    if len(packages) != 1:
        raise ValueError('aapt2 must report exactly one APK package.')
    fields = dict(re.findall(r"(\w+)='([^']*)'", packages[0]))
    if fields.get('name') != 'io.wordnest.wordnest':
        raise ValueError('APK applicationId does not match io.wordnest.wordnest.')
    # Flutter split-per-ABI adds ABI offset 2000 to arm64-v8a versionCode.
    expected_code = 2000 + expected.code
    if fields.get('versionName') != expected.name or fields.get('versionCode') != str(expected_code):
        raise ValueError(f'APK version mismatch: {fields}; expected {expected.name} code {expected_code} (arm64 split). Rebuild, do not rename.')
    abis = re.findall(r"^native-code:\s*(.+)$", badging, re.M)
    if len(abis) != 1 or re.findall(r"'([^']+)'", abis[0]) != ['arm64-v8a']:
        raise ValueError('Canonical Android APK must contain only arm64-v8a native code.')
    return {'application_id': fields['name'], 'version_name': fields['versionName'],
            'version_code': int(fields['versionCode'])}


def windows_file_version(executable: Path) -> tuple[int, int, int, int]:
    """Read the numeric PE VERSIONINFO. On Windows uses version.dll; on other
    platforms falls back to the `pefile` parser. Install pefile
    (`pip install pefile`) to run this step on Linux/macOS."""
    with executable.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError('Windows runner is not a PE executable.')
    if os.name == 'nt':
        return _windows_file_version_native(executable)
    try:
        import pefile  # type: ignore
    except ImportError as error:
        raise ValueError(
            'Windows PE version validation on non-Windows requires pefile; '
            'install it with `pip install pefile` or run the record step on Windows.'
        ) from error
    pe = pefile.PE(str(executable), fast_load=True)
    try:
        if not hasattr(pe, 'VS_VERSIONINFO') or pe.VS_VERSIONINFO is None:
            raise ValueError('Windows runner has no VS_VERSIONINFO resource.')
        for info in pe.VS_VERSIONINFO:
            if not hasattr(info, 'FileVersionMS'):
                continue
            ms, ls = info.FileVersionMS, info.FileVersionLS
            version = (ms >> 16, ms & 0xffff, ls >> 16, ls & 0xffff)
            pms, pls = info.ProductVersionMS, info.ProductVersionLS
            product = (pms >> 16, pms & 0xffff, pls >> 16, pls & 0xffff)
            if version != product:
                raise ValueError('Windows file and product versions disagree.')
            return version
        raise ValueError('Windows runner has no fixed file version metadata.')
    finally:
        pe.close()


def _windows_file_version_native(executable: Path) -> tuple[int, int, int, int]:
    from ctypes import wintypes
    dll = ctypes.WinDLL('version.dll', use_last_error=True)
    dll.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    dll.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    dll.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    dll.GetFileVersionInfoW.restype = wintypes.BOOL
    dll.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR,
                                 ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.UINT)]
    dll.VerQueryValueW.restype = wintypes.BOOL
    handle = wintypes.DWORD()
    size = dll.GetFileVersionInfoSizeW(str(executable.resolve(strict=True)), ctypes.byref(handle))
    if not size:
        raise ValueError('Windows runner has no readable version metadata.')
    buffer = ctypes.create_string_buffer(size)
    if not dll.GetFileVersionInfoW(str(executable), 0, size, buffer):
        raise ValueError('Cannot read Windows runner version metadata.')
    pointer, length = ctypes.c_void_p(), wintypes.UINT()
    if not dll.VerQueryValueW(buffer, '\\', ctypes.byref(pointer), ctypes.byref(length)) or length.value < 52:
        raise ValueError('Windows runner has no fixed version metadata.')
    words = ctypes.cast(pointer, ctypes.POINTER(wintypes.DWORD * 13)).contents
    if words[0] != 0xFEEF04BD:
        raise ValueError('Invalid PE fixed version signature.')
    version = (words[2] >> 16, words[2] & 65535, words[3] >> 16, words[3] & 65535)
    product = (words[4] >> 16, words[4] & 65535, words[5] >> 16, words[5] & 65535)
    if version != product:
        raise ValueError('Windows file and product versions disagree.')
    return version


def validate_builds(root: Path, version: ReleaseVersion, aapt2: Path, public: bool) -> dict:
    build_files(root)
    windows = windows_file_version(root / WINDOWS_RELEASE / 'wordnest.exe')
    if '.'.join(map(str, windows)) != version.windows:
        raise ValueError(f'Windows runner version mismatch: {windows}; expected {version.windows}.')
    apk = root / ANDROID_APK
    android = parse_apk_version(run_checked(apk_version_command(aapt2, apk)), version)
    assets = declared_assets(root)
    if public:
        check_public_source(root)
    with zipfile.ZipFile(apk) as archive:
        if archive.testzip() is not None or 'AndroidManifest.xml' not in archive.namelist():
            raise ValueError('APK CRC or AndroidManifest.xml validation failed.')
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError('APK contains duplicate entries.')
        for name in assets:
            win_asset = root / WINDOWS_RELEASE / 'data/flutter_assets' / name
            entry = 'assets/flutter_assets/' + name
            if not win_asset.is_file() or sha(win_asset) != sha(root / name):
                raise ValueError(f'Windows bundled asset does not match current source: {name}')
            if entry not in archive.namelist() or hashlib.sha256(archive.read(entry)).hexdigest() != sha(root / name):
                raise ValueError(f'APK bundled asset does not match current source: {name}')
        if public:
            for name in archive.namelist():
                if name.startswith('assets/flutter_assets/assets/') and forbidden_public_asset(name):
                    raise ValueError(f'Private vocabulary asset in public APK: {name}')
            for path in (root / WINDOWS_RELEASE / 'data/flutter_assets/assets').rglob('*'):
                if path.is_file() and forbidden_public_asset(path.name):
                    raise ValueError(f'Private vocabulary asset in public Windows bundle: {path.name}')
    return {'windows_file_version': version.windows, 'android': android,
            'declared_assets_verified': assets, 'public_resource_checks': public}


def apksigner_command(signer: Path, apk: Path) -> list[str]:
    signer = signer.resolve(strict=True)
    if signer.name.lower() == 'apksigner.bat':
        jar = (signer.parent / 'lib/apksigner.jar').resolve(strict=True)
    elif signer.suffix.lower() == '.jar':
        jar = signer
    else:
        raise ValueError('Pass Android SDK apksigner.bat or apksigner.jar.')
    java_home = os.environ.get('JAVA_HOME')
    java = Path(java_home) / 'bin/java.exe' if java_home else None
    if java is None or not java.is_file():
        found = shutil.which('java.exe') or shutil.which('java')
        if not found:
            raise ValueError('Java not found; set JAVA_HOME or add Java to PATH.')
        java = Path(found)
    return [str(java.resolve(strict=True)), '-jar', str(jar),
            'verify', '--verbose', '--print-certs', str(apk.resolve(strict=True))]


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix='.' + path.name, suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, indent=2, sort_keys=True, ensure_ascii=False)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def prepare(root: Path, public: bool = False) -> dict:
    root = root.resolve(strict=True)
    version = read_version(root)
    if public:
        check_public_source(root)
    release = root / WINDOWS_RELEASE
    if (root / ANDROID_APK).exists() or any(path.is_file() for path in release.rglob('*')):
        raise ValueError('Stale build artifacts exist. Run flutter clean separately before prepare.')
    value = {'format': 1, 'kind': 'wordnest-release-preparation', 'project_root': str(root),
             'version': version.full, 'public': public, 'prepared_ns': time.time_ns(),
             'preparation_id': uuid.uuid4().hex, 'source_sha256': source_snapshot(root)}
    write_json(root / PREPARATION, value)
    # A prior receipt must not authorize this new build attempt.
    (root / RECEIPT).unlink(missing_ok=True)
    return value


def read_preparation(root: Path, public: bool) -> dict:
    value = json.loads((root / PREPARATION).read_text(encoding='utf-8'))
    if (value.get('format') != 1 or value.get('kind') != 'wordnest-release-preparation'
            or value.get('project_root') != str(root) or value.get('public') is not public
            or value.get('version') != read_version(root).full):
        raise ValueError('Preparation root, mode, or version mismatch; prepare and rebuild.')
    if value.get('source_sha256') != source_snapshot(root):
        raise ValueError('Release sources changed after prepare; prepare and rebuild.')
    return value


def record(root: Path, aapt2: Path, public: bool = False) -> dict:
    root = root.resolve(strict=True)
    prepared = read_preparation(root, public)
    # Only true build outputs prove the build ran after prepare; static engine
    # files and bundled assets are copied with preserved mtimes and their
    # content is verified against current source hashes in validate_builds.
    release = root / WINDOWS_RELEASE
    for path in [release / 'wordnest.exe', release / 'data/app.so', root / ANDROID_APK]:
        if path.stat().st_mtime_ns + 2_000_000_000 < prepared['prepared_ns']:
            raise ValueError(f'Build file predates preparation: {path}')
    before = build_snapshot(root)
    validation = validate_builds(root, read_version(root), aapt2, public)
    if before != build_snapshot(root):
        raise ValueError('Build inputs changed while recording.')
    read_preparation(root, public)
    value = {'format': 1, 'kind': 'wordnest-release-receipt', 'project_root': str(root),
             'version': read_version(root).full, 'public': public,
             'preparation_id': prepared['preparation_id'], 'source_sha256': prepared['source_sha256'],
             'build_sha256': before, 'validation': validation,
             'limitations': ['Local integrity receipt, not a signed build attestation.',
                             'Flutter commands run separately; helper does not claim build/test invocation.']}
    write_json(root / RECEIPT, value)
    return value


def validate_receipt(root: Path, public: bool) -> dict:
    root = root.resolve(strict=True)
    prepared = read_preparation(root, public)
    value = json.loads((root / RECEIPT).read_text(encoding='utf-8'))
    if (value.get('format') != 1 or value.get('kind') != 'wordnest-release-receipt'
            or value.get('project_root') != str(root) or value.get('version') != read_version(root).full
            or value.get('public') is not public or value.get('preparation_id') != prepared['preparation_id']
            or value.get('source_sha256') != prepared['source_sha256']):
        raise ValueError('Release receipt root, mode, source, or version mismatch; record a fresh build.')
    if value.get('build_sha256') != build_snapshot(root):
        raise ValueError('Build artifacts differ from validated receipt; do not reuse stale or mixed builds.')
    return value


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'record'))
    parser.add_argument('--project-root', type=Path, default=ROOT)
    parser.add_argument('--public', action='store_true')
    parser.add_argument('--aapt2', type=Path, help='Android SDK build-tools aapt2.exe (required for record)')
    opts = parser.parse_args(argv)
    try:
        if opts.action == 'prepare':
            value = prepare(opts.project_root, opts.public)
            target = opts.project_root.resolve() / PREPARATION
        else:
            value = record(opts.project_root, find_aapt2(opts.aapt2), opts.public)
            target = opts.project_root.resolve() / RECEIPT
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Release validation failed: {error}\n')
    print(f'{opts.action}: {value["version"]}; {target}')
    print('No Flutter build, application, installer, Git, or upload executed.')


if __name__ == '__main__':
    main()
