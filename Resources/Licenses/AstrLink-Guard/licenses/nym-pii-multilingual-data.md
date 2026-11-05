---
license: mit
task_categories:
  - token-classification
language:
  - en
  - de
  - fr
  - es
  - it
  - pt
  - nl
  - pl
  - sv
  - cs
  - ro
  - tr
  - fi
  - da
  - el
  - ru
  - uk
  - ja
  - zh
  - ko
  - ar
  - hi
tags:
  - pii
  - synthetic
  - ner
  - anonymization
size_categories:
  - 100K<n<1M
---

# nym-pii-multilingual-data

805,000 synthetic, exactly-labeled PII token-classification examples across
~23 languages and 6 scripts, built for training
[nym](https://github.com/byteowlz/nym)'s PII detection models
(e.g. [`Wismut/nym-pii-multilingual`](https://huggingface.co/Wismut/nym-pii-multilingual)).

## Format

JSONL with character-offset spans (offsets index into `text` as UTF-8 —
compatible with HF fast-tokenizer `offset_mapping`):

```json
{"text": "Passport Y94316756 issued to Gary Fisher, Ukraine, expires 11/03/2008.",
 "entities": [{"start": 9, "end": 18, "label": "PASSPORT"},
              {"start": 29, "end": 33, "label": "GIVEN_NAME"},
              {"start": 34, "end": 40, "label": "SURNAME"},
              {"start": 42, "end": 49, "label": "COUNTRY"},
              {"start": 59, "end": 69, "label": "DATE"}]}
```

Splits: `train` 724,500 · `validation` 40,250 · `test` 40,250.
40 entity types (names, DOB, contact, addresses, government/medical/financial
IDs, credentials, network identifiers, …); ~13% of examples are PII-free
negatives; ~20% carry label-preserving OCR/typo noise (`o→0`, `rn→m`,
keyboard typos, spacing glitches).

## How it was generated (and why labels are exact)

1. A **coverage rubric** enumerates (language × topic × style × flavor) cells —
   23 languages, 20 domains (clinical, banking, HR, legal, logs, chat, …),
   13 registers including multi-paragraph documents, and 16 flavor twists
   including adversarial cases (PII glued into URLs/emails, same-type-adjacent
   entities, non-PII lookalikes).
2. A local LLM writes `[LABEL]`-placeholder **templates** for each cell, in that
   cell's language — it never produces data or offsets. Templates accumulate in a
   reusable bank (~5,959 distinct shapes for this release).
3. **Faker fills** each template placeholder with a realistic, locale-matched
   value, building the string incrementally so every span is **exact by
   construction** (no annotation noise, no post-hoc alignment). Each template is
   filled many times with different locale-matched values to reach 805k.
4. Noise is applied per-segment with offsets recomputed, so spans stay exact
   even when values are corrupted.

Generation pipeline (reproducible, MIT):
[`scripts/datagen`](https://github.com/byteowlz/nym/tree/main/scripts/datagen)
in the nym repository. Templates were written by Step-3.7-Flash (AWQ) running
locally on vLLM (seeds 0–2); values by Faker with matching locales.

## Versions

- **v2 (current, 805k)** — the template bank filled more heavily (more
  locale/value/noise variety per template shape) for higher-volume training of
  compact student models. Same template shapes and distribution as v1.
- **v1 (69k)** — the original release that trained the first
  `Wismut/nym-pii-multilingual` teacher; preserved in this repo's git history.

## Contains NO real personal information

Every name, address, ID and credential is synthetic (Faker or format-conforming
random values). The dataset is therefore shareable without privacy constraints.
(nym's compact models are additionally fine-tuned on a separate, license-tagged
corpus of teacher-labeled real text; that corpus is **not** part of this dataset.)

## License

MIT.
