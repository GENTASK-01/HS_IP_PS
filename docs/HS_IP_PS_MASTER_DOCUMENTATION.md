# HS_IP_PS — COMPLETE MASTER DOCUMENTATION
### HIGH SECURITY IP PROTECTION SYSTEM — for MQL5 Expert Advisors
**Consolidated 13 parts · corrected, refactored & hardened — v1.2.0**

> Authoritative code lives in the bundled `scripts/`, `templates/`, `bin/`, `config/` folders.
> Environment: MT5 @ `C:\Program Files\Vantage International MT5`, Python 3.14.7, WinRAR 7.23,
> project root `E:\HS_IP_PS` (relocatable via `HSIPS_HOME`).

---

## 1. PROJECT IDENTITY & SECURITY POSITION

`HS_IP_PS` — a fully automated, institutional-grade pipeline that transforms unprotected MQL5 EA source into a hardened, licensed, packaged `.ex5` product.

**Honest guarantee:** no protection is unbreakable. The goal is to raise the cost of cracking above the value of casual theft, block simple redistribution, and enforce license terms technically.

**Operating constraints (enforced):**
- Developer OS: Windows 10 Pro (64-bit). Build tooling on `C:`; **all** project data under the project root (default `E:\HS_IP_PS`).
- Customer OS: Windows 10+ and macOS 26 Tahoe+. → **Pure MQL5 runtime**, no DLL, no paid server, offline-first licensing.
- MetaTrader/MetaEditor Build 6090+.
- Free tooling only.

**Toolchain (final):**
| Tool | Version | Path |
|---|---|---|
| MetaTrader 5 | Build 6090 | `C:\Program Files\Vantage International MT5\terminal64.exe` |
| MetaEditor 5 | Build 6090 | `C:\Program Files\Vantage International MT5\metaeditor64.exe` |
| Python | 3.14.7 | `C:\Python314\python.exe` |
| PowerShell | 7.6.4 | `C:\Program Files\PowerShell\7\pwsh.exe` |
| Git | 2.55.0 | `C:\Program Files\Git\cmd\git.exe` |
| WinRAR | 7.23 | `C:\Program Files\WinRAR\Rar.exe` (console) |

> OpenSSL is **not required** — license encryption is self-contained (see §5).

---

## 2. ARCHITECTURE & 10-LAYER PROTECTION MODEL

```
Developer → HS_IP_PS Orchestrator (project root) → Customer package (.zip/.rar + .lic)
```

| Layer | Protection |
|---|---|
| L0 | Machine hardening: BitLocker, NTFS ACLs, local-only Git |
| L1 | Source isolation: `source_original` read-only, `source_work` disposable |
| L2 | Sanitization: strip comments, author/link/copyright metadata, debug prints |
| L3 | Identifier obfuscation (prefix mode, e.g. `NSX_` → `hx0001f`) |
| L4 | String encryption (`HSIPS_STRINGS.mqh`; default OFF — adjacency-safe) |
| L5 | License enforcement (signed, expiring, bound) |
| L6 | Environment binding (account + server + broker) |
| L7 | Anti-tamper: payload integrity hash, clock-rollback detection |
| L8 | Compilation hardening (MetaEditor CLI, fail-on-error/warning) |
| L9 | Distribution packaging (safety scan, SHA-256, no source/keys) |
| L10 | Audit & incident response |

**Automated pipeline (22 stages):** check environment → check tools → check intake → backup → clean work → copy → sanitize → obfuscate → encrypt strings → inject product header → inject license → inject binding → inject anti-tamper → build salt → build ID → compile → validate log → hash `.ex5` → manifest → package → license template → audit log.

---

## 3. WORKSPACE LAYOUT

