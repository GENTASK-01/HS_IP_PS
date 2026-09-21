# HS_IP_PS — STEP-BY-STEP IMPLEMENTATION GUIDE
### Only specific, executable steps. Configured for the actual machine (v1.2.0).

**Machine constants (already verified on your system):**

| Tool | Path |
|---|---|
| MetaTrader 5 terminal | `C:\Program Files\Vantage International MT5\terminal64.exe` |
| MetaEditor compiler | `C:\Program Files\Vantage International MT5\metaeditor64.exe` |
| Python 3.14.7 | `C:\Python314\python.exe` |
| PowerShell 7.6.4 | `C:\Program Files\PowerShell\7\pwsh.exe` |
| Git 2.55 | `C:\Program Files\Git\cmd\git.exe` |
| WinRAR 7.23 | `C:\Program Files\WinRAR\Rar.exe` (console) + `WinRAR.exe` (GUI) |
| Project root | `E:\HS_IP_PS` (relocatable via `HSIPS_HOME`) |

> OpenSSL is **not required** (license encryption is self-contained).

---

## PHASE 0 — One-time environment variables (elevated PowerShell)

```powershell
[Environment]::SetEnvironmentVariable("HSIPS_HOME", "E:\HS_IP_PS", "Machine")
[Environment]::SetEnvironmentVariable("HSIPS_MT5_PATH", "C:\Program Files\Vantage International MT5", "Machine")
[Environment]::SetEnvironmentVariable("HSIPS_PYTHON", "C:\Python314\python.exe", "Machine")
[Environment]::SetEnvironmentVariable("HSIPS_GIT", "C:\Program Files\Git\cmd\git.exe", "Machine")
[Environment]::SetEnvironmentVariable("HSIPS_RAR", "C:\Program Files\WinRAR\Rar.exe", "Machine")
```

Verify `Rar.exe` exists (required only for **encrypted** archives):
```powershell
Test-Path "C:\Program Files\WinRAR\Rar.exe"   # True → encrypted RAR available
```

---

## PHASE 1 — Deploy the bundle & bootstrap

1. Copy the entire `HS_IP_PS_MASTER` bundle contents into `E:\HS_IP_PS` (folders `scripts\`, `templates\`, `bin\`, `config\` + docs).
2. Run as Administrator (creates folders, writes `config\hsips.json` with real paths, NTFS permissions, local Git):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\Initialize-HSIPSStructure.ps1
```
3. Confirm `E:\HS_IP_PS\config\hsips.json` shows the correct `metaeditor_exe`, `terminal_exe`, `tools.python`, `tools.git`, `tools.rar`.

> The bootstrap is idempotent and does **not** overwrite the bundled scripts (they ship as files, so no drift).

---

## PHASE 2 — Onboard a product (once per EA)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\New-HSIPSProduct.ps1 `
  -ProductCode "NEBULA_SCALPER" -ProductName "Nebula Scalper" -Version "1.0.0" `
  -EntryFile "NebulaScalper.mq5" -LicenseProfile "LIVE_SINGLE_ACCOUNT"
```

Copy source into `E:\HS_IP_PS\source_original\NEBULA_SCALPER\src`, then validate:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\Test-HSIPSSourceIntake.ps1 -ProductCode "NEBULA_SCALPER"
# expect: INTAKE PASSED
```

Optional obfuscation prefix (recommended):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\Set-HSIPSObfuscationPrefix.ps1 -ProductCode "NEBULA_SCALPER" -Prefix "NSX_"
```

Generate the product secret (once):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\New-HSIPSProductSecret.ps1 -ProductCode "NEBULA_SCALPER"
```

---

## PHASE 3 — Protected build (one command)

```cmd
E:\HS_IP_PS\bin\hsips-build.bat NEBULA_SCALPER
```

Expect: `HS_IP_PS BUILD COMPLETED SUCCESSFULLY`, 0 errors, 0 warnings.
Artifact: `E:\HS_IP_PS\build\NEBULA_SCALPER\<BUILD_ID>\binary\*.ex5`.

---

## PHASE 4 — Generate a customer license (offline)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\New-HSIPSLicense.ps1 `
  -ProductCode "NEBULA_SCALPER" -AccountLogin 7654321 -Server "Broker-Live" `
  -Profile "LIVE_SINGLE_ACCOUNT" -ExpiryDays 365
```

---

## PHASE 5 — Package the customer delivery

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\Invoke-HSIPSPackage.ps1 `
  -ProductCode "NEBULA_SCALPER" -CustomerName "JohnDoe" `
  -LicenseFiles "E:\HS_IP_PS\licenses\NEBULA_SCALPER\7654321_<stamp>.lic"
```
Replace `<stamp>` with the actual timestamp (list with `Get-ChildItem E:\HS_IP_PS\licenses\NEBULA_SCALPER\`).

Encrypted archive (RAR, requires `Rar.exe`): add `-CreateEncrypted` (prompts for password).

---

## PHASE 6 — Single-command full release (build + license + package)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\Invoke-HSIPSRelease.ps1 `
  -ProductCode "NEBULA_SCALPER" -CustomerName "JohnDoe" -AccountLogin 7654321 `
  -Server "Broker-Live" -Profile "LIVE_SINGLE_ACCOUNT" -ExpiryDays 365
```

---

## PHASE 7 — Verify before delivery (mandatory)

1. Install `.ex5` into `MQL5\Experts`, **no** license → expect `INIT_FAILED` + `HS_IP_PS: LICENSE INVALID`.
2. Place `.lic` in `MQL5\Files\HS_IP_PS` → expect `HS_IP_PS: LICENSE OK`.
3. Attach on a **different** account → expect `LICENSE INVALID`.
4. Confirm `package_manifest.json` and `CHECKSUMS.txt` contain **non-null** SHA-256 values.

---

## Git isolation (once)

Inside `E:\HS_IP_PS`, Git is initialized with **local** (repo-scoped) config — no `--global`, no remote:
```powershell
cd E:\HS_IP_PS
git status
git add config source_original\NEBULA_SCALPER
git commit -m "Add NEBULA_SCALPER"
```

## Backup (encrypted RAR)
```cmd
"C:\Program Files\WinRAR\Rar.exe" a -ep1 -m5 -hp"YOUR_PASSWORD" E:\HS_IP_PS\backup\HS_IP_PS_backup.rar E:\HS_IP_PS\source_original E:\HS_IP_PS\config E:\HS_IP_PS\keys E:\HS_IP_PS\templates E:\HS_IP_PS\scripts
```

## Secret rotation (on compromise)
1. Move/delete `keys\private\NEBULA_SCALPER_product_secret.bin`.
2. `New-HSIPSProductSecret.ps1` → `Invoke-HSIPSBuild.ps1` → re-issue `.lic` to all customers.
