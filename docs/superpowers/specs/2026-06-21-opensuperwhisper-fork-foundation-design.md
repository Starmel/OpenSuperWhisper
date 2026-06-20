# Spec — Fork OpenSuperWhisper : Phase 0 (Fork & baseline) + Phase 1 (Triage)

**Date** : 2026-06-21
**Statut** : en attente de relecture
**Périmètre de CE document** : Phases 0 et 1 uniquement. Les phases 2-4 sont décrites
en roadmap (voir § Roadmap) mais seront spécifiées séparément, une fois le triage produit.

> Ce fichier de planification vit temporairement dans `osw-planning/`. Il sera **déplacé
> dans le repo forké** (`docs/superpowers/specs/`) et committé pendant la Phase 0.

---

## 1. Contexte & objectif

`Starmel/OpenSuperWhisper` est une app macOS native (Swift/SwiftUI, Apple Silicon, MIT,
819★/97 forks) de dictée par reconnaissance vocale. Deux moteurs STT : Whisper.cpp
(submodule `libwhisper/whisper.cpp`) et Parakeet/FluidAudio. Dernier commit `master`
2026-05-06, dernière release `0.1.0` (2026-03-03). Projet au ralenti mais pas archivé.

**Objectif du programme** : reprendre le projet via un **fork public maintenu** sous
`github.com/my-monkeys/OpenSuperWhisper`, intégrer de façon **curée** les meilleures PR
ouvertes, corriger les bugs des issues, et ajouter les fonctionnalités voulues par le
mainteneur (cf. § Décisions).

**Objectif de la Phase 0+1** : établir une fondation saine (fork qui build + tourne en
local) et une carte exhaustive du travail (triage écrit des 22 PR et 38 issues), qui
servira d'entrée aux specs des phases features.

## 2. Décisions validées (brainstorming)