```
<ROOT>  (default E:\HS_IP_PS)
├── bin\                launchers (hsips.bat, hsips-build.bat)
├── config\             hsips.json, security_policy.json, build_policy.json, products\
├── keys\public|private|shards
├── templates\          HSIPS_LICENSE.mqh.template
├── scripts\            all PowerShell + Python automation
├── source_original\    permanent developer source (read-only)
├── source_work\        disposable protected working copy
├── include_work\       disposable protected includes
├── build\              compiled .ex5 + reports
├── dist\               final protected output
├── licenses\           generated customer .lic
├── logs\               build + license logs
├── audit\              manifests, hashes, obfuscation maps
├── backup\             encrypted backups
└── customer_packages\  ready-to-send archives
```

**Rule:** `source_original` permanent · `source_work` disposable · `dist` customer-facing · `keys\private` + `audit` never distributed. The write-guard blocks any pipeline write outside the root, which is resolved as `HSIPS_HOME` env var → the guard script's own parent folder (fully relocatable, no hardcoded drive).

---

## 4. LICENSING MODEL (offline-first)

**License types:** TRIAL · DEMO · LIVE_SINGLE_ACCOUNT · LIVE_MULTI_ACCOUNT · TIME_LIMITED · PERPETUAL · BROKER_LOCKED · SYMBOL_LOCKED · CUSTOM.

**License file (`.lic`, 264 bytes):**
```
Offset  Size  Field
0       4     Magic "HSPL"
4       4     Format version (1)
8       256   Encrypted payload (HSIPS stream cipher — see §5)
```
Payload (after decryption, 256 bytes): `PL1` magic → version → license ID (16) → product UUID (16) → issued (8) → expiry (8, 0=none) → login (8) → max accounts (4) → flags (4) → server (64) → broker (64) → nonce (16) → integrity hash (32) → reserved (8).

**Flags (bitmask):** 1 ALLOW_DEMO · 2 ALLOW_LIVE · 4 ALLOW_TESTER · 8 ALLOW_OPTIMIZATION · 16 SERVER_BOUND · 32 BROKER_BOUND · 64 EXPIRY_REQUIRED.

**Runtime location:** `MQL5\Files\HS_IP_PS\*.lic` (sandboxed; identical on Windows + macOS).

---

## 5. CRYPTOGRAPHY (self-contained — no external AES/OpenSSL)

- **Key:** `K = HSIPS_Hash256( secret(32) ‖ productUUID(16) ‖ login_le64 ‖ server_utf8 )`
  - `secret` = 32-byte product secret, split into 4 XOR shards (`SECRET_A/B/C/D`) embedded in the `.ex5`.
  - `server` encoded as **UTF-8** on both sides.
- **Cipher:** XOR keystream. `keystream = HSIPS_Hash256(K ‖ uint32_le(i))[0:16]` for blocks `i=0..15`.
  - Implemented **identically** in MQL5 (`HSIPS_StreamXor`) and Python (`hsips_stream_xor`).
- **Integrity:** `HSIPS_Hash256(first 216 bytes of payload)` stored at payload[216:248]; verified at runtime.
- **Clock rollback:** encrypted monotonic timestamp in `MQL5\Files\HS_IP_PS\clock.bin` (12 h tolerance).

`HSIPS_Hash256` is a custom 256-bit hash (4×u64 state, multiply-rotate, 64 finalization rounds) — **byte-identical** in MQL5 and Python (verified by round-trip test).

---

## 6. RUNTIME ENFORCEMENT (fail-closed)

On attach: read `.lic` → derive key → stream-decrypt → verify magic/UUID/integrity → check account login, server, broker, demo/live mode, tester/optimization flags, expiry, clock → gate every event.

Event wrappers gate: `OnInit` (returns `INIT_FAILED`), `OnTick`, `OnTimer`, `OnTrade`, `OnTradeTransaction`, `OnTester`, `OnChartEvent`.

Invalid license → chart comment `HS_IP_PS: LICENSE INVALID`, new orders blocked, strategy logic never executed. Valid → `HS_IP_PS: LICENSE OK`. No detailed internal errors are revealed.

---

## 7. DEVELOPER WORKFLOW (one command per stage)

