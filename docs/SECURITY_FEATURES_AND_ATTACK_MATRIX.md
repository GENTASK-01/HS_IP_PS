# HS_IP_PS — COMPLETE SECURITY FEATURES & ATTACK MATRIX
### High Security IP Protection System — v1.2.0

> This document enumerates **every** security control implemented in the current system,
> then maps **every** plausible attacker action against it and explains exactly why each
> fails (and, honestly, where residual risk remains). Nothing here is aspirational — each
> item corresponds to real code in `scripts/`, `templates/HSIPS_LICENSE.mqh.template`, and
> the runtime behavior of the compiled `.ex5`.

---

# PART 1 — COMPLETE SECURITY FEATURES

## 1.1 Layer 0 — Developer Machine Hardening
| # | Feature | Implementation |
|---|---|---|
| 0.1 | Drive separation | `C:` = software only; all project data on the project drive (default `E:`) — enforced by the write-guard |
| 0.2 | BitLocker full-disk encryption | Optional OS-level encryption of source + keys at rest |
| 0.3 | NTFS ACL lockdown | `Initialize-HSIPSStructure.ps1` strips inherited ACEs; grants only Administrators, SYSTEM, and the operator; `keys\private` separately restricted |
| 0.4 | Least-privilege build user | Optional dedicated `HSBuilder` local user; not an Administrator |
| 0.5 | Local-only Git | Repo has **no remote**; `.gitignore` excludes `keys\private`, `logs`, `audit`, `source_work`, `backup`, `licenses`, `dist` |
| 0.6 | Git isolation | `--local` (repo-scoped) config only — no `--global`, no cloud sync |
| 0.7 | No cloud sync | Project root never inside OneDrive/Dropbox/etc. (policy + guidance) |
| 0.8 | Write-guard | `Assert-HSIPSWritePath` throws on any pipeline write outside the project root |

## 1.2 Layer 1–2 — Source Isolation & Sanitization
| # | Feature | Implementation |
|---|---|---|
| 1.1 | Original source read-only | Pipeline never compiles or packages `source_original` directly |
| 1.2 | Disposable working copy | `source_work` wiped and regenerated every build |
| 1.3 | Comment stripping | `//` and `/* */` removed (string/char-literal aware) |
| 1.4 | Metadata sanitization | `#property author/link/description` removed; `copyright` replaced with product name |
| 1.5 | Intake validation | Blocks `.dll/.exe/.ex5/.bat/.py/.pem/.key` etc.; detects DLL imports, WebRequest, private keys, hardcoded credentials, debug flags |
| 1.6 | DLL policy | `require_dll=false` default; pure-MQL5 enforced |

