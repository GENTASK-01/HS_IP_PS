# HS_IP_PS — SECURITY GUIDE: TRIAL / TIME-LIMITED LICENSE EXPIRY

### Question
> I generated a license that works for 3 days. After 3 days, can I reuse the same
> license key for another 3 days?

### Answer
**No.** Once the expiry timestamp passes, that `.lic` file is permanently invalid.
Reuse is cryptographically impossible. A fresh license must be generated for each
extension period.

---

## 1. Why reuse is impossible — 5 independent layers

### 1.1 Expiry is hard-coded inside the encrypted payload
`New-HSIPSLicense.ps1 -ExpiryDays 3` computes `expiry = now + 3 days`; the Python
generator writes it as an 8-byte **little-endian Unix timestamp** at payload
offset 48–56 and sets flag `EXPIRY_REQUIRED` (bit 64). It is not read from any
customer-controlled file — it is baked into the `.lic` bytes.

### 1.2 The payload is encrypted with a developer-only key
```
key = HSIPS_Hash256( secret(32) ‖ productUUID(16) ‖ login_le64 ‖ server_utf8 )
```
`HSIPS_StreamXor(key, payload)` encrypts the payload. The 32-byte
`keys\private\*_product_secret.bin` never leaves the Developer machine, so the
customer cannot decrypt the payload nor re-encrypt a modified one.

### 1.3 The payload is integrity-sealed
`payload[216:248] = HSIPS_Hash256(payload[0:216])`. The expiry timestamp lies
inside the hashed region. Any single bit change (e.g. pushing the date forward)
breaks the hash → `HSIPS_ParsePayload` returns false → `LICENSE INVALID`.

### 1.4 Expiry is checked against server time, not the PC clock
```mql5
ulong now = (ulong)TimeGMT();
if(now == 0) now = (ulong)TimeCurrent();
if(expiry != 0 && now > expiry) return false;
```
`TimeGMT()` is the terminal's GMT clock, synchronized to the trade server while
connected. Changing the local Windows/macOS clock does not affect it.

### 1.5 Clock-rollback protection
`HSIPS_CheckClock` compares against an encrypted monotonic timestamp stored in
`MQL5\Files\HS_IP_PS\clock.bin` (sealed with the same secret). A backwards time
jump beyond the 12-hour tolerance locks the license. Rolling back 3 days → lock.

Also: the license is **re-validated every 15 minutes** (`HSIPS_LICENSE_AllowTick`),
so expiry locks the EA mid-session, not only at attach.

---

## 2. Attack attempts and why they fail

| Attempt | Result | Blocked by |
|---|---|---|
| Reuse the same `.lic` after expiry | ❌ | expiry check (`now > expiry`) |
| Roll the system clock back | ❌ | server time + `clock.bin` rollback lock |
| Hex-edit the expiry bytes | ❌ | integrity hash (offsets 216–248) |
| Copy another customer's valid `.lic` | ❌ | login + server binding |
| Re-encrypt a patched payload | ❌ | missing 32-byte product secret |

---

## 3. The correct way to extend a trial

There is no reuse — issue a **fresh license** each time:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\HS_IP_PS\scripts\New-HSIPSLicense.ps1 `
  -ProductCode "NEBULA_SCALPER" -AccountLogin 11714248 -Server "VantageMarkets-Demo" `
  -Profile "DEMO" -ExpiryDays 3
```

Each run produces a new `.lic` with a **new License ID, new issued timestamp, and
new random nonce**. The customer deletes the old file from `MQL5\Files\HS_IP_PS`
and installs the new one.

---

## 4. Operational warning (fail-closed expiry)

The injected runtime is **fail-closed**: on expiry `OnInit` returns `INIT_FAILED`
and `OnTick`/`OnTimer` stop running — the EA stops **entirely**, including
stop-loss / take-profit management.

Best practice:
- Instruct customers to **close positions before the trial expires**, or
- **Issue the renewal before expiry** so there is no gap.

If "block new orders but keep managing open positions" is preferred, it is a
small behavior change to the license wrapper gating (`OnInit`/`OnTick`).

---

## 5. Developer best practices (trial hygiene)

1. Use short, fixed trials (3–14 days) and renew manually — never auto-renew.
2. Every renewal = a fresh license (new ID + nonce + expiry).
3. Never issue `PERPETUAL` or any-account licenses for evaluations.
4. Keep `logs\license_generation_*.json` as your issuance audit trail
   (they contain license ID, login, server, flags, timestamps — no secret).
5. Rotate the product secret only on compromise (it forces re-issuing every
   customer's license + rebuilding the EA).
