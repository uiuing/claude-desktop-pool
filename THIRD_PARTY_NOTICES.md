# Third-party notices

The license and attribution files listed here are reproduced from the named upstream releases. They are stored under `Resources/Licenses/` in the source tree and `Contents/Resources/Licenses/` in the macOS app bundle. Paths in the table are relative to that license directory.

| Component | Version | Use | Included notices |
| --- | --- | --- | --- |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime/tree/v1.24.2) | 1.24.2 | Native runtime for local text detection | `ONNXRuntime/MIT-LICENSE.txt`, `ONNXRuntime/ThirdPartyNotices.txt` |
| [ONNX Runtime Swift Package Manager bindings](https://github.com/microsoft/onnxruntime-swift-package-manager/tree/1.24.2) | 1.24.2 | Swift/Objective-C bindings for the bundled runtime | `ONNXRuntimeSwiftBindings/MIT-LICENSE.txt` |
| [AstrLink Guard](https://huggingface.co/QuantumNous/astrlink-guard/tree/7216b6a3b897ef903d4b1ba367ae6fb95b0fa5e4) | 0.1.3, revision `7216b6a3b897ef903d4b1ba367ae6fb95b0fa5e4` | Local INT8 text detection model, downloaded during setup | `AstrLink-Guard/LICENSE`, `AstrLink-Guard/ATTRIBUTION.md`, `AstrLink-Guard/licenses/`, `AstrLink-Guard/SHA256SUMS` |
| [Lobe Icons](https://github.com/lobehub/lobe-icons/blob/ea434b96e75813517b377825e01c0df61dee8836/packages/static-svg/icons/claude-color.svg) | revision `ea434b96e75813517b377825e01c0df61dee8836` | Claude mark in the menu bar and menu panel | `LobeIcons/MIT-LICENSE.txt` |
| [ViewInspector](https://github.com/nalexn/ViewInspector/tree/0.10.5) | 0.10.5 | Development and tests only; not part of the app runtime | `ViewInspector/MIT-LICENSE.txt` |

## ONNX Runtime

ONNX Runtime and its Swift Package Manager bindings are published by Microsoft under the MIT License. Their separate license texts are retained unchanged. The full ONNX Runtime 1.24.2 third-party notice collection is also retained unchanged; it includes notices for upstream components across supported platforms.

The package source is pinned to revision `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`. Its macOS runtime contains Apple silicon and Intel static libraries. The package's [release manifest](https://github.com/microsoft/onnxruntime-swift-package-manager/blob/1.24.2/Package.swift) records the binary archive and SHA-256 checksum.

## AstrLink Guard

Claude Pool downloads the publisher's unmodified `int8/model_int8.onnx`, `int8/model_int8.onnx_data`, and `int8/tokenizer.json` from the pinned revision. Later it may install the same files from a newer tagged release of the same repository, only while that release is published under Apache-2.0; the notices bundled here are those of the pinned revision, and the publisher's repository carries each release's own attribution. Model weights are not stored in this source repository or included in the app bundle.

The model is published under Apache-2.0. The publisher identifies the base model, [microsoft/Multilingual-MiniLM-L12-H384](https://huggingface.co/microsoft/Multilingual-MiniLM-L12-H384), as MIT-licensed. The corresponding base-model license is retained in `AstrLink-Guard/licenses/MiniLM-MIT.txt`.

The publisher's English attribution section is reproduced unchanged in `AstrLink-Guard/ATTRIBUTION.md`. It identifies modified data derived from NVIDIA Nemotron-PII under CC BY 4.0, modified data derived from google/eng-practices under CC BY 3.0, and data derived from Django under BSD-3-Clause, including the publisher's non-endorsement statement.

The complete publisher `licenses/` tree is retained, including notices for Samsung CredData, Wismut/nym-pii-multilingual-data, the base model, datasets, and source repositories. Its `SOURCES.json` records the publisher's source revisions and license references. These files are copied from the pinned model revision and checked against the publisher's `SHA256SUMS`.

Publisher sources: [model card and attribution](https://huggingface.co/QuantumNous/astrlink-guard/blob/7216b6a3b897ef903d4b1ba367ae6fb95b0fa5e4/README.md), [source manifest](https://huggingface.co/QuantumNous/astrlink-guard/blob/7216b6a3b897ef903d4b1ba367ae6fb95b0fa5e4/licenses/SOURCES.json), [license directory](https://huggingface.co/QuantumNous/astrlink-guard/tree/7216b6a3b897ef903d4b1ba367ae6fb95b0fa5e4/licenses).

## Lobe Icons

The path of `packages/static-svg/icons/claude-color.svg` from LobeHub's icon set is embedded in `Sources/ClaudePool/ClaudeMark.swift`, unchanged; the menu bar draws it as a template image. The icon set is published under the MIT License, retained in `LobeIcons/MIT-LICENSE.txt`. The mark depicted is Claude's and belongs to Anthropic; Claude Pool uses it only to show what is Claude's and is not affiliated with or endorsed by Anthropic.

## Development dependency

ViewInspector 0.10.5 is published under the MIT License by Alexey. It is used by the UI test target. Its original license is retained for the development dependency; Claude Pool's runtime does not depend on ViewInspector.
