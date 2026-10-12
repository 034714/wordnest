"""Validate and package existing builds only; never run Flutter/app/installer."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))
from release_helpers import (ANDROID_APK, WINDOWS_RELEASE, apksigner_command, build_files,
                             build_snapshot, find_aapt2, native_tool, read_version,
                             run_checked, sha, validate_builds, validate_receipt)


STABLE_NAMES = ('WordNest-windows-x64-setup.exe', 'WordNest-windows-x64-portable.zip',
                'WordNest-android.apk')


def find_compiler(explicit: Path | None) -> Path:
    if explicit is not None:
        return native_tool(explicit, 'ISCC.exe')
    candidates = [shutil.which('ISCC.exe')]
    for env in ('LOCALAPPDATA', 'ProgramFiles', 'ProgramFiles(x86)'):
        base = os.environ.get(env)
        if base:
            folder = 'Programs/Inno Setup 6' if env == 'LOCALAPPDATA' else 'Inno Setup 6'
            candidates.append(Path(base) / folder / 'ISCC.exe')
    for path in candidates:
        if path and Path(path).is_file():
            return native_tool(Path(path), 'ISCC.exe')
    raise ValueError('ISCC.exe not found; install Inno Setup 6 or pass --iscc.')


def supplemental_files(root: Path, public: bool) -> dict[str, Path]:
    extras = {'WordNest.ico': root / 'assets/tray.ico', 'USAGE.txt': HERE / 'USAGE.txt',
              'licenses/ECDICT-LICENSE.txt': root / 'assets/ECDICT-LICENSE.txt'}
    if public:
        extras.update({
            'licenses/KYLEBING-LICENSE.txt': root / 'assets/KYLEBING-LICENSE.txt',
            'licenses/cet4-kylebing.provenance.json': root / 'assets/cet4-kylebing.provenance.json',
            'licenses/catalog-manifest.json': root / 'assets/catalog-manifest.json',
            'licenses/PUBLIC-RELEASE-NOTES.md': root / 'docs/public-release-notes.md',
        })
    elif (root / 'assets/KYLEBING-LICENSE.txt').is_file():
        extras['licenses/KYLEBING-LICENSE.txt'] = root / 'assets/KYLEBING-LICENSE.txt'
    for name in ('LICENSE', 'LICENSE.txt', 'NOTICE', 'NOTICE.txt', 'THIRD_PARTY_NOTICES.md',
                 'THIRD-PARTY-NOTICES.md'):
        if (root / name).is_file():
            extras['licenses/' + name] = root / name
    for name, source in extras.items():
        if not source.is_file():
            raise ValueError(f'Missing supplemental packaging file: {name} ({source})')
    return extras


def expected_payload(root: Path, public: bool) -> tuple[dict[str, Path], list[str]]:
    release = root / WINDOWS_RELEASE
    inputs = [path for path in build_files(root) if path != root / ANDROID_APK]
    payload = {path.relative_to(release).as_posix(): path for path in inputs
               if path.suffix.lower() not in {'.lib', '.exp'}}
    extras = supplemental_files(root, public)
    # Windows destinations are case insensitive, unlike Python dict keys.
    names = list(payload) + list(extras)
    if len({name.casefold() for name in names}) != len(names):
        raise ValueError('Supplemental files collide with Windows Release payload.')
    payload.update(extras)
    excluded = [path.relative_to(release).as_posix() for path in inputs
                if path.suffix.lower() in {'.lib', '.exp'}]
    return payload, excluded


def inno_path(path: Path) -> str:
    value = str(path.resolve(strict=True))
    if any(character in value for character in ('\"', '\r', '\n', '\x00', '{', '}')):
        raise ValueError('Inno source path contains unsupported quoting/constant characters.')
    return value


def write_supplemental_include(path: Path, extras: dict[str, Path]) -> None:
    lines = []
    for name, source in sorted(extras.items()):
        relative = Path(name)
        destination = '{app}'
        if relative.parent != Path('.'):
            destination += '\\' + str(relative.parent).replace('/', '\\')
        lines.append(f'Source: "{inno_path(source)}"; DestDir: "{destination}"; '
                     f'DestName: "{relative.name}"; Flags: ignoreversion\n')
    path.write_text(''.join(lines), encoding='utf-8-sig')


def compiler_command(compiler: Path, root: Path, output: Path, version,
                     include: Path, public: bool) -> list[str]:
    for path in (root, output, include):
        inno_path(path)
    script = HERE / ('WordNest-public.iss' if public else 'WordNest.iss')
    return [str(native_tool(compiler, 'ISCC.exe')), '/DProjectRoot=' + str(root),
            '/DVersion=' + version.name, '/DWindowsVersion=' + version.windows,
            '/DOutputRoot=' + str(output), '/DSupplementalFiles=' + str(include), str(script)]


def validate_compile_coverage(log: str, expected: dict[str, Path]) -> None:
    compressed = [Path(line.strip().split('Compressing: ', 1)[1]).resolve()
                  for line in log.splitlines() if 'Compressing: ' in line]
    # Counter also detects accidental duplicate sources, not just missing entries.
    if Counter(os.path.normcase(str(path)) for path in compressed) != Counter(
            os.path.normcase(str(path.resolve())) for path in expected.values()):
        raise ValueError('Compiler compressed source set differs from expected payload.')
    if 'warning:' in log.lower():
        raise ValueError('Compiler reported a warning; packaging refused.')


def make_portable(path: Path, prefix: str, expected: dict[str, Path]) -> None:
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, source in sorted(expected.items()):
            info = zipfile.ZipInfo(prefix + name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, source.read_bytes(), compresslevel=9)
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != {prefix + name for name in expected}:
            raise ValueError('Portable ZIP CRC or entry set validation failed.')
        for name, source in expected.items():
            if hashlib.sha256(archive.read(prefix + name)).hexdigest() != sha(source):
                raise ValueError(f'Portable ZIP entry hash mismatch: {name}')


def artifact_names(version, stable: bool) -> list[str]:
    return list(STABLE_NAMES)


def previous_report(output: Path, root: Path, version, public: bool, stable: bool,
                    payload: list[dict], receipt: dict) -> dict:
    report = json.loads((output / 'packaging-report.json').read_text(encoding='utf-8'))
    if (report.get('project_root') != str(root) or report.get('version') != version.name
            or report.get('pubspec_version') != version.full or report.get('public') is not public
            or report.get('stable_aliases') is not stable or report.get('payload') != payload
            or report.get('receipt_build_sha256') != receipt['build_sha256']):
        raise ValueError('Prior report does not match current root/version/payload/receipt; full packaging required.')
    deliverables = report.get('deliverables', [])
    names = artifact_names(version, stable)
    if len(deliverables) != len(names) or {Path(item['path']).name for item in deliverables} != set(names):
        raise ValueError('Prior report artifact set does not match requested packaging mode.')
    for item in deliverables:
        path = output / Path(item['path']).name
        if str(path) != item['path'] or path.stat().st_size != item['bytes'] or sha(path) != item['sha256']:
            raise ValueError(f'Prior deliverable differs from its report: {path}')
    return report


def package_release(opts) -> dict:
    root = opts.project_root.resolve(strict=True)
    output = (opts.output_dir or root.parent).resolve()
    release = root / WINDOWS_RELEASE
    if output == root or output == root / 'build' or root / 'build' in output.parents:
        raise ValueError('Output directory must not overwrite project root or build inputs.')
    if opts.stable_aliases:
        raise ValueError('Canonical fixed filenames are emitted by default; do not use --stable-aliases.')
    version = read_version(root)
    receipt = validate_receipt(root, opts.public)
    aapt2 = find_aapt2(opts.aapt2, opts.apksigner)
    validation = validate_builds(root, version, aapt2, opts.public)
    compiler = find_compiler(opts.iscc)
    expected, excluded = expected_payload(root, opts.public)
    before = build_snapshot(root)
    input_hashes = {name: sha(path) for name, path in expected.items()}
    payload = [{'path': name, 'bytes': path.stat().st_size, 'sha256': input_hashes[name]}
               for name, path in sorted(expected.items())]
    previous = None
    if opts.setup_only:
        previous = previous_report(output, root, version, opts.public, opts.stable_aliases, payload, receipt)
    output.mkdir(parents=True, exist_ok=True)
    names = artifact_names(version, opts.stable_aliases)
    with tempfile.TemporaryDirectory(prefix='.wordnest-package-', dir=output) as directory:
        stage = Path(directory)
        include = stage / 'supplemental-files.iss'
        write_supplemental_include(include, supplemental_files(root, opts.public))
        log = run_checked(compiler_command(compiler, root, stage, version, include, opts.public))
        validate_compile_coverage(log, expected)
        (stage / 'windows-installer-compile.log').write_text(log, encoding='utf-8')
        setup = stage / names[0]
        if not setup.is_file():
            raise ValueError('Compiler did not produce the requested versioned installer.')
        with setup.open('rb') as stream:
            if stream.read(2) != b'MZ':
                raise ValueError('Installer is not a PE executable.')
        portable, android = stage / names[1], stage / names[2]
        if opts.setup_only:
            shutil.copyfile(output / names[1], portable)
            shutil.copyfile(output / names[2], android)
        else:
            make_portable(portable, f'WordNest-{version.name}-windows-x64/', expected)
            shutil.copyfile(root / ANDROID_APK, android)
        if sha(android) != sha(root / ANDROID_APK):
            raise ValueError('APK output differs from validated build input.')
        signature = 'not independently verified; no signing command executed'
        debug_signed = None
        if opts.apksigner:
            certificate_log = run_checked(apksigner_command(opts.apksigner, android))
            if 'Verifies' not in certificate_log:
                raise ValueError('apksigner did not confirm APK verification.')
            (stage / 'android-signature-verification.txt').write_text(certificate_log, encoding='utf-8')
            debug_signed = 'CN=Android Debug' in certificate_log
            signature = 'apksigner verify passed; ' + ('Android Debug test certificate' if debug_signed else 'see certificate log')
        if before != build_snapshot(root) or input_hashes != {name: sha(path) for name, path in expected.items()}:
            raise ValueError('Build or supplemental inputs changed during packaging.')
        validate_receipt(root, opts.public)
        if previous:
            previous_report(output, root, version, opts.public, opts.stable_aliases, payload, receipt)
        if opts.stable_aliases:
            for source, name in zip((setup, portable, android), STABLE_NAMES):
                shutil.copyfile(source, stage / name)
                if sha(source) != sha(stage / name):
                    raise ValueError('Stable alias copy differs from versioned artifact.')
        deliverables = [{'path': str(output / name), 'bytes': (stage / name).stat().st_size,
                         'sha256': sha(stage / name)} for name in names]
        (stage / 'SHA256SUMS').write_text(''.join(f"{item['sha256']}  {Path(item['path']).name}\n"
                                               for item in deliverables), encoding='ascii')
        limitations = ['No installer/app execution or clean-machine runtime test.',
                       'No Authenticode verification or signing performed.',
                       'Local source/build receipt is not a signed provenance attestation.',
                       'Build commands and Flutter tests run separately, not by this script.']
        if debug_signed is True:
            limitations.append('Android APK uses Android Debug test signing; not production-key signing.')
        elif debug_signed is None:
            limitations.append('APK signature and certificate were not independently verified in this run.')
        report = {
            'format': 2, 'project_root': str(root), 'output_root': str(output),
            'version': version.name, 'build_number': version.code, 'pubspec_version': version.full,
            'public': opts.public, 'stable_aliases': opts.stable_aliases, 'compiler': str(compiler),
            'compile_exit_code': 0, 'compile_warnings': 0, 'setup_only': opts.setup_only,
            'release_file_count': sum(1 for path in expected.values() if release in path.parents),
            'excluded_files': excluded, 'build_validation': validation,
            'receipt_build_sha256': receipt['build_sha256'],
            'installer_compiler_input_coverage': 'exact source multiset, including all supplements, matched compiler log',
            'installer_extract_or_execute_test': 'not performed; compiler-based coverage only',
            'installer_languages': ['chinesesimplified (default)', 'english (selectable)'],
            'portable_entries': len(expected),
            'portable_validation': 'preserved hash-verified prior artifact' if previous else 'exact entry set, CRC and per-entry SHA256 passed',
            'apk_validation': 'aapt2 package/versionName/versionCode, CRC, manifest, bundled assets and byte-identical copy passed',
            'apk_signature_validation': signature, 'apk_debug_signed': debug_signed,
            'source_build_artifacts_unchanged': True, 'payload': payload, 'deliverables': deliverables,
            'limitations': limitations,
        }
        (stage / 'packaging-report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        # Publish only validated outputs. Report is replaced last as the completion marker.
        preserve = {names[1], names[2]}
        if opts.stable_aliases:
            preserve.update(STABLE_NAMES[1:])
        for name in names:
            if not opts.setup_only or name not in preserve:
                os.replace(stage / name, output / name)
        for name in ('windows-installer-compile.log', 'android-signature-verification.txt', 'SHA256SUMS', 'packaging-report.json'):
            if (stage / name).is_file():
                os.replace(stage / name, output / name)
        if not opts.apksigner:
            (output / 'android-signature-verification.txt').unlink(missing_ok=True)
    return report


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, default=ROOT, help='Private or sanitized public source root')
    parser.add_argument('--output-dir', type=Path, help='Defaults to selected project parent (local sh folder)')
    parser.add_argument('--public', action='store_true', help='Require licensed public source and bundled assets')
    parser.add_argument('--stable-aliases', action='store_true', help='Also produce fixed-name GitHub latest/download assets (public only)')
    parser.add_argument('--iscc', type=Path)
    parser.add_argument('--aapt2', type=Path, help='Android SDK build-tools aapt2.exe for required APK version verification')
    parser.add_argument('--apksigner', type=Path, help='Optional SDK apksigner.bat or jar; invoked directly through Java')
    parser.add_argument('--setup-only', action='store_true', help='Recompile only setup; require identical version, receipt and prior artifacts')
    opts = parser.parse_args(argv)
    try:
        report = package_release(opts)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Packaging failed: {error}\n')
    print(json.dumps(report['deliverables'], indent=2))
    print('No Flutter build, application, installer, Git, or upload executed.')


if __name__ == '__main__':
    main()