1. **But** : successeur public maintenu (releases signées/notarisées, tri rigoureux,
   crédit aux auteurs des PR d'origine).
2. **Hébergement** : org `my-monkeys`, même nom → `github.com/my-monkeys/OpenSuperWhisper`.
3. **Approche PR/issues** : A — triage + intégration curée (PAS de merge mécanique).
4. **Features prioritaires** : dictionnaire/boost mots-clés · fiabilité & UX · confidentialité
   & cycle de vie · post-traitement IA (1 implém à choisir) · **clipboard-fallback** (neuf).
5. **Build local** : Xcode 26.1.1 / Swift 6.2 / Apple Silicon confirmés OK.

## 3. Roadmap (programme complet)

| Phase | Objectif | Critère de sortie |
|---|---|---|
| **0** | Fork & baseline | App build + se lance + transcrit en local ; remote `upstream` configuré |
| **1** | Triage écrit (22 PR + 38 issues) | `TRIAGE.md` + backlog priorisé par bucket |
| **2** | Quick wins (PR propres + clipboard-fallback) | PR intégrées avec crédit auteur |
| **3** | Features (3a dict/boost · 3b privacy · 3c fiabilité · 3d IA) | chaque sous-phase : spec → plan → impl → revue |
| **4** | Release publique (signature/notarisation, CI, cask, annonce) | release `vX` installable |

CE document spécifie **0 et 1**.

---

## 4. Phase 0 — Fork & baseline

### 4.1 Fork & clone
- `gh repo fork Starmel/OpenSuperWhisper --org my-monkeys --clone=false` (préserve le lien amont).
  - Fallback si l'option `--org` n'est pas supportée par la version de `gh` : créer le fork
    sur le compte perso puis transférer, OU `gh api` avec `organization=my-monkeys`.
- Clone dans `/Users/maxim/Documents/my-monkey/OpenSuperWhisper`.
- Remotes : `origin` = `my-monkeys/OpenSuperWhisper`, `upstream` = `Starmel/OpenSuperWhisper`.
- Branche de travail : on travaille sur `master` du fork (miroir de l'amont au départ).

### 4.2 Submodules
- `git submodule update --init --recursive`. Deux submodules :
  - `libwhisper/whisper.cpp` → ggerganov/whisper.cpp
  - `asian-autocorrect` → huacnlee/autocorrect
- **Risque connu (issue #71)** : `Bridge.h` référence `whisper.h` ; si le submodule whisper.cpp
  n'est pas initialisé, erreur fatale Xcode. → l'init submodule est un prérequis dur.

### 4.3 Dépendances toolchain (manquantes localement)
- `brew install libomp rust` (cmake ✓, ruby ✓ déjà présents).
- `gem install xcpretty` (optionnel — joli output ; le build marche sans).

### 4.4 Build & run
- Le script de référence est `./run.sh` (et `./run.sh build` pour build seul). Il :
  1. configure libwhisper via `cmake -G Xcode -B libwhisper/build -S libwhisper` ;
  2. build `autocorrect-swift` via `cargo` (target `aarch64-apple-darwin`), copie le
     `.dylib`, `install_name_tool` + `codesign --sign -` (ad-hoc) ;
  3. copie `libomp.dylib` depuis `/opt/homebrew/opt/libomp` (ad-hoc signed) ;
  4. `xcodebuild -scheme OpenSuperWhisper -configuration Debug` avec
     **`CODE_SIGNING_ALLOWED=NO`** → **aucun compte Apple Dev nécessaire en local** ;
  5. lance l'app.
- **Risque Xcode 26 / Swift 6.2** : le projet n'a pas été rebuild depuis ~6 semaines.
  Erreurs probables : durcissement concurrence Swift 6 (`Sendable`, acteurs), API dépréciées,
  warnings promus en erreurs. → corriger au cas par cas, commits ciblés `fix(build):`.

### 4.5 Vérification (exit criteria — preuve avant de déclarer « fait »)
- [ ] `./run.sh build` se termine sur `Building successful!` (capturer la sortie).
- [ ] L'app se lance (fenêtre + icône barre de menu).
- [ ] Transcription d'un fichier connu : drag&drop de `jfk.wav` (fourni dans le repo) →
      texte attendu (« And so my fellow Americans… ») produit. Capture du résultat.
- [ ] `git remote -v` montre `origin` (fork) + `upstream` (Starmel).
- Si un critère échoue → systematic-debugging avant de continuer, on ne maquille pas.

### 4.6 Hygiène repo public
- Déplacer ce spec + `TRIAGE.md` (Phase 1) dans `docs/superpowers/specs/` du fork et committer.
- Vérifier présence `LICENSE` (MIT, conservé) et mention du fork + crédit amont dans le README
  (sera complété en Phase 4 ; note minimale ajoutée dès la Phase 0).
- Ne PAS committer d'artefacts de build (`build/`, `SourcePackages/`, `Build/`) — vérifier
  le `.gitignore` amont, compléter si besoin.

---

## 5. Phase 1 — Triage

### 5.1 Méthode
Pour **chaque** PR ouverte (22) et **chaque** issue ouverte (38) :
- récupérer le diff / le corps via `gh pr view` / `gh issue view` ;
- lire le code (pour les PR) afin de juger qualité, périmètre, conflits réels.

### 5.2 Schéma `TRIAGE.md`

**Section PR** — une ligne par PR :

| Col | Valeurs |
|---|---|
| PR | `#N` + titre + auteur |
| Feature | bucket concerné (dict/boost, privacy, fiabilité, IA, clipboard, infra, autre) |
| État amont | `MERGEABLE` / `CONFLICTING` |
| Verdict | `merge-clean` / `adapt-rebase` / `superseded-by #X` / `reject` |
| Raison | 1 phrase (pourquoi ce verdict ; si reject/superseded, justifier) |

**Arbitrage des PR concurrentes** (lecture du code des deux/trois, choix d'un gagnant) :
- Post-traitement IA : `#106` (on-device LLM) vs `#119` (Ollama) vs `#134` (llama.cpp grammar).
- Dictionnaire/boost : `#149` (custom dictionary) vs `#142` (Parakeet word boosting).
- Pause/reprise audio : `#126` vs `#49` (+ issue #131).
- Nettoyage/rétention enregistrements : `#148` vs `#47`.
- Critères de choix : propreté du code, périmètre minimal, compat moteurs (Whisper + Parakeet),
  s'applique au master actuel, tests présents.

**Section Issues** — une ligne par issue :

| Col | Valeurs |
|---|---|
| Issue | `#N` + titre |
| Type | `bug` / `feature` / `doublon-de #X` / `déjà-corrigé` / `wontfix` |
| Lien PR | PR qui la traite (le cas échéant) |
| Priorité | P0 (casse l'usage) / P1 (gênant) / P2 (confort) |

### 5.3 Livrable
- `TRIAGE.md` committé dans le fork.
- **Backlog priorisé** groupé par les 4 buckets + bugfixes, qui devient l'entrée des specs
  des sous-phases 3a-3d et de la phase 2.
- Phase 1 = **analyse seulement** : aucun code feature écrit, aucune PR mergée à ce stade.

---

## 6. Non-objectifs (Phase 0+1)
- Pas d'écriture de code de feature.
- Pas de merge de PR (même « clean ») — ça commence en Phase 2.
- Pas de signature/notarisation ni de release (Phase 4).
- Pas de refactoring non lié à un build break.

## 7. Risques & mitigations
| Risque | Mitigation |
|---|---|
| Build casse sous Xcode 26/Swift 6.2 | Corrections ciblées `fix(build):`, systematic-debugging |
| `whisper.h` manquant (#71) | Init submodules en prérequis dur, vérifié avant build |
| `gh repo fork --org` indisponible | Fallback `gh api` / création + transfert |
| PR concurrentes mal arbitrées | Lecture effective du code des deux côtés avant verdict, justification écrite |
| Compte Apple Dev (Phase 4) | Hors périmètre ici ; local = ad-hoc signing, non bloquant |

## 8. Point ouvert
- Compte Apple Developer (~99 $/an) pour la notarisation des releases publiques (Phase 4).
  À trancher avant la Phase 4, pas avant.
