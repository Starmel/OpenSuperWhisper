# Third-party notices

## Phonon-2

OpenSuperWhisper's optional Phonon-2 engine uses Fermion Research's official
Core ML model and Swift runtime. The model is downloaded on demand; it is not
part of the base application bundle.

- Model: `FermionResearch/Phonon-2-CoreML`, pinned to revision
  `1143812fd4236522232a8c33e3115f0577e3cd7d`, weights licensed CC BY 4.0.
- Runtime: `fermionresearch/phonon-coreml` release `1.1.2`, tag commit
  `bf59e574639b060e30ee1a3f9c0e003fed5744c8`, licensed Apache 2.0.
- The complete upstream NOTICE text is bundled in
  `OpenSuperWhisper/Resources/Phonon2-NOTICE.txt` and downloaded alongside the
  model as `NOTICE` and `LICENSE-WEIGHTS-CC-BY-4.0.txt`.

Pinned download evidence (SHA-256):

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `decoder.bin` | 13,301,279 | `36fa7202dda85c603af60d930ab88d7e9f0d2a619490aff46f5384db924cfa70` |
| `manifest.json` | 1,428 | `ab3fb5dfd3fc07b1d8a24379d04418f458d0443ba6359d3a5ab2f098a7d64089` |
| `Phonon-2.mlpackage/Manifest.json` | 617 | `6ebc9309aea0e16bda9c7558521fef6307fac0afba9a5b4959fea45ed7cd0429` |
| `Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel` | 2,500,482 | `4f6790ec94fe4429b10397c013563d0a51119953ff6d3da466bbcb23a25dee2a` |
| `Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin` | 329,186,560 | `93aa991318a00ed492fdbb724e7bca4e6a69c6cf671ab4f14a14ef6101e7648b` |
| `LICENSE-WEIGHTS-CC-BY-4.0.txt` | 18,657 | `9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411` |
| `NOTICE` | 3,084 | `b468a23a1ce2c5181ea4050432bb68713a6468ce2e452927228d24f3d56226be` |

Primary sources: [model repository](https://huggingface.co/FermionResearch/Phonon-2-CoreML),
[model card](https://huggingface.co/FermionResearch/Phonon-2), and
[runtime release](https://github.com/fermionresearch/phonon-coreml/tree/1.1.2).
