# Spec — 3a : Dictionnaire personnalisé / boost de mots-clés

**Date** : 2026-06-21
**Branche** : `feat/3a-custom-dictionary`
**Sources** : PR #149 (AlexCherrypi, custom dictionary universel) + PR #142 (HashiamKadhim, boost décodage Parakeet). Les deux auteurs sont crédités.

## 1. Objectif

Permettre à l'utilisateur de définir des **termes** (noms propres, jargon technique) pour
que la transcription les rende correctement — sur les **deux moteurs** (Whisper et Parakeet).

## 2. Découverte clé : conflit de version FluidAudio (décision d'architecture)

Les deux PR ne sont PAS un simple cherry-pick — elles ciblent des versions FluidAudio
**incompatibles** :

| | #149 | #142 | master actuel |
|---|---|---|---|
| FluidAudio | **0.15.x** (rév. `7f963cd`) | **0.11.0** (rév. `5d9176e`) | **0.11.0** (`5d9176e`) |
| API moteur | `loadModels` + `transcribe(url, decoderState:&)` + `TdtDecoderState()` | `initialize(models:)` + `transcribe(url)` | `initialize(models:)` |
| Custom vocabulary | **absente** (`ASR/CustomVocabulary/` retiré en 0.15.x) | **présente** (`ASR/CustomVocabulary/`: BKTree, CustomVocabularyContext, Rescorer, WordSpotting) | présente |

