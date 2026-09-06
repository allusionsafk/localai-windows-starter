# Source and installer provenance

`source/` is the editable 0.4.0-dev development source. The historical transport parts, Apply scripts, release scripts, certification inputs and workflows remain unchanged.

To reproduce the original final 0.3.2 source, from the repository root run:

```powershell
.\adaptive-media\Reconstruct-0.3.2.ps1 -Destination "$PWD\adaptive-media\.artifacts\baseline-new"
```

The destination must not exist, and its parent must exist. Reconstruction checks the five-part archive SHA-256 before inspecting or extracting it, validates all archive entry names, and applies the exact nine-patch order used by the historical candidate workflow. Failure leaves any partial new destination for inspection; it never overwrites an existing destination. No build, install or publication is performed. `BASELINE-0.3.2-MANIFEST.json` records the archive digest, ordered patch/input digests and all 25 reconstructed file digests. The destination receives the same manifest. Build output is excluded because reconstruction does not build.

Verified on Windows PowerShell 5.1 and PowerShell 7: fresh reconstructions produced identical 25-file manifests. Both runtimes passed `tests/Test-Packaging.ps1` and `tests/Test-Reconstruction.ps1`. The latter uses hashed hostile ZIP fixtures to check traversal, absolute/drive paths, alternate data streams, reserved names and Windows filename normalization. The digest tests exercise missing/malformed/mismatching and valid SHA-256 values.

The development build command is `source/scripts/Build-Dev.ps1 -Clean -SmokeTest`. It uses a fresh smoke AppId, removes shell registration and legacy deletion sections from the smoke installer, disables dependency and shortcut tasks, installs into a fresh temporary directory, runs installed tests, reinstalls as an upgrade, uninstalls, and checks an unknown settings sentinel remains byte-identical. This tests installer preservation of user-created files; application settings migration is covered separately by app tests. Failed assertions attempt isolated uninstallation before removing the temporary directory. No production AppId registration or existing settings are intentionally changed.

The final installer has an exact versioned path, an adjacent `.sha256.txt`, and `dist/build-provenance.json` containing SHA-256, byte length and UTC build time. These identify the actual compiled bytes; rebuilding may produce another digest. Distribution or certification must use those exact bytes and their matching digest. This development workflow does not publish, tag or replace historical certified artifacts.

Packaging safety tests do not execute dependency installers. The MPV provisioner requires a valid GitHub SHA-256 digest and matching download before execution. Downloads and WinGet capture files live in unique temporary directories, helpers start hidden, and failures are logged and displayed with the log location. Live network provisioning and visible no-flash behavior still need a controlled manual check. Full development build/smoke verification is run after the concurrent application edits finish.
