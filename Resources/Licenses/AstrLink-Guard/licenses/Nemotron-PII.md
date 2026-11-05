---
license: cc-by-4.0
task_categories:
- token-classification
language:
- en
tags:
- datadesigner
- pii
- privacy
- data-masking
- synthetic-data
- named-entity-recognition
- nvidia
- nemotron
- personas
size_categories:
- 100K<n<1M
---

# Nemotron-PII: Synthesized Data for Privacy-Preserving AI

## Dataset Description

Nemotron‑PII is a synthetic, persona‑grounded dataset for training and evaluating detection of Personally Identifiable Information (PII) and Protected Health Information (PHI) in text at production quality. It contains 100,000 English records across 50+ industries with span‑level annotations for 55+ PII/PHI categories, generated with NVIDIA NeMo Data Designer using synthetic personas grounded in U.S. Census data to ensure demographic realism and contextual consistency. This dataset includes both structured (e.g., forms, invoices) and unstructured (e.g., emails, free text) documents and explicitly marks locale conventions (U.S. or international) per record.

This dataset is ready for commercial use.

## Dataset Owner(s)

NVIDIA Corporation

## Dataset Creation Date

2025/10/28

## License/Terms of Use

This dataset is licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0) available at https://creativecommons.org/licenses/by/4.0/legalcode.

## Intended Usage

Train and evaluate Named Entity Recognition (NER) models for PII/PHI detection and redaction in healthcare, finance, legal, and enterprise compliance scenarios. Benchmark model robustness across prompt styles and formats using persona‑grounded texts spanning U.S. and international conventions. Support conversational AI safety and cross‑border privacy tooling with realistic yet synthetically-labeled data.

Although this dataset is fully synthetic and designed to avoid real personal data, practitioners should validate models in deployment to prevent missed detections or unintended leakage in downstream processes.

## Dataset Characterization

**Data Collection Method**<br>
[Synthetic] Generated via NVIDIA NeMo Data Designer; persona‑grounded for realistic, consistent entities within each document.

**Labeling Method**<br>
[Synthetic] Span‑level annotations for 55+ PII/PHI entities produced during generation.

## Dataset Format

Parquet format for efficient storage and processing; JSONL (UTF‑8) and CSV exports also available.

## Dataset Quantification

- Size: 100,000 records (50k train / 50k test)
- Domains: 50+ industries (e.g., healthcare, finance, cybersecurity)
- Entity Types: 55+ PII/PHI categories (e.g., names, SSNs, MRNs, addresses, phones, emails, account numbers)
- Locale Coverage: U.S. and international; international includes ~12% U.S.‑style overlap to reflect real‑world data diversity
- Content Types: Structured (forms, invoices) and unstructured (emails, notes, free text)

| Field | Format |
| :-- | :-- |
| uid | String/UUID |
| domain | String |
| document_type | String |
| document_description | String |
| document_format | String: structured \| unstructured |
| locale | String: us \| intl |
| text | UTF‑8 string |
| spans | List[{"start": int, "end": int, "label": str}] |
| text_tagged | String (inline tags) |

## Dataset Structure

- Splits:
    - train: US + intl combined (50,000)
    - test: US + intl combined (50,000)
- Columns:
    - uid, domain, document_type, document_description, document_format, locale, text, spans, text_tagged

## References

- NVIDIA NeMo Data Designer (synthetic data generation): https://docs.nvidia.com/nemo/microservices/latest/generate-synthetic-data/index.html
- Generate Realistic Persons (personas): https://docs.nvidia.com/nemo/microservices/latest/generate-synthetic-data/generate-realistic-personal-details.html
- Nemotron‑Personas collection: https://huggingface.co/collections/nvidia/nemotron-personas
- Gretel PII Masking dataset (related work): https://huggingface.co/datasets/gretelai/gretel-pii-masking-en-v1

## Ethical Considerations

NVIDIA believes [Trustworthy AI](https://www.nvidia.com/en-us/ai-data-science/trustworthy-ai/) is a shared responsibility and we have established policies and practices to enable development for a wide array of AI applications. When downloaded or used in accordance with our terms of service, developers should work with their internal teams to ensure this dataset meets requirements for the relevant industry and use case and addresses unforeseen product misuse.
Please report security vulnerabilities or NVIDIA AI Concerns [here](https://www.nvidia.com/en-us/support/submit-security-vulnerability/).

## Citation

If you use this dataset in your research, please cite it as follows:

```bibtex
@dataset{nemotron-pii,
  author = {Amy Steier and Andre Manoel and Alexa Haushalter and Maarten Van Segbroeck},
  title = {Nemotron-PII: Synthesized Data for Privacy-Preserving AI},
  year = {2025},
  publisher = {NVIDIA},
  url = {https://huggingface.co/datasets/nvidia/Nemotron-PII}
}
```