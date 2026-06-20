# OpenSuperWhisper Fork — Foundation (Phase 0 + 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Établir un fork public `my-monkeys/OpenSuperWhisper` qui build et tourne en local, puis produire un triage écrit exhaustif des 22 PR et 38 issues ouvertes.

**Architecture:** Phase 0 = opérations git/toolchain + build de validation (pas de code feature). Phase 1 = analyse pure produisant `TRIAGE.md` + backlog priorisé. Chaque tâche se termine par une vérification objective (commande + sortie attendue) tenant lieu de « test », car ces phases sont ops + analyse, pas du TDD applicatif.

**Tech Stack:** Swift 6.2 / SwiftUI, Xcode 26.1.1, Apple Silicon (arm64), whisper.cpp + FluidAudio/Parakeet (submodules), Rust/cargo (asian-autocorrect), cmake + libomp, `gh` CLI.

## Global Constraints

- **Plateforme** : macOS Apple Silicon (arm64) uniquement. Toolchain : Xcode 26.1.1, Swift 6.2.
- **Build local** : signature **ad-hoc** (`CODE_SIGNING_ALLOWED=NO`) — aucun compte Apple Dev requis dans ces phases.
- **Licence** : MIT conservée à l'identique. Le fork préserve le lien amont (`upstream` = Starmel/OpenSuperWhisper).
- **Attribution publique** : tout texte visible (README, descriptions, annonces) attribue à « My-Monkey » / le collectif — **jamais** de nom réel, jamais « basé à Montpellier ».
- **Pas d'artefacts de build committés** : `build/`, `Build/`, `SourcePackages/`, `libwhisper/build/`, `asian-autocorrect/target/` restent gitignored.
- **Triage = analyse seulement** : aucune PR mergée, aucun code feature écrit avant la Phase 2.
- **Chemins** : le fork est cloné dans `/Users/maxim/Documents/my-monkey/OpenSuperWhisper` (ci-après `$REPO`).
- **Identité des commits** : auteur = `MaximCosta <91082344+MaximCosta@users.noreply.github.com>`, fixé en config git **locale** du repo (Task 1). **Aucune mention de Claude / d'IA** dans les noms d'auteur, les messages ou les trailers — repo public, on ne veut pas dissuader les contributeurs. Les apports issus de PR amont créditent leur auteur via `Co-authored-by: <auteur PR>` (phases 2+ uniquement).
- **Rôle & rigueur** : Claude est le **mainteneur principal** (valide les PR, traite les issues, teste). Rigueur maximale : tout changement de code est testé et vérifié (preuve avant de déclarer « fait »). En cas de doute réel sur une PR → demander à Maxim. Avancer en autonome par défaut.

---

## File Structure

Créés / modifiés pendant ces phases :

- `$REPO/` — le clone du fork (créé Task 1).
- `$REPO/.gitignore` — complété si des artefacts de build ne sont pas ignorés (Task 4).
- `$REPO/README.md` *(`Readme.md`)* — note minimale « fork maintenu par My-Monkey » + crédit amont (Task 4).
- `$REPO/docs/superpowers/specs/2026-06-21-opensuperwhisper-fork-foundation-design.md` — la spec, déplacée depuis `osw-planning/` (Task 4).
- `$REPO/docs/superpowers/plans/2026-06-21-opensuperwhisper-fork-foundation-plan.md` — ce plan, déplacé depuis `osw-planning/` (Task 4).
- `$REPO/TRIAGE.md` — livrable de la Phase 1 (Tasks 6-8).
- `/tmp/osw-triage-raw/` — dumps bruts des PR/issues pour analyse (Task 5, non committé).

Branche de travail : `chore/fork-foundation` (les commits de fondation + triage y vivent ; fast-forward vers `master` possible ensuite).

---

## PHASE 0 — Fork & baseline

### Task 1 : Fork + clone + remotes

**Files:**
- Create: `$REPO/` (clone)

