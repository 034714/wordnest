# WordNest 0.3.3 public-source preparation

This update includes the current local-first learning, notebook and appearance changes. Library alphabetical and note-first sorting now preserve source order for equal keys. Version metadata is aligned to `0.3.3+6`. Release upload and native signing verification are separate steps; prepared update-feed URLs are not evidence that assets have been uploaded.

This is a sanitized source export, not a published release or a verified native build. The owner confirmed GitHub account `034714` and the proposed new public repository `034714/wordnest`; its name was available when checked. No repository creation or upload has been performed by the exporter.

## Public content and rights

- Empty databases start with the licensed KyleBing CET4 book. Existing databases are not reset or overwritten. The self-authored demo remains available as test data.
- The offline dictionary is the ECDICT subset. Its MIT notice and attribution remain in `assets/ECDICT-LICENSE.txt` and the application's license registry. That MIT license applies to the dictionary, not automatically to WordNest application code.
- No application license has been selected by the owner. All rights remain reserved for application code and original demo content unless the owner grants a license. Public visibility alone does not grant redistribution rights.
- Personal vocabulary assets, their provenance metadata, external vocabulary fixtures, local databases, logs, caches, private session/audit directories, signing keys, local SDK configuration and personal build artifacts are not exported.
- Original CET4 source (external link only): [Jimmy-Library / Jimmy-Grammar vocabulary JSON](https://github.com/Jimmy-Library/Jimmy-Grammar/blob/main/wordbooks/大学/四级/386871_英语四级你还在背单词吗？.json). The owner authorized publication, but the third-party source's redistribution license has not been confirmed. The public export links to that source rather than copying its vocabulary or personal provenance metadata; users must assess the applicable rights before importing or redistributing it.
- Parser and SQLite large-import tests use newly generated original data: 10 chapters, 2,331 ordered memberships and 2,329 distinct synthetic identifiers. No tests are broadly skipped; the existing Windows-only SQLite platform gate remains.

## Reproduce the source export

From the private project, run `python packaging/export_public.py`. The default destination is the sibling directory `wordnest-public`. Use `--destination` for a different fresh directory. An existing destination is refused by default. `--refresh` replaces an existing export only if its complete file/directory set and every file hash still match the prior exporter manifest; any user edits, added files, caches, symlinks or directories cause refusal. The old directory is retained until the replacement succeeds. Run refresh only after ongoing parent builds and documentation capture have finished. The exporter never edits the local application's source. The exporter includes exactly three allowlisted release PNGs from `docs/screenshots`. The exporter checks expected transforms, asset presence and private path/reference exclusions, then records relative file paths and SHA-256 hashes in `public-source-manifest.json`.

This manifest verifies the export's bytes, not Flutter compilation, the absence of every possible secret, or dependency licensing. Review the entire exported tree before publishing. A reviewed allowlist of receipt, packaging and smoke-test tools is included; build outputs and private signing material are not included.

## Build and test from the public tree only

Requirements match the checked-in dependencies: Dart SDK satisfying `^3.13.5`, Flutter satisfying the lockfile's `>=3.44.0`, and platform development tools. Run these commands inside the exported directory, not inside the private project:

```text
flutter pub get
flutter analyze
flutter test
flutter build windows --release
flutter build apk --release --split-per-abi
```

Windows builds need Visual Studio's Desktop development with C++ workload and the Windows SDK. Android builds need Java 17, Android SDK/NDK versions requested by Flutter, network access for dependencies, and compatibility with the pinned Gradle 9.3.1 / Android Gradle plugin 9.1.0 / Kotlin 2.4.0 configuration. `android/local.properties`, Windows ephemeral files and plugin registrants are generated locally by Flutter and must not be copied from the private build.

The Android release signing configuration is managed separately. Never commit keys or credentials; verify the final APK certificate before distribution. No private signing material is part of this source export. Windows artifacts are not code-signed by this export.

The source retains Android application ID `io.wordnest.wordnest` and version `0.3.3+6`; MSIX metadata is aligned to `0.3.3.0`. Replacing an existing installation with the same ID can reuse its local learning data, and Android upgrades additionally require a matching signing certificate. Back up user data first. This source is not intended to erase or sanitize an existing user's database.

The web scaffold is retained, but native-only features mean web functionality is not asserted here. Native build/test verification is still required after exporting.

## Updates and release artifacts

`update-feed-android.template.json` and `update-feed-windows.template.json` are deliberately nonfunctional templates. Their `downloadUrl` values are placeholders, not real links. Replace them with actual public HTTPS artifact URLs only after the appropriate platform build has been independently verified and uploaded. Serve separate feeds matching each platform. The application offers bundled platform-specific GitHub update feeds by default; users can select a custom source or explicitly disable updates.

Never upload the existing personal portable build, snapshots, installers or APKs. They may embed private vocabulary even if source assets were subsequently removed. Build public binaries from the fresh sanitized project and inspect the bundled assets. GitHub repository creation and publication remain pending parent confirmation. Prepared screenshots are included under `docs/screenshots`; they illustrate UI states, not proof that public binaries have been built or tested.
