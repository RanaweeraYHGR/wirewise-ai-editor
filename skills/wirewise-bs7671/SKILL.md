---
name: wirewise-bs7671
description: Residential electrical design rules for WireWise AI, based on BS 7671:2018+A4:2026 (18th Edition, Amendment 4) with Sri Lankan supply and legal context. Use when placing lights and switches (lux / lumen method), generating circuits, sizing cables and protective devices, checking voltage drop / earth fault loop impedance / RCD needs, earthing and bonding, bathroom (Section 701) rules, or writing validation messages and BOM entries.
---

# WireWise BS 7671 Design Skill

## Edition and legal basis
- **BS 7671:2018+A4:2026** is current: published 15 Apr 2026; A2+A3 withdrawn 15 Oct 2026. *(IET, BSI, NICEIC)*
- **Sri Lanka:** the Electricity (Safety, Quality & Continuity) Regulations 2016 name BS 7671 "or latest" as the required installation standard. PUCSL's 2026 solar/BESS framework requires the latest BS 7671.
- **Earthing:** Sri Lankan homes are **TT** (UoM EE101). The licensee must give the earthing type and Ze on request (SQCR Reg 64).

## Trust levels
Every value in `references/` carries a `_source`:
- `verified_current`: official, current
- `verified_2008_guide`: ECA Guide, 17th Ed. Concept OK, value may have changed.
- `secondary`: datasheet, training site or forum that quotes BS 7671
- `unverified`: model knowledge

Show the trust tag in every validation result. If a value is missing, say "not in rule profile". Never invent one.

## Golden rules
1. **LLM interprets, code calculates.** Ib, In, Iz, VD, Zs and RA only come from deterministic functions reading `rule-profile.json`.
2. Every check returns a status (pass / warning / error), the regulation reference and the trust tag.
3. Never say "compliant", "safe" or "certified". Say "Passed under selected rule profile — review required".
4. Missing input (length, installation method, Ze, RA) → WARNING, not an assumption.

## Step 0 — Lighting layout (per room, before circuits)
Use `rule-profile.json → lighting_design`. This isn't BS 7671. It's design guidance.
1. Target lux from the room type.
2. Number of lights: N = ceil(E × A / (lumens × 0.5 × 0.8)). If N > 4, use a brighter lamp first.
3. One switch per room, by the door. Two-way switching on stairs and long corridors. Outdoor lights on a photo-sensor or timer.
4. Group up to 10 points per lighting circuit, with at least 2 lighting circuits per house.
5. Check W/m² against the 7.5 benchmark. Exceeding it is INFO only.
The LLM may adjust the room type or the user's preference ("brighter kitchen"). The count is always calculated.

## Design procedure (per final circuit)
| # | Step | Rule | Ref |
|---|---|---|---|
| 1 | Divide circuits | Separate lighting / sockets / each AC / each water heater / cooker. Kitchen gets its own socket circuit. | 314.1 |
| 2 | Ib | P×1000 / (230×pf). No diversity on socket finals. Diversity only for max demand. | 311.1 |
| 3 | In | Next standard rating ≥ Ib. Lighting ≤ 16 A (ES/BC). | 433.1.1, 559.6.1.6 |
| 4 | Iz | Table Iz for method ≥ In / (Ca·Cg·Ci). Ignore grouping for cables at ≤ 30% load. | 433.1.1, App 4 |
| 5 | VD | mV/A/m × Ib × L / 1000 ≤ 3% lighting / 5% other | 525, App 4 |
| 6 | Fault | S ≥ √(I²t)/k, k = 115. A 1 mm² cpc is fine with B6–B50 MCBs. | 434, 543.1 |
| 7 | Shock, **TT** (default) | RCD for fault protection: RA × IΔn ≤ 50 V. Warn if RA > 200 Ω. 0.2 s. | 411.5.3 |
| 7b | Shock, TN | Zs = Ze + (R1+R2)×1.2×L ≤ max Zs (0.4 s) | 411.4, Table 41.3 |
| 8 | 30 mA RCD | Sockets ≤ 32 A, all lighting (domestic), all bathroom circuits, concealed cables < 50 mm | 411.3.3, 411.3.4, 701.411.3.3, 522.6.202 |
| 9 | RCD sizing | Standing leakage < 25% IΔn. ≤ 10 double sockets per RCD circuit. | 531.2.4 |
| 10 | Bathroom | Zone IP: IPX7 / IPX4 / IPX4. Sockets ≥ 2.5 m from Zone 1. | Section 701 |
| 11 | Earthing & bonding | Earth electrode (TT). Bond incoming metal water/gas pipes. Typical 16 mm² earthing conductor (TT min 6), 10 mm² main bonds. | 542, 544 |
| 12 | AFDD | Required only for listed building types; otherwise INFO | 421.1.7 |
| 13 | **Max demand (whole house)** | After every change, apply `max_demand.diversity` → Ib_total vs main switch (default 30 A). ≥ 80% WARNING, > 100% ERROR. Suggest fixes; three-phase needs a chartered engineer. | 311.1 |

**Run step 13 after every natural-language change.** For example, "add AC to all bedrooms" must re-check the total, not just the new circuits.

## Sanity check
Compare the calculated max length with `circuit_templates.*.max_length_m` (2008 standard circuits). A big mismatch → WARNING to check the inputs.

## Validation message format
```
[ERROR|WARNING|INFO] <circuit id> — <what failed>
Rule: <reg no> | Value: <calc> vs limit <limit> | Trust: <tag>
Suggested fix: <deterministic option, e.g. next cable size / add RCD>
```

## Files
- `references/regulations-map.md`: reg-by-reg notes with ✅ / 📘 / 🔶 / ⚠️ tags
- `references/rule-profile.json`: all numbers, each with a `_source`
- `references/sri-lanka.md`: legal basis, supply, TT earthing, sockets
- `references/sources.md`: every source, what it confirmed, what's still unverified