**Interfaces:**
- Produces: un repo git local en `$REPO` avec `origin` = fork my-monkeys, `upstream` = Starmel.

- [ ] **Step 1 : Vérifier l'accès à l'org et l'absence de fork existant**

Run:
```bash
gh api orgs/my-monkeys -q .login
gh repo view my-monkeys/OpenSuperWhisper --json name 2>&1 | head -1
```
Expected : la 1ʳᵉ commande affiche `my-monkeys`. La 2ᵉ affiche une erreur `Could not resolve to a Repository` (= pas encore de fork). Si le fork existe déjà, sauter le Step 2 et cloner directement.

- [ ] **Step 2 : Créer le fork dans l'org (sans cloner)**

Run:
```bash
gh repo fork Starmel/OpenSuperWhisper --org my-monkeys --fork-name OpenSuperWhisper --clone=false
```
Expected : `✓ Created fork my-monkeys/OpenSuperWhisper`. Attendre 2-3 s que GitHub matérialise le fork.

- [ ] **Step 3 : Cloner le fork dans le chemin cible**

Run:
```bash
git clone git@github.com:my-monkeys/OpenSuperWhisper.git /Users/maxim/Documents/my-monkey/OpenSuperWhisper
```
Expected : clone réussi, `master` checkout.

- [ ] **Step 4 : Ajouter le remote upstream + brancher**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
git remote add upstream https://github.com/Starmel/OpenSuperWhisper.git
git fetch upstream
git checkout -b chore/fork-foundation
git remote -v
```
Expected : `git remote -v` liste `origin … my-monkeys/OpenSuperWhisper` (fetch+push) **et** `upstream … Starmel/OpenSuperWhisper` (fetch+push). Branche courante `chore/fork-foundation`.

- [ ] **Step 5 : Fixer l'identité d'auteur en config locale (pas de mention IA)**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
git config user.name "MaximCosta"
git config user.email "91082344+MaximCosta@users.noreply.github.com"
git config --local --get user.name && git config --local --get user.email
```
Expected : `MaximCosta` puis `91082344+MaximCosta@users.noreply.github.com`. Tous les commits de ce repo utiliseront cette identité, jamais l'identité globale ni de trailer Claude.

