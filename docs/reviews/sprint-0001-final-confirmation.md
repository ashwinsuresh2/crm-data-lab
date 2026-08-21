# Sprint 0001 — Targeted Confirmation Reports (final pre-freeze pass)

- **Confirmed commit:** `df2ebb8` on `sprint-0001-contracts` (2026-08-20) — remediation commits A `a057a15`, E `66f597d`, U `44095e2`, D `8095d7b` (human-approved Wave-1 amendment) merged; amendment recorded in WAVE1_FREEZE.md.
- **Five fresh reviewer instances, read-only, confined to the enumerated findings (confirm-or-reject only). Result: 5× PASS.**

---

## QA lens — VERDICT: PASS

1. **B1 fixed:** CompanyDetail (yaml 660–695) and ContactDetail (696–737) are flattened final schemas, `additionalProperties: false` at the final level, all base + added properties declared and required; grep shows zero `allOf` outside the two "no allOf" descriptions.
2. **B2 fixed:** consumer (1092–3), failure (1128–9), failure.secondary (1147–8) are inline `type: object` + `nullable: true` with stated null semantics; all 24 nullable occurrences sit on inline schemas; no nullable adjacent to $ref/allOf.
3. **ACs preserved:** spot-walk of AC-1..AC-9 through the remediated files — task title required in LogInteractionResponse; four states + failure_stage with tie-break; constant 401/403/404 bodies; replay-same-IDs; pagination on all four lists; §10 traceability table intact.
4. **Validation record independently reproduced** (scratchpad, nothing installed in repo): swagger-parser validate → PASS (3.0.3, 11 paths, zero errors); all Ajv fixture demonstrations reproduced; each outcome forced by the schema text alone.

## Data-correctness lens — VERDICT: PASS

1. **Tier-1 receipt:** §8.2.1 atomic upsert present with all mandated fields; offset commits only after durable receipt; zero-row UPDATE explicitly invalid; skip-on-processed preserved; all three interleavings (fresh / stale-processing / processed) walked and coherent, with FK and CHECK satisfaction verified against D's DDL.
2. **No zero-row no-op remains:** exhaustive UPDATE sweep — only the upsert itself and the operator resurrection (guarded on a definitely-existing outbox row); both parking triggers route through §8.2.1.
3. **Request-hash A↔D aligned:** D §3's amended rule (path identifiers incl. contactId + normalized body, server-generated excluded) and A §6 state the same observable rule; server-generated exclusion consistent by construction.
4. **attempt_count available:** both amended RETURNING lists confirmed; E references them citing the amendment; ceilings (MAX=10) live solely in E; only delegation comments in D.
5. **Format assertions:** §3.4 normative; independent Ajv-2020 strict + ajv-formats reproduction — 20/20 (compiles, valid fixtures pass, all mandated + payload negatives rejected, extra property rejected, causation_id null accepted / "banana" rejected, out-of-enum outcome rejected).
E5 residue confirmed: park-vs-ack clarification (§7.3), lease default 10 s + AC-5 clock at worker restart (§8.1), envelope↔payload equalities in §6.2 with EVENT_LINKAGE_MISMATCH.

## Security lens — VERDICT: PASS

Three layers verified line-cited: **(a) source** — E §9 safe-scalar list contains no topic/partition/offset; confinement rule bans them from both last_error columns and any tenant-facing response; negative-assertion test list includes topic names and partition/offset digits; tier-2 and publication paths route coordinates to protected logs. **(b) defense-in-depth** — A §9 explicit allowlist; ProcessingStatus subtree closed at every level; banned terms occur in the YAML only as prohibition prose; the only non-prose "offset" is the pagination parameter (client paging cursor, deliberately out of scope). **(c) render** — U bans internal fields from rendering/console/URLs and treats last_error as opaque. Non-blocking observation for Sprint 0002: AuditEvent.details is the one open-schema response object (content contractually confined to task_id/outcome; no component holding Kafka coordinates writes audit rows) — add a schema-closure test at implementation.

## Architecture lens — VERDICT: PASS

1. **Logical-identity replay:** zero "byte-for-byte" matches (remaining byte-mentions are negations); §8.3 enumerates all nine envelope elements with the current-canonical-serializer wording; §2.2 over-claim gone; PostgreSQL-survival precondition survives (twice).
2. **Offset reset vs replay:** normative distinction block present — original records at existing offsets vs new records at new offsets, no reconstruction of original offsets or interleaving; reinforced in the AC-4 note and replay test row.
3. **Engine neutrality intact:** A's allowlist withholds all lease/coordination internals with a product-level rationale; no re-coupling of the tenant surface to publisher topology or broker mechanics; broker endpoint stays behind the shared config seam.

## Product/UX lens — VERDICT: PASS

1. Deactivated user in the 401/unauthenticated class (P-AUTH-2 + P-AUTH-7) with the anti-enumeration rationale; 403 class narrowed to P-AUTH-3b/4/6; §3.3 mid-session split matches; consistent with A's constant 401.
2. Transient failed non-terminal: polling stops at processed only; failed rendered as current (not latched); tests must not treat one sub-ceiling failed reading as terminal. (Upstream-verified: sub-ceiling failed readings genuinely arise via the consumer stage.)
3. Pagination affirmative: conditional wording gone; mandatory "load more", append-in-place, no client re-sort, satisfying P's "shows all" beyond 50 rows; matches A §8 exactly.
4. State progression: "progresses to processed — typically via published; intermediate states may not be observed by polling" in both §3.2 and §5.
5. Terminology: zero "follow-up" matches. **No product scope change:** same six screens + sign-in gate, same state inventory, no new behaviors.
