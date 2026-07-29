# Plan — 10 ancient dragon castes

Locked before implementation so there is a clean restore point. Everything below is
derived from reading Naut's Procedural Dragons (`content-mods/nauts-procedural-dragons`),
not guessed; the one deliberate assumption is that copying upstream's mechanisms works
without a trial world.

## Goal

Replace the single ancient dragon with **10 castes**, applied identically to both:

- `HA_ANCIENT_DRAGON` — the standalone `[MEGABEAST][DIFFICULTY:18]`
- the `ANCIENT_DRAGON` caste-set inside `HA_KOBOLD`

Worldgen megabeast counts are per *creature*, not per caste, so this adds variety
without generating more megabeasts. It stays one new megabeast type.

## The caste grid

Only anatomy justifies a caste. Head *shape* does not (see "Not in this pass").

| heads | tail | horns | castes | POP_RATIO each |
|---|---|---|---|---|
| 1 | spiked / clubbed | 2 / 4 / 6 | 6 | 40 |
| 2 | spiked / clubbed | fixed 4/head | 2 | 15 |
| 3 | spiked / clubbed | fixed 4/head | 2 | 15 |

Total **10 castes**, ratios summing to **300**: 240 (80%) single-headed, 30 (10%)
two-headed, 30 (10%) three-headed; tails split 50/50; horns split 1/3 each within the
single-headed group. Multi-head castes carry no horn axis because upstream's
`nHEADNECKS_HORNS` plans bundle necks + heads + a fixed four horns per head.

Caste tokens: `DRAGON_H1_SPIKE_HORN2/4/6`, `DRAGON_H1_CLUB_HORN2/4/6`,
`DRAGON_H2_SPIKE`, `DRAGON_H2_CLUB`, `DRAGON_H3_SPIKE`, `DRAGON_H3_CLUB`.

### Keeping the kobold share at 0.2%

Today: `FEMALE:500`, `MALE:500`, `ANCIENT_DRAGON:2` → 2/1002 ≈ 0.2%. Ten castes cannot
share a ratio of 2, so scale the whole creature: **`FEMALE:74850`, `MALE:74850`**, dragon
castes summing to **300** → 300/150000 = **exactly 0.2%**.

## Body plans to port

New file `objects/body_ha_dragon.txt`, copied from upstream `body_new.txt` with `HA_`
prefixes on the *plan* names only. **Body part tokens stay unchanged** (`HD`, `NK`,
`TRHORN`, …) because the graphics layers match on tokens, not plan names.

| plan | contents |
|---|---|
| `HA_DRAGON` | frame: `UB`/`DGLB`, `NK` (CATEGORY:NECK), `HD` (CATEGORY:HEAD), 4 legs + 4 feet |
| `HA_2HEAD_DRAGON` / `HA_3HEAD_DRAGON` | same frame with `NK1..n` / `HD1..n` |
| `HA_TAIL_SPIKED` / `HA_TAIL_CLUBBED` | one part, `[CON:TAIL]` — needs vanilla `TAIL` present |
| `HA_2HEAD_HORN` / `HA_4HEAD_HORN` / `HA_6HEAD_HORN` | 2/4/6 horns, `[CONTYPE:HEAD]` |
| `HA_2HEADNECKS_HORNS` / `HA_3HEADNECKS_HORNS` | 4 horns per head, `[CON:HD1]`/`[CON:HD2]`… |
| `HA_FIRE_SACK` | internal upper-body organ, `CATEGORY:FIRE_ORGAN` |

`[CONTYPE:HEAD]` attaches by category, and our head is token `HD` category `HEAD`, so the
horn plans bolt on with no other change.

## Why the frame swap matters

We currently use vanilla `QUADRUPED_NECK`, whose neck part is `CATEGORY:SPINE`. Upstream's
selectors test `BY_CATEGORY:NECK`. Moving to `HA_DRAGON` gives a real `NECK` category, the
`HD` head, and four legs whose sprites already match the atlas.

## Breath

Give every caste `HA_FIRE_SACK` and re-gate the breath from
`[CDI:BP_REQUIRED:BY_CATEGORY:MOUTH]` to **`BY_CATEGORY:FIRE_ORGAN`**, so a spear through
the chest can end the fire while leaving the dragon alive.

Do **not** copy upstream's own gating: it asks for `BY_TOKEN:BIG_FIRE_SACK`, but that is
the *plan* name — the part token is `FIRE_SACK`, so that requirement can never match.

Vapor / ice / icy-liquid / venom sacks are skipped: they are defined upstream but attached
to no caste and referenced by no interaction, so they do nothing as shipped.

## Graphics

Per layer set (BABY / CHILD / DEFAULT on the caste, DEFAULT on the megabeast):

1. **Head slots** — keep the current head at `12:10:14:11` for head 1. Add `HEAD2`
   (`15:10:17:11`) gated on `CONDITION_BP:BY_TOKEN:HD2` and `HEAD3` (`9:10:11:11`) gated
   on `HD3`, each with the eye and horn overlays upstream pairs with that slot.
2. **Horns become real** — the two horn layers currently draw unconditionally. Re-gate on
   `CONDITION_BP:BY_TOKEN:TRHORN`/`TLHORN`, and add the lower pair (`RHORN`/`LHORN`) so
   2- vs 4- vs 6-horn castes actually look different and a severed horn disappears.
3. Every added layer keeps `CONDITION_CASTE` gating in the kobold file.

## Not in this pass

**Procedural head-shape variation.** Upstream also swaps between `DRAGON_HEAD`,
`WYVERN_HEAD` (narrow+short), `WYRM_HEAD` (broad) and `DRAKE_HEAD` (tall) using
`BP_APPEARANCE_MODIFIER` rolls on the head, plus five `LH*_HEAD` shapes chosen by neck
`LENGTH`. It needs no castes and would be a nice follow-up, but each head sprite sits at a
different anchor and the eye/horn overlays are positioned per slot, so the overlays need
re-tuning per shape. Shipping it blind would mis-anchor faces. Deferred deliberately.

## Verification

Raws-only change: needs a new world. Then spawn the full set paused and confirm head
count, tail type and horn count vary across individuals.