Vérifié via l'API GitHub `FluidInference/FluidAudio` : à `7f963cd`, `Sources/FluidAudio/ASR`
ne contient plus que Cohere/Paraformer/Parakeet/Qwen3/SenseVoice/Shared — **plus de
CustomVocabulary**. Donc le boost décodage Parakeet (#142) **ne peut pas** fonctionner sur 0.15.x
tel quel (API + fichier rescorer ciblé par le patch disparus).

**Décision : cibler FluidAudio 0.11.0** (= version actuelle du master, **zéro régression**).
Rationale :
- Le boost vocabulaire Parakeet (#142), explicitement voulu, **exige** l'API CustomVocabulary
  qui n'existe qu'en 0.11.0.
- La feature dictionnaire de #149 est **agnostique du moteur** : le prompt-boost est côté
  Whisper, le remplacement est du post-traitement. Seule la modernisation `loadModels`/
  `decoderState` de #149 nécessite 0.15.x — et elle **n'est pas** nécessaire à la feature.
- Upgrade FluidAudio 0.11→0.15 = **tâche future séparée** (migration d'API conséquente + doit
  re-résoudre le boost vocabulaire). Hors périmètre 3a.

## 3. Conception unifiée (un seul dictionnaire, pas deux éditeurs)

Le modèle de #149 est déjà le sur-ensemble : `CustomDictionaryEntry { original, replacement }`.
- `replacement` = le **bon terme** (ce qu'on veut obtenir).
- `original` = la **forme mal entendue** (optionnelle ; vide → entrée « boost seul »).

Une seule liste alimente **trois mécanismes** :

| Mécanisme | Moteur | Source | Effet |
|---|---|---|---|
| Prompt-boost | Whisper | `replacement` (dédupliqué) injecté dans `initialPrompt` | biaise la reconnaissance |
| Boost décodage | Parakeet | `replacement` → vocabulaire FluidAudio (CustomVocabulary + rescorer patché) | biaise le décodage |
| Remplacement | les 2 | `original → replacement` (whole-word, insensible casse) | correction post-transcription |

`promptBoost` (#149) ignore déjà `original` (mappe sur `replacement`, filtre vides, dédup) →
les entrées « boost seul » fonctionnent nativement. **On supprime** la pref/éditeur séparés
`parakeetCustomVocabulary` de #142 : le vocabulaire Parakeet est **sourcé des mêmes entrées**.

## 4. Composants (fichiers)

- **`OpenSuperWhisper/Models/CustomDictionary.swift`** (de #149) — `CustomDictionaryEntry` +
  `CustomDictionary.apply(_:entries:)` (remplacement whole-word, garde anti-perte si champ vide)
  + `CustomDictionary.promptBoost(entries:)`.
- **`AppPreferences.swift`** — `customDictionaryEnabled: Bool` (défaut false) + `customDictionaryEntries: [CustomDictionaryEntry]` (Codable). **PAS** de `parakeetCustomVocabulary`.
- **`Settings.swift`** — `shouldApplyCustomDictionary` (enabled && !empty) + l'éditeur unique
  « Custom Dictionary » (onglet Transcription) de #149. **PAS** l'éditeur « boosted words » de #142.
- **`Engines/WhisperEngine.swift`** (de #149) — prompt-boost (combine `initialPrompt` + termes) + post-remplacement.
- **`Engines/FluidAudioEngine.swift`** — (a) post-remplacement (de #149) ; (b) `configureCustomVocabulary(on:)` (de #142) **re-sourcé** : lit `customDictionaryEntries.replacement` (au lieu de `parakeetCustomVocabulary`). **NE PAS** prendre les changements `loadModels`/`decoderState` de #149 (rester sur l'API 0.11.0 : `initialize(models:)`, `transcribe(url)`).
- **`patches/fluidaudio-vocabulary-rescorer.patch`** (de #142) — patche le rescorer FluidAudio 0.11.0 (« prefer longer spans »).
- **`run.sh`** — `apply_fluidaudio_patches()` + l'étape `xcodebuild -resolvePackageDependencies` (de #142), **fusionnés** avec le hook `dev-codesign` existant (les deux coexistent).
- **Tests** — `OpenSuperWhisperTests.swift` : tests de #149 (apply/promptBoost) + un test du sourcing du vocabulaire Parakeet depuis les entrées (logique pure extraite si besoin).
- **`Package.resolved`** — **inchangé** (reste FluidAudio 0.11.0 / `5d9176e`).

## 5. Approche d'intégration (ordre + résolution de conflits)

1. **#149 d'abord** : cherry-pick ses commits. Résoudre les conflits `Settings.swift` /
   `AppPreferences.swift` (nos ajouts Phase 2 `notifyWhenNoPasteTarget`) et `OpenSuperWhisperTests.swift`.
   Puis **annuler** ses changements spécifiques 0.15.x : restaurer `FluidAudioEngine` sur l'API
   0.11.0 (`initialize(models:)`, `transcribe(url)` sans `decoderState`) et **rejeter** le bump
   `Package.resolved`. Build + tests → vert.
2. **#142 ensuite** : appliquer le patch (`patches/…`), fusionner `run.sh` (apply_fluidaudio_patches
   + resolve + dev-codesign), et brancher `configureCustomVocabulary` sur `customDictionaryEntries.replacement`.
   Build (le patch doit s'appliquer au checkout 0.11.0) + tests → vert.

Deux étapes pour que tout échec soit attribuable.

## 6. Tests & vérification

- Build vert (`./run.sh build`) — inclut l'application idempotente du patch FluidAudio 0.11.0.
- Suite unitaire (cible `OpenSuperWhisperTests`) verte, hors 4 échecs env. préexistants
  (Bluetooth/paste). Tests sur `-derivedDataPath build-test` (ne clobbe pas la signature).
- `CustomDictionary.apply` / `promptBoost` testés (whole-word, casse, champs vides, dédup).
- **Smoke voix Parakeet délégué à Maxim** : il choisit 2-3 termes (ex. « My-Monkey », un nom
  propre), les ajoute, et confirme à l'oreille que Whisper ET Parakeet les rendent correctement,
  et qu'un `original → replacement` corrige bien.

## 7. Risques & mitigations

| Risque | Mitigation |
|---|---|
| Patch FluidAudio ne s'applique plus | `run.sh` idempotent + échec **bruyant** (exit 1), pas en prod. Verrouillé sur 0.11.0 → stable |
| Conflits cherry-pick #149/#142 vs Phase 2 | Résolution manuelle documentée ; build+test après chaque étape |
| Verrou FluidAudio 0.11.0 (pas d'upgrade 0.15.x) | Documenté comme tâche future ; pas une régression (master déjà 0.11.0) |
| Deux features post-traitement (autocorrect asiatique + dico) | Ordre déterministe : autocorrect puis dictionnaire (déjà le cas dans #149) |

## 8. Non-objectifs

- Pas d'upgrade FluidAudio 0.15.x (tâche future séparée).
- Pas d'éditeur « boosted words » distinct (unifié dans Custom Dictionary).
- Pas de gestion multi-dictionnaires / import-export (YAGNI ; rouvrir si demandé).
