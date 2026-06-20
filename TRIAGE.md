# TRIAGE — OpenSuperWhisper fork (2026-06-21)

> **Synthèse** : 22 PR — 5 *merge-clean* (quick wins), 10 *adapt-rebase* (à intégrer après rebase),
> 4 *reject/superseded*, 3 en **décision mainteneur** (post-traitement IA). 38 issues — ~18 bugs
> (dont P0 : #117), ~18 features, ~2 méta/déjà-résolues.
> Gagnants des features concurrentes : **rétention #148** (supersède #47), **audio #126** (vs #49),
> **boost #149 + #142 complémentaires**, **IA → reco #106 (MLX), à valider**.
>
> Baseline : le fork **build OK** sous Xcode 26 / Swift 6.2 (Swift 5 language mode ; warnings de
> concurrence Swift 6 non bloquants — voir Dette technique).

Légende verdicts : `merge-clean` (mergeable + valeur sûre) · `adapt-rebase` (à rebaser/intégrer) ·
`superseded-by #X` · `reject` · `decide` (décision produit à valider avec le mainteneur).

## Pull Requests

| PR | Feature (bucket) | Amont | Verdict | Raison |
|---|---|---|---|---|
| #116 spinner pendant chargement modèle (rakendd) | fiabilité | MERGEABLE | **merge-clean** | +1/-1, UX évidente (bouton record silencieusement désactivé pendant le load) |
| #132 feedback d'erreur engine/transcription (michael-wojcik) | fiabilité | MERGEABLE | **merge-clean** | +489/-10, **inclut des tests** ; résout #117 (échec silencieux, P0) |
| #137 anti cold-start (pré-warm audio) (RABJR51) | fiabilité | MERGEABLE | **merge-clean** | +24/-1, supprime la coupure des 1ers mots ; lié #84 |
| #100 bump asian-autocorrect (dependabot) | infra | MERGEABLE | **merge-clean** | +1/-1 ; déjà sur 203fd5f, bump vers 8855a5c |
| #105 bump fastlane 2.229→2.232 (dependabot) | infra | MERGEABLE | **merge-clean** | Gemfile.lock seulement |
| #67 bump whisper.cpp f3ff80e→44fa2f6 (dependabot) | infra | MERGEABLE | **adapt-rebase** | Touche aussi build.yml + run.sh ; **à tester** (API ggml/whisper peut bouger) |
| #149 dictionnaire perso / boost mots-clés (AlexCherrypi) | dict/boost | MERGEABLE | **adapt-rebase** | Remplacement *Heard→Replace* post-transcription, **universel (2 moteurs)** ; implémente #19 |
| #142 Parakeet word boosting (HashiamKadhim) | dict/boost | MERGEABLE | **adapt-rebase** | Boost au décodage côté FluidAudio, **Parakeet-only** + tests ; **complémentaire de #149** |
| #148 rétention enregistrements + Launch at Login (AlexCherrypi) | privacy | MERGEABLE | **adapt-rebase** | Storage tab (limite N, suppr. anciens) + login ; couvre #144 |
| #121 désactiver l'historique (privacy) (lucyfarnik) | privacy | CONFLICTING | **adapt-rebase** | Toggle Privacy, suppression immédiate ; complète #148 ; couvre #144 |
| #126 pause/reprise média à l'enregistrement (directedbit) | privacy/UX | CONFLICTING | **adapt-rebase** | `MediaPlaybackController` (MRMediaRemote), gated préférence ; résout #131. ⚠️ API privée |
| #129 fix race clipboard (transcription précédente collée) (YounesMadrid69) | fiabilité | CONFLICTING | **adapt-rebase** | +29/-8 sur ClipboardUtil ; base saine pour la feature clipboard-fallback ; lié #80 |
| #122 toggle « No speech detected » (lucyfarnik) | fiabilité | CONFLICTING | **adapt-rebase** | +8/-5 ; lié #16 |
| #123 strip filler words via regex (lucyfarnik) | IA/texte | CONFLICTING | **adapt-rebase** | Nettoyage déterministe léger (alt. au LLM) ; off par défaut ; lié #55 |
| #147 streaming live (resumable) (AlexCherrypi) | fiabilité/perf | MERGEABLE | **adapt-rebase** | +788/-30, `StreamingWhisperEngine` ; gros → **sous-phase dédiée** |
| #106 post-traitement LLM on-device (Apple MLX) (userFRM) | IA | CONFLICTING | **decide** ✅reco | On-device, in-app models, manuel (clean/dev/markdown) ; le plus aligné ADN ; +1403/17 fichiers |
| #119 post-traitement via Ollama (rakendd) | IA | CONFLICTING | **decide** | +301/4 fichiers, auto + prompt custom, mais **dépend d'Ollama externe** (friction) |
| #134 correction grammaire via llama.cpp (san-kit) | IA | CONFLICTING | **decide** | On-device auto + modèles téléchargeables, mais **submodule llama.cpp + dylib** (build lourd) |
| #47 nettoyage auto enregistrements (bcharleson) | privacy | CONFLICTING | **superseded-by #148** | +1797, redondant avec #148 (plus propre & mergeable) |
| #49 préservation lecture audio (mixing) (halapenyoharry) | audio | CONFLICTING | **superseded-by #126** | Réécrit le chemin record (AVAudioEngine), chevauche #147 ; #126 répond à l'issue #131 |
| #64 intégration STT Groq (cloud) (Schreezer) | moteur | CONFLICTING | **reject** | +10846 **et pollué** (`.crush/*.db`, `.gemini-clipboard/*.png`, `CRUSH.md`) ; STT cloud ≠ ADN local. Idée « provider cloud optionnel » à reprendre proprement plus tard si voulu |
| #38 sauver JSON à côté du .wav (wkoszek) | export | CONFLICTING | **reject** (défer) | POC niche (métadonnées JSON) ; faible demande ; rouvrir si besoin réel |

## Arbitrages (PR concurrentes)

### Post-traitement IA — #106 (MLX) vs #119 (Ollama) vs #134 (llama.cpp) → **DÉCISION MAINTENEUR**
Reco : **#106 (Apple MLX)** comme base — on-device, Apple-natif (SwiftPM, pas de 2ᵉ submodule C++),
gestion des modèles in-app, le plus maintenable. Y **greffer** le *mode automatique* + *prompt
configurable* de #119. **Reject #134** (submodule llama.cpp + dylib = build trop lourd) et #119 comme
primaire (dépendance Ollama externe = friction pour l'utilisateur lambda).
→ Décision structurante (taille app, manuel vs auto) : **à confirmer avec Maxim avant la Phase 3d.**

### Boost mots-clés — #149 vs #142 → **les deux (complémentaires)**
#149 = remplacement *Heard→Replace* post-transcription, marche sur **les deux moteurs**.
#142 = boost de vocabulaire au **décodage Parakeet** (qualité supérieure mais Parakeet-only) + tests.
→ Base #149 (universel) + #142 en complément moteur Parakeet.

### Rétention enregistrements — #148 vs #47 → **#148**
#148 mergeable, propre, auteur actif (AlexCherrypi), Storage tab + Launch at Login. #47 = +1797,
conflicting, redondant. → #148 gagne, #47 superseded.

### Audio pendant l'enregistrement — #126 vs #49 → **#126**
#126 = pause/reprise média (répond à l'issue #131 demandée), opt-in, self-contained. #49 = ne pas
interrompre (mixing) via réécriture AVAudioEngine, chevauche #147. → #126 gagne.

## Issues

| Issue | Type | Lien PR | Prio |
|---|---|---|---|
| #117 échec silencieux (pas d'erreur affichée) | bug | #132 | **P0** |
| #139 deux ✓ verts → modèle actif ambigu | bug | — | P1 |
| #124 « Translate to English » sans effet (Parakeet) | bug | — | P1 |
| #107 espace manquant entre phrases | bug | (lié #115 mergé) | P1 |
| #90 coller cassé sur claviers non-US | bug | — | P1 |
| #84 n'enregistre que quelques secondes | bug | #137 ? | P1 |
| #78 popup « Recording » à position aléatoire | bug | — | P2 |
| #52 dialogue d'enregistrement invisible en plein écran | bug | — | P1 |
| #22 écrans de modèles vides | bug | (lié #12) | P1 |
| #16 « No speech detected » | bug | #122 | P1 |
| #13 échec auto-détection de langue | bug | (commit e30e53d partiel) | P1 |
| #12 liste de transcriptions vide après fichier | bug | (lié #22) | P1 |
| #9 crash sur M1 au lancement du DMG | bug | — | P1 (signature/quarantaine ?) |
| #71 `whisper.h` manquant (build) | bug/doc | (init submodule) | P2 |
| #80 copier la transcription au presse-papier (raccourci) | feature | #129 + **clipboard-fallback** | **P1** |
| #19 booster certains mots-clés | feature | #149/#142 | P1 |
| #144 restreindre rétention transcriptions/enregistrements | feature | #148/#121 | P1 |
| #131 auto pause/reprise audio | feature | #126 | P1 |
| #55 hooks de traitement de texte avant sortie | feature | #123/#106 | P2 |
| #130 toggle « Translate to English » menu barre | feature | — | P2 |
| #125 démarrer caché (barre menu) + position indicateur | feature | (privacy bucket) | P2 |
| #128 améliorer l'UI de téléchargement des modèles | feature | (lié #143) | P2 |
| #143 taille des modèles | feature/question | #128 | P2 |
| #140 remapper la touche ESC | feature | — | P2 |
| #150 ajouter une CLI | feature | — | P2 |
| #145 support du modèle SenseVoice | feature | (branche demo amont) | P2 |
| #111 support Moonshine | feature | — | P2 |
| #21 support Whisper Turbo | feature | (large-v3-turbo déjà ?) | P2 |
| #135 app compagnon iOS (dictée système) | feature | — | P2 (hors périmètre court terme) |
| #79 identification/diarisation de locuteurs | feature | — | P2 (gros) |
| #57 choisir le périphérique d'entrée | feature | (sélection micro ajoutée ?) | P2 |
| #87 barre de progression au drop d'un audio | feature | — | P2 |
| #77 anglais britannique | feature/question | — | P2 |
| #35 insérer des emoji | feature | — | P2 |
| #15 compat Intel macOS | feature | — | P2 (gros) |
| #14 workflows classifier/router (agent mode) | feature | — | P2 |
| #20 Todo list | méta | — | info |
| #8 tourner sans l'app au Dock | feature | (README [x] fait) | **close ?** |

## Dette technique repérée au build (à durcir, non bloquant)
- Concurrence Swift 6 : capture de `self`/`attributedString` en contexte concurrent
  (`TranscriptionService.swift:151,156`, `ContentView.swift:1096`) — erreurs en Swift 6 language mode.
- ⚠️ `MicrophoneService.swift:294-296` : `UnsafeMutableRawPointer` formé sur une `CFString` —
  **vrai code smell** à auditer (lié possiblement à #57 input device).
- Warnings linker : `libomp`/`libautocorrect` bâtis pour SDK macOS 26/27 vs deployment target 14.0.

## Backlog priorisé (entrée des phases 2-3)

### Phase 2 — Quick wins (merge-clean, faible risque)
- [ ] #116 spinner · #132 feedback erreur (résout #117 P0) · #137 cold-start · #100 · #105
- [ ] #67 bump whisper.cpp (à **tester** après rebase)
- [ ] **Feature neuve clipboard-fallback** : toujours copier la transcription au presse-papier
      (issue #80), au-dessus des réglages clipboard déjà mergés (#133), en intégrant le fix de race #129.

### 3a — Dictionnaire / boost mots-clés
- [ ] base **#149** (universel) + complément **#142** (Parakeet) ; issues #19.

### 3b — Confidentialité & cycle de vie
- [ ] **#148** (rétention + Launch at Login) + **#121** (désactiver historique) + **#125** (start hidden) ;
      issues #144, #125.

### 3c — Fiabilité & UX
- [ ] #90 (paste non-US) · #139 (modèle actif ambigu) · #122/#16 (no-speech) · #52 (plein écran) ·
      #126 (pause média, #131) · audit du code smell `MicrophoneService`.

### 3d — Post-traitement IA  *(décision produit à valider avant impl.)*
- [ ] implém choisie : **reco #106 (MLX)** + auto/prompt de #119 ; option déterministe légère #123 ;
      issues #55, #14.

### Sous-phase dédiée — Streaming
- [ ] **#147** (StreamingWhisperEngine) — gros, à isoler.

### À fermer / clarifier
- [ ] #8 (background app — marqué fait au README) → vérifier puis fermer.
- [ ] #20 (todo méta), #71 (doc build) → réponse/fermeture.