- [ ] **Step 6 : Pas de commit ici** (rien à committer tant que les fichiers ne bougent pas — le clone est l'état initial).

---

### Task 2 : Submodules + toolchain

**Files:** aucun fichier source modifié (installation d'outils + checkout submodules).

**Interfaces:**
- Consumes: `$REPO` de la Task 1.
- Produces: submodules initialisés (`libwhisper/whisper.cpp`, `asian-autocorrect`), `libomp` + `rust` + `xcpretty` installés.

- [ ] **Step 1 : Initialiser les submodules (prérequis dur — sinon `whisper.h` manquant, cf. issue #71)**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
git submodule update --init --recursive
```
Expected : checkout de `libwhisper/whisper.cpp` et `asian-autocorrect`.

- [ ] **Step 2 : Vérifier que `whisper.h` est bien présent**

Run:
```bash
ls libwhisper/whisper.cpp/include/whisper.h 2>/dev/null || ls libwhisper/whisper.cpp/whisper.h 2>/dev/null
```
Expected : un chemin valide s'affiche (le header existe). Si rien → le submodule n'est pas init, revenir au Step 1.

- [ ] **Step 3 : Installer les dépendances toolchain manquantes**

Run:
```bash
brew install libomp rust
gem install xcpretty
```
Expected : `libomp`, `rust` (donc `cargo`) installés ; `xcpretty` installé (si `gem install` échoue pour cause de permissions système, réessayer avec `gem install --user-install xcpretty` ou ignorer — `xcpretty` est optionnel).

- [ ] **Step 4 : Vérifier la toolchain**

Run:
```bash
cargo --version && cmake --version | head -1 && ls /opt/homebrew/opt/libomp/lib/libomp.dylib
```
Expected : version de cargo, version de cmake, et le chemin de `libomp.dylib` s'affichent sans erreur.

- [ ] **Step 5 : Pas de commit** (aucun fichier du repo modifié).

---

### Task 3 : Build, test suite, et smoke transcription

**Files:**
- Modify (potentiellement) : fichiers Swift cassés par Xcode 26 / Swift 6.2 (inconnus a priori — boucle de correction).

**Interfaces:**
- Consumes: repo + submodules + toolchain (Tasks 1-2).
- Produces: un build Debug fonctionnel + preuve que la transcription marche.

- [ ] **Step 1 : Premier build via le script de référence**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
./run.sh build 2>&1 | tail -40
```
Expected (cas idéal) : se termine par `Building successful!`.

- [ ] **Step 2 : Si BUILD FAILED → boucle de correction (systematic-debugging)**

Si la sortie contient `BUILD FAILED` :
1. Invoquer la skill `superpowers:systematic-debugging`.
2. Repérer la **première** erreur réelle (souvent durcissement concurrence Swift 6 : `Sendable`, `@MainActor`, capture d'`actor`, ou API dépréciée).
3. Appliquer le **fix minimal** sur le fichier concerné (pas de refactor large).
4. Relancer `./run.sh build 2>&1 | tail -40`.
5. Répéter jusqu'à `Building successful!`.
6. Committer chaque correctif ciblé :
```bash
git add <fichier(s) corrigé(s)>
git commit -m "fix(build): <description courte du fix Swift 6.2>"
```
Expected final : `./run.sh build` aboutit à `Building successful!`.

- [ ] **Step 3 : Lancer la suite de tests existante (validation automatisée du baseline)**

Run:
```bash
xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tail -30
```
Expected : `** TEST SUCCEEDED **`. Si des tests échouent à cause de l'environnement (et non du code), noter lesquels et pourquoi ; ne pas masquer un échec réel.

- [ ] **Step 4 : Smoke transcription (vérification manuelle GUI — critère de sortie clé)**

Run pour lancer l'app :
```bash
./run.sh 2>&1 &
```
Puis **manuellement** : glisser-déposer `jfk.wav` (à la racine du repo) dans la fenêtre de l'app, ou utiliser le menu d'import de fichier audio.
Expected : la transcription affiche le texte attendu (≈ « And so my fellow Americans, ask not what your country can do for you… »). Capturer le résultat (capture d'écran ou copie du texte produit).

> Pourquoi manuel : il n'existe pas encore de CLI (cf. issue #150). Cette étape requiert l'interaction GUI. Si Maxim est absent, la suite de tests du Step 3 reste la preuve automatisée minimale ; le smoke GUI peut être confirmé par Maxim.

- [ ] **Step 5 : Quitter l'app**

Run:
```bash
osascript -e 'quit app "OpenSuperWhisper"' 2>/dev/null || pkill -f OpenSuperWhisper.app || true
```
Expected : l'app se ferme.

---

### Task 4 : Hygiène repo + relocalisation des docs + premier push

**Files:**
- Modify: `$REPO/.gitignore`
- Modify: `$REPO/Readme.md`
- Create: `$REPO/docs/superpowers/specs/2026-06-21-opensuperwhisper-fork-foundation-design.md`
- Create: `$REPO/docs/superpowers/plans/2026-06-21-opensuperwhisper-fork-foundation-plan.md`

**Interfaces:**
- Consumes: build vert (Task 3).
- Produces: repo propre, spec + plan versionnés dans le fork, branche poussée sur `origin`.

- [ ] **Step 1 : Vérifier que les artefacts de build sont ignorés**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
git status --porcelain | grep -E '^\?\?' | grep -E 'build/|Build/|SourcePackages/|libwhisper/build/|asian-autocorrect/target/' || echo "OK: rien d'untracked côté build"
```
Expected : `OK: rien d'untracked côté build`. Sinon, ajouter les chemins manquants à `.gitignore` :
```
build/
Build/
SourcePackages/
libwhisper/build/
asian-autocorrect/target/
```

- [ ] **Step 2 : Ajouter une note de fork au README (attribution My-Monkey, crédit amont)**

Ajouter en tête de `Readme.md`, juste après le titre `# OpenSuperWhisper`, le bloc suivant :
```markdown
> **Fork maintenu par [My-Monkey](https://my-monkey.fr).** Successeur communautaire de
> [`Starmel/OpenSuperWhisper`](https://github.com/Starmel/OpenSuperWhisper) (MIT), repris pour
> intégrer les contributions en attente et continuer le développement. Merci à l'auteur d'origine
> et à tous les contributeurs — les apports intégrés créditent leurs auteurs.
```

- [ ] **Step 3 : Déplacer la spec et le plan dans le repo**

Run:
```bash
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp /Users/maxim/Documents/my-monkey/osw-planning/2026-06-21-opensuperwhisper-fork-foundation-design.md docs/superpowers/specs/
cp /Users/maxim/Documents/my-monkey/osw-planning/2026-06-21-opensuperwhisper-fork-foundation-plan.md docs/superpowers/plans/
```
Expected : les deux fichiers présents sous `docs/superpowers/`.

- [ ] **Step 4 : Committer la fondation**

Run:
```bash
git add .gitignore Readme.md docs/
git commit -m "chore: établir le fork My-Monkey (docs de fondation, note README)"
```
Expected : commit créé sur `chore/fork-foundation`.

- [ ] **Step 5 : Pousser la branche sur le fork**

Run:
```bash
git push -u origin chore/fork-foundation
```
Expected : branche poussée, URL de PR affichée par GitHub.

---

## PHASE 1 — Triage

### Task 5 : Dump brut de toutes les PR et issues

**Files:**
- Create: `/tmp/osw-triage-raw/` (non committé)

**Interfaces:**
- Produces: un dossier avec le corps + diff de chaque PR et le corps de chaque issue, prêt à analyser.

- [ ] **Step 1 : Lister et figer les numéros de PR et d'issues ouvertes**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
mkdir -p /tmp/osw-triage-raw
gh pr list --repo Starmel/OpenSuperWhisper --state open --limit 100 --json number --jq '.[].number' | sort -n > /tmp/osw-triage-raw/pr-numbers.txt
gh issue list --repo Starmel/OpenSuperWhisper --state open --limit 200 --json number --jq '.[].number' | sort -n > /tmp/osw-triage-raw/issue-numbers.txt
wc -l /tmp/osw-triage-raw/pr-numbers.txt /tmp/osw-triage-raw/issue-numbers.txt
```
Expected : ~22 PR, ~38 issues (les comptes peuvent avoir bougé — utiliser les comptes réels comme référence pour la complétude).

- [ ] **Step 2 : Dumper chaque PR (corps + diff)**

Run:
```bash
while read n; do
  gh pr view "$n" --repo Starmel/OpenSuperWhisper --json number,title,author,body,mergeable,additions,deletions,files \
    > "/tmp/osw-triage-raw/pr-$n.json"
  gh pr diff "$n" --repo Starmel/OpenSuperWhisper > "/tmp/osw-triage-raw/pr-$n.diff" 2>/dev/null || echo "diff indisponible pour #$n"
done < /tmp/osw-triage-raw/pr-numbers.txt
ls /tmp/osw-triage-raw/pr-*.json | wc -l
```
Expected : un `.json` (+ `.diff` quand dispo) par PR ; le compte de `.json` == nombre de PR.

- [ ] **Step 3 : Dumper chaque issue (corps + commentaires)**

Run:
```bash
while read n; do
  gh issue view "$n" --repo Starmel/OpenSuperWhisper --json number,title,body,labels,comments \
    > "/tmp/osw-triage-raw/issue-$n.json"
done < /tmp/osw-triage-raw/issue-numbers.txt
ls /tmp/osw-triage-raw/issue-*.json | wc -l
```
Expected : un `.json` par issue ; le compte == nombre d'issues.

- [ ] **Step 4 : Pas de commit** (données brutes temporaires, hors repo).

---

### Task 6 : `TRIAGE.md` — section PR (avec arbitrage des PR concurrentes)

**Files:**
- Create: `$REPO/TRIAGE.md`

**Interfaces:**
- Consumes: dumps de la Task 5.
- Produces: la section PR de `TRIAGE.md` avec un verdict justifié par PR.

- [ ] **Step 1 : Lire les PR et remplir le tableau PR**

Pour chaque PR (lire `pr-$n.json` + `pr-$n.diff`), écrire une ligne dans `TRIAGE.md` sous l'en-tête :
```markdown
# TRIAGE — OpenSuperWhisper fork (2026-06-21)

## Pull Requests

| PR | Feature (bucket) | État amont | Verdict | Raison |
|---|---|---|---|---|
| #149 Custom dictionary (AlexCherrypi) | dict/boost | MERGEABLE | … | … |
```
Buckets autorisés : `dict/boost`, `privacy`, `fiabilité`, `IA`, `clipboard`, `infra`, `autre`.
Verdicts autorisés : `merge-clean`, `adapt-rebase`, `superseded-by #X`, `reject`.

- [ ] **Step 2 : Arbitrer les groupes de PR concurrentes (lecture effective du code des deux/trois côtés)**

Lire et comparer le code, puis désigner un gagnant + justifier dans une sous-section :
```markdown
## Arbitrages (PR concurrentes)

### Post-traitement IA — #106 vs #119 vs #134
Gagnant : #___ — raison : ___ . Rejetés : #___, #___ (raison).

### Dictionnaire / boost — #149 vs #142
Gagnant : #___ — raison : ___ .

### Pause/reprise audio — #126 vs #49 (+ issue #131)
Gagnant : #___ — raison : ___ .

### Nettoyage / rétention enregistrements — #148 vs #47
Gagnant : #___ — raison : ___ .
```
Critères (rappel spec) : propreté du code, périmètre minimal, compat Whisper **et** Parakeet, applicabilité au master actuel, présence de tests.

- [ ] **Step 3 : Vérifier la complétude PR (gate objectif)**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
while read n; do grep -q "#$n " TRIAGE.md || echo "MANQUE PR #$n"; done < /tmp/osw-triage-raw/pr-numbers.txt
echo "--- fin du contrôle PR ---"
```
Expected : aucune ligne `MANQUE PR #…` avant `--- fin du contrôle PR ---`.

- [ ] **Step 4 : Pas de commit encore** (on committe `TRIAGE.md` complet en Task 8).

---

### Task 7 : `TRIAGE.md` — section issues + backlog priorisé

**Files:**
- Modify: `$REPO/TRIAGE.md`

**Interfaces:**
- Consumes: dumps issues (Task 5) + section PR (Task 6).
- Produces: section issues + backlog priorisé par bucket.

- [ ] **Step 1 : Remplir le tableau des issues**

Ajouter à `TRIAGE.md` :
```markdown
## Issues

| Issue | Type | Lien PR | Priorité |
|---|---|---|---|
| #117 Silent failure… | bug | #132 | P0 |
```
Types : `bug`, `feature`, `doublon-de #X`, `déjà-corrigé`, `wontfix`.
Priorités : `P0` (casse l'usage), `P1` (gênant), `P2` (confort).

- [ ] **Step 2 : Écrire le backlog priorisé par bucket**

Ajouter :
```markdown
## Backlog priorisé (entrée des phases 2-3)

### Phase 2 — Quick wins
- [ ] (PR …) …

### 3a — Dictionnaire / boost mots-clés
- [ ] base : PR #___ ; complément : ___ ; issues couvertes : #19, …

### 3b — Confidentialité & cycle de vie
- [ ] base : #148 (rétention) + #121 (désactiver historique) + #125 (start hidden) ; issues : #144, …

### 3c — Fiabilité & UX
- [ ] #90 paste non-US ; #139 modèle actif ambigu ; #117/#132 feedback erreur ; …

### 3d — Post-traitement IA
- [ ] implém choisie : PR #___ ; issues : #55 (hooks), #14 (router), …

### Feature neuve — clipboard-fallback
- [ ] toujours copier la transcription au presse-papier (issue #80), par-dessus #133 ; tenir compte de la race #129.
```

- [ ] **Step 3 : Vérifier la complétude issues (gate objectif)**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
while read n; do grep -q "#$n " TRIAGE.md || echo "MANQUE ISSUE #$n"; done < /tmp/osw-triage-raw/issue-numbers.txt
echo "--- fin du contrôle issues ---"
```
Expected : aucune ligne `MANQUE ISSUE #…`.

---

### Task 8 : Committer le triage + synthèse

**Files:**
- Modify: `$REPO/TRIAGE.md`

**Interfaces:**
- Consumes: `TRIAGE.md` complet (Tasks 6-7).
- Produces: triage versionné + poussé, prêt à servir d'entrée aux specs des phases features.

- [ ] **Step 1 : Ajouter une synthèse en tête de `TRIAGE.md`**

Insérer juste sous le titre un résumé chiffré :
```markdown
> **Synthèse** : N PR au total — X merge-clean, Y adapt-rebase, Z superseded, W reject.
> M issues — A bugs (dont P0 : …), B features, C doublons/déjà-corrigé.
> Gagnants des features concurrentes : IA #__, boost #__, audio #__, rétention #__.
```

- [ ] **Step 2 : Committer et pousser**

Run:
```bash
cd /Users/maxim/Documents/my-monkey/OpenSuperWhisper
git add TRIAGE.md
git commit -m "docs: triage exhaustif des 22 PR et 38 issues amont"
git push origin chore/fork-foundation
```
Expected : commit poussé sur `origin/chore/fork-foundation`.

- [ ] **Step 3 : Restituer la synthèse à Maxim**

Présenter le résumé chiffré + les 4 gagnants d'arbitrage, et proposer d'enchaîner sur le brainstorming de la première sous-phase feature (typiquement 3a ou Phase 2 quick wins).

---

## Self-Review (rempli par l'auteur du plan)

**Couverture spec :**
- Fork + remotes (spec §4.1) → Task 1 ✓
- Submodules + piège #71 (§4.2) → Task 2 ✓
- Deps toolchain (§4.3) → Task 2 ✓
- Build ad-hoc + fix Swift 6.2 (§4.4) → Task 3 ✓
- Critères de sortie : build vert + app lancée + jfk.wav (§4.5) → Task 3 (Steps 1-4) ✓
- Hygiène repo + relocaliser docs (§4.6) → Task 4 ✓
- Méthode triage + schéma (§5.1-5.2) → Tasks 5-7 ✓
- Arbitrage PR concurrentes (§5.2) → Task 6 Step 2 ✓
- Livrable TRIAGE.md + backlog (§5.3) → Tasks 6-8 ✓
- Non-objectifs (§6) → repris dans Global Constraints ✓

**Placeholders :** les `…` / `#___` des Tasks 6-7 sont des **champs à remplir par l'analyse** (les valeurs n'existent pas avant lecture du code), pas des trous de plan — leur schéma et leurs valeurs autorisées sont entièrement spécifiés. Acceptable.

**Cohérence des types/chemins :** `$REPO` = `/Users/maxim/Documents/my-monkey/OpenSuperWhisper` partout ; branche `chore/fork-foundation` cohérente Tasks 1/4/8 ; `/tmp/osw-triage-raw/` cohérent Tasks 5-7.