## 1.3 Layer 3 — Identifier Obfuscation
| # | Feature | Implementation |
|---|---|---|
| 3.1 | Prefix-based renaming | Identifiers matching `NSX_*` renamed to `hxNNNNN` (e.g. `NSX_CalculateRisk` → `hx0001f`) |
| 3.2 | Preservation of MQL5 ABI | Event handlers (`OnInit`, `OnTick`, …) and standard-library names never renamed |
| 3.3 | Private obfuscation map | `identifier_map` stored only in `audit\` (never distributed) |

## 1.4 Layer 4 — String Encryption
| # | Feature | Implementation |
|---|---|---|
| 4.1 | String encryption | Selected literals → `HSIPS_STR(id)`; ciphertext in `HSIPS_STRINGS.mqh` |
| 4.2 | Key sharding | XOR key split into `HSIPS_KA[]` / `HSIPS_KB[]` arrays |
| 4.3 | Runtime reconstruction | `HSIPS_DecryptPayload` reconstructs strings at call time via `ShortArrayToString` |
| 4.4 | Adjacency-safe | Never splits adjacent string-literal concatenation (compile integrity) |
| 4.5 | Default OFF | `StringMode=none` default for zero-error builds; opt-in via `-StringMode sensitive_only` |

## 1.5 Layer 5 — License Enforcement Engine
| # | Feature | Implementation |
|---|---|---|
| 5.1 | Offline-first | No activation server, no internet check, no DLL |
| 5.2 | Encrypted payload | 256-byte payload encrypted (XOR keystream over `HSIPS_Hash256`) |
| 5.3 | Product secret | 32-byte `product_secret.bin`, XOR-split into 4 shards embedded in `.ex5` |
| 5.4 | Key derivation | `HSIPS_Hash256(secret ‖ UUID ‖ login ‖ server_utf8)` — account+server bound |
| 5.5 | License types | TRIAL / DEMO / LIVE_SINGLE / LIVE_MULTI / PERPETUAL / BROKER_LOCKED / CUSTOM |
| 5.6 | Expiration | 8-byte Unix expiry + `EXPIRY_REQUIRED` flag; checked vs server time |
| 5.7 | Demo/live gating | `ACCOUNT_TRADE_MODE` vs `ALLOW_DEMO`/`ALLOW_LIVE` flags |
| 5.8 | Tester/optimization gating | `MQL_TESTER` / `MQL_OPTIMIZATION` vs flags |
| 5.9 | Fail-closed | Invalid → `INIT_FAILED`, all events blocked, `HS_IP_PS: LICENSE INVALID` |
| 5.10 | No info leakage | No detailed internal error revealed to the customer |
| 5.11 | Periodic re-check | License re-validated every 15 min (`HSIPS_LICENSE_AllowTick`) |
| 5.12 | Multi-license scan | Scans all `*.lic` in `MQL5\Files\HS_IP_PS`; uses the matching one |

## 1.6 Layer 6 — Runtime Environment Binding
| # | Feature | Implementation |
|---|---|---|
| 6.1 | Account login binding | `license_login != login` → reject |
| 6.2 | Server binding | `SERVER_BOUND` flag + exact server-name match |
| 6.3 | Broker binding | `BROKER_BOUND` flag + broker match |
| 6.4 | Product binding | Payload `product UUID` must equal embedded `HSIPS_PRODUCT_UUID` |

## 1.7 Layer 7 — Anti-Tamper & Integrity
| # | Feature | Implementation |
|---|---|---|
| 7.1 | Payload integrity hash | `HSIPS_Hash256(payload[0:216])` vs `payload[216:248]` |
| 7.2 | License magic + version | `HSPL` header + format-version check |
| 7.3 | Clock-rollback detection | Encrypted monotonic timestamp in `clock.bin`; 12 h tolerance |
| 7.4 | Multi-source time | `TimeGMT()` → `TimeCurrent()` fallback |

## 1.8 Layer 8 — Compilation Hardening
| # | Feature | Implementation |
|---|---|---|
| 8.1 | MetaEditor CLI build | `/compile` + `/log` automated; no manual IDE step |
| 8.2 | Fail on error | Any error → build aborts |
| 8.3 | Fail on warnings | `max_warnings=0` default |
| 8.4 | Log validation | Robust parse of "N error(s), M warning(s)" |
| 8.5 | `.ex5` validation | Must exist and exceed 1024 bytes |
| 8.6 | Unique build identity | Build ID = timestamp + version + random suffix; SHA-256 of `.ex5` |

## 1.9 Layer 9 — Distribution Packaging
| # | Feature | Implementation |
|---|---|---|
| 9.1 | Allowlist-only content | Only `.ex5/.lic/.txt/.json` can ship |
| 9.2 | Safety scan | Rejects `.mq5/.mqh/.ps1/.py/.bat/.log/.pem/.key/.bin/.pfx/.p12` and `source/scripts/keys/logs/audit` paths |
| 9.3 | SHA-256 manifests | `CHECKSUMS.txt` + `package_manifest.json` + `.zip.sha256` sidecar |
| 9.4 | Optional encrypted RAR | `Rar.exe -hp` (header + data encryption) for private transfer |
| 9.5 | Never ships | source, scripts, keys, secrets, logs, audit, obfuscation maps |

## 1.10 Layer 10 — Audit & Incident Response
| # | Feature | Implementation |
|---|---|---|
| 10.1 | Intake reports | `audit\intake_*.json` (files, hashes, errors) |
| 10.2 | Protection reports | `audit\source_protection_*.json` (obfuscation map, string map) |
| 10.3 | Build reports | `build\…\manifest\build_report.json`, `source_hashes.json`, `checksums.json` |
| 10.4 | License issuance logs | `logs\license_generation_*.json` (ID, login, server, flags, timestamps — no secret) |
| 10.5 | Key rotation procedure | New secret → rebuild → reissue |
| 10.6 | Reproducible identifiers | Product UUID, version, build ID, hashes |

## 1.11 Cross-Cutting Properties
| # | Property |
|---|---|
| 11.1 | **Pure MQL5 runtime** — no DLL, no external helper, no Windows-only API (macOS-compatible) |
| 11.2 | **Zero paid dependencies** — Python stdlib + built-in PowerShell only |
| 11.3 | **Relocatable root** — resolved from `HSIPS_HOME` or bundle location (no hardcoded drive) |
| 11.4 | **Defense in depth** — 10 independent layers; bypass of one degrades, not defeats |
| 11.5 | **Fail-closed by default** — every failure mode disables trading, never enables it |

---

# PART 2 — COMPLETE ATTACK MATRIX
### Every plausible attacker action → why it fails → residual risk

## 2.1 Goal: Run the EA without a valid license

| # | Attacker technique | Why it fails |
|---|---|---|
| A1 | Attach EA with no `.lic` | `OnInit` → `INIT_FAILED`; all events gated |
| A2 | Place an empty/random `.lic` | Magic `HSPL` + version + payload parse fail |
| A3 | Place a `.lic` for a different product | `product UUID` mismatch |
| A4 | Delete `clock.bin` to reset rollback | Rollback check tolerates a first run; but expiry/account checks still apply; if no valid license, still fails |
| A5 | Rename an arbitrary file to `.lic` | Fails magic + size + decryption + integrity |

## 2.2 Goal: Extend or reuse a time-limited (trial) license

| # | Attacker technique | Why it fails |
|---|---|---|
| B1 | Reuse the same `.lic` after expiry | `now > expiry` → reject (server time) |
| B2 | Roll the system clock back | `clock.bin` monotonic store detects >12 h backward jump → lock |
| B3 | Disconnect + roll local clock back | Falls back to `TimeCurrent()`, but `clock.bin` still detects the jump |
| B4 | Hex-edit the expiry bytes | Inside the integrity-hashed region (offsets 0–216) → hash mismatch |
| B5 | Re-encrypt a modified payload | Requires the 32-byte product secret (developer-only) |
| B6 | Edit `clock.bin` | Sealed with `HSIPS_Hash256(secret ‖ …)`; secret unknown |
| B7 | Set clock forward then back within tolerance | ±12 h max gain; cannot extend by days |

## 2.3 Goal: Transfer a license to another account/machine

| # | Attacker technique | Why it fails |
|---|---|---|
| C1 | Copy `.lic` to another account | `license_login != login` → reject |
| C2 | Copy `.lic` to another broker server | `SERVER_BOUND` + exact server match fails |
| C3 | Copy `.lic` to another machine (same account) | Account/server binding is the control; works only on the licensed account (by design — this is the intended "move to new PC" feature) |
| C4 | Share login credentials + `.lic` | Only works by logging into the *victim's* account — the victim's capital/logins are exposed, not the EA's protection |

## 2.4 Goal: Recover or reverse-engineer source code

| # | Attacker technique | Why it fails |
|---|---|---|
| D1 | Decompile the `.ex5` | Identifiers obfuscated (`hxNNNNN`), comments stripped, metadata sanitized |
| D2 | Extract string literals | Strings encrypted into `HSIPS_STRINGS.mqh` (XOR + key shards) |
| D3 | Extract license logic secrets | Secret XOR-split into 4 shards (`SECRET_A..D`) embedded inline |
| D4 | Reconstruct original names | Obfuscation map never ships (lives in private `audit\`) |
| D5 | Find source in the package | Safety scan guarantees no `.mq5/.mqh` ships |

## 2.5 Goal: Redistribute the `.ex5`

| # | Attacker technique | Why it fails |
|---|---|---|
| E1 | Upload `.ex5` to a forum/torrent | Useless without a valid, account-bound `.lic` |
| E2 | Share `.ex5` + a friend's `.lic` | `.lic` bound to friend's login+server → fails on others |
| E3 | Strip license checks from `.ex5` | Requires defeating obfuscation + inline shards + integrity; non-trivial, manual, per-build |

## 2.6 Goal: Forge a valid license

| # | Attacker technique | Why it fails |
|---|---|---|
| F1 | Guess the license format | Format is documented but useless without the secret |
| F2 | Brute-force the product secret | 32 bytes = 256-bit keyspace → computationally infeasible |
| F3 | Recover secret from `.ex5` | Secret is split into 4 XOR shards across inline arrays — requires defeating obfuscation + locating + combining shards |
| F4 | Steal the secret | Only lives in `keys\private` (NTFS-restricted, BitLocker, never shipped, never in Git) |

## 2.7 Goal: Tamper with runtime behavior

| # | Attacker technique | Why it fails |
|---|---|---|
| G1 | Modify the `.ex5` binary | MT5 signature/integrity checks + broken internal hashes → fails to load or `INIT_FAILED` |
| G2 | DLL injection / memory patching | No DLL surface; pure-MQL5; and license re-checked every 15 min |
| G3 | Fake the account/server identity | `AccountInfoInteger/String` come from the connected broker, not attacker-controlled |
| G4 | Feed fake tester flags | `MQL_TESTER`/`MQL_OPTIMIZATION` are terminal-enforced |

## 2.8 Goal: Compromise the Developer machine (the real prize)

| # | Attacker technique | Why it (mostly) fails |
|---|---|---|
| H1 | Remote access / phishing | Dedicated build user, no cloud sync, firewall guidance |
| H2 | Copy `keys\private` via USB | NTFS ACLs + removable-media policy + BitLocker |
| H3 | Read the secret from clipboard/logs | Secret never printed; logs exclude it |
| H4 | Read Git history for secrets | `.gitignore` + no-remote + `keys\private` never committed |
| H5 | Physical theft | BitLocker at rest |

---

## PART 3 — HONEST RESIDUAL RISKS (what *can* still happen)

A complete security document must state what the system **cannot** defend against:

| # | Residual risk | Mitigation / reality |
|---|---|---|
| R1 | **The Developer leaks the source or secret** | No software can recover leaked IP; rely on process discipline + backups |
| R2 | **Screen recording / manual observation** | An authorized customer can learn *behavior* (entries/exits) — unavoidable for any client-side EA |
| R3 | **Compromised MT5 terminal / broker server** | Runtime trusts `AccountInfo*` and `TimeGMT()`; a hostile terminal defeats runtime checks |
| R4 | **Admin control of the customer machine** | Any client-side protection is ultimately inspectable/patchable given enough skill + time |
| R5 | **Custom cipher is not third-party audited** | `HSIPS_Hash256` and the XOR keystream are bespoke (not FIPS/NIST-reviewed). They are strong *practically* but not a formally vetted primitive. The `.ex5` itself is additionally protected by MetaQuotes' own obfuscation/encryption of compiled binaries. |
| R6 | **No remote kill switch** | Offline model cannot revoke a *leaked* license remotely; only account/server binding limits its use |
| R7 | **MQL5 sandbox limits hardware fingerprinting** | No MAC/CPU ID without a DLL (which would break macOS + increase AV flags); account/server binding is the practical substitute |
| R8 | **Determined reverse engineer with the .ex5** | Obfuscation raises cost/time but does not make it impossible |

**Bottom line:** HS_IP_PS makes unauthorized use, redistribution, and reverse engineering
*expensive and labor-intensive*, blocks all casual/simple attacks, and enforces license terms
technically — but it is not, and is not claimed to be, mathematically unbreakable.