| Action | Command |
|---|---|
| Create product | `New-HSIPSProduct.ps1 -ProductCode … -ProductName … -Version … -EntryFile …` |
| Validate intake | `Test-HSIPSSourceIntake.ps1 -ProductCode …` |
| Set obfuscation prefix | `Set-HSIPSObfuscationPrefix.ps1 -ProductCode … -Prefix "NSX_"` |
| Generate secret | `New-HSIPSProductSecret.ps1 -ProductCode …` |
| **Build** | `hsips-build.bat <PRODUCT_CODE>` or `Invoke-HSIPSBuild.ps1 -ProductCode …` |
| License | `New-HSIPSLicense.ps1 -ProductCode … -AccountLogin … -Server … -Profile …` |
| Package | `Invoke-HSIPSPackage.ps1 -ProductCode … -CustomerName … [-LicenseFiles …]` |
| Full release | `Invoke-HSIPSRelease.ps1 -ProductCode … -CustomerName … -AccountLogin … -Server …` |
| Bump version | `Set-HSIPSProductVersion.ps1 -ProductCode … -Version …` |

**Release checklist:** intake passed · 0 errors · 0 warnings · fails without license · works with license · fails on wrong account/server · package contains only `.ex5/.lic/.txt/.json` · non-null SHA-256 manifests · Git committed · backup updated · no private material sent.

---

## 8. DISTRIBUTION & PACKAGING

Customer package contains only:
```
ExpertAdvisors\PRODUCT_CODE.ex5
HS_IP_PS\license.lic
Documentation\INSTALL_WINDOWS.txt, INSTALL_MACOS.txt, LICENSE_TERMS.txt, CHECKSUMS.txt
manifest\package_manifest.json
README.txt
```

- ZIP always via built-in `Compress-Archive` (dependency-free).
- Encrypted archive = **RAR** via `Rar.exe a -ep1 -m5 -hp<pwd>` (WinRAR cannot write 7z; `-hp` encrypts headers+data).
- Safety scan rejects `.mq5/.mqh/.ps1/.py/.bat/.log/.pem/.key/.bin/.pfx/.p12` and any `source/scripts/keys/logs/audit` path.

---

## 9. CUSTOMER INSTALLATION

**Windows & macOS (identical logic):**
1. Extract package. 2. MT5 → File → Open Data Folder. 3. Copy `.ex5` → `MQL5\Experts`. 4. Create `MQL5\Files\HS_IP_PS` (exact case). 5. Copy `.lic` → that folder. 6. Refresh Navigator → attach → enable Algo Trading. 7. Confirm `HS_IP_PS: LICENSE OK`.

**macOS notes:** use Data Folder navigation only; The Unarchiver/Keka handle `.rar`; `.lic` is binary (never open in TextEdit).

---

## 10. TESTING, HARDENING, AUDIT, INCIDENT RESPONSE

- **QA matrix:** visual tester trade-log parity vs. unprotected source · 24 h demo forward test · negative tests (no license, wrong account/server, rollback, optimization, tamper) · Windows/macOS VM tests.
- **Hardening:** BitLocker · Defender + firewall · `gpedit.msc` removable-media deny · no cloud sync · screen-lock.
- **Audit:** review `audit\intake_*.json`, `audit\source_protection_*.json`, `build\…\logs\compile.log` (0/0), `package_manifest.json` (only safe files).
- **Incident response:** secret compromise → immediate key rotation (new secret → rebuild → reissue all licenses). Source leak → rewrite strategy + bump MAJOR. `.ex5` redistribution → account-binding renders it useless; DMCA. Account sharing → revoke + rotate.
- **Emergency release:** patch → bump version → `Invoke-HSIPSRelease.ps1 … -NoLicense` → distribute `.ex5` (existing `.lic` stays valid while UUID/secret unchanged).

---

## 11. ACCEPTED LIMITATIONS

1. Source leak = unrecoverable. 2. Screen-recording defeats behavioral secrecy. 3. Compromised MT5 bypasses runtime checks. 4. Stolen keys permit forgery until rotation. 5. Admin-controlled customer machines are ultimately inspectable. 6. MQL5 sandbox limits hardware fingerprinting (account/server binding is the practical substitute).

**Protect the keys. Trust the pipeline. Trade securely.**
