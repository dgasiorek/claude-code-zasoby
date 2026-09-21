# Konwencje zespołowe CN (Content Networks)

Reguły obowiązujące we wszystkich projektach CN, niezależnie od stacka.

## 1. Język

- Wszystko co czyta człowiek — commity, opisy MR, dokumentacja, Javadoc, komentarze, nazwy testów, rozmowa — PO POLSKU
- Identyfikatory, nazwy plików, klucze konfiguracyjne, kontrakty zewnętrzne (API, nagłówki) — PO ANGIELSKU

## 2. Commity i wersjonowanie

- Format commita: `<hasło>: DEV-XXX <opis po polsku>` (np. `fix: DEV-840 poprawka mapowania kategorii`)
- Hasła sterują automatycznym release'em per serwis:
  - `feature:` / `feat:` → minor
  - `fix:` / `hotfix:` / `perf:` / `refactor:` → patch
  - `!` po haśle lub stopka `BREAKING CHANGE` → major
  - `chore:` / `docs:` / `test:` / `style:` / `build:` / `ci:` (lub brak hasła) → bez release'u
- Wersje bumpuje pipeline (version-first, `versions:set`) — NIGDY nie edytuj `<version>` ręcznie
- Tagi release'ów: `<serwis>/vX.Y.Z`; scope commita opcjonalny (pipeline wykrywa serwis po ścieżkach)
- NIE commituj ani nie pushuj bez wyraźnego polecenia użytkownika; `git add` bez `docs/*.md` chyba że zmiana ich dotyczy

## 3. Gałęzie

- Trunk: `dev` (cn-mediaconnector) lub `main` (pozostałe repozytoria) — sprawdź `origin/HEAD` zanim założysz branch
- Feature branch: `DEV-XXX-krotki-opis` (numer ticketa Jira z projektu DEV)

## 4. Styl pracy agenta

- Minimalny diff — zmieniaj tylko to, co potrzebne do zadania
- ŻADNYCH nowych komentarzy w kodzie
- Clean Code + pragmatyczny SOLID; pytaj zanim "ulepszysz" coś poza zakresem zadania
- Jeśli w projekcie istnieją `CLAUDE.md`, `AGENTS.md` i `.github/copilot-instructions.md` — trzymaj je bajt-w-bajt identyczne przy każdej zmianie któregokolwiek

## 5. CI/CD i infrastruktura

- CI to GitLab CI z centralnymi szablonami w `fuse/cn-mediaconnector-do` (konsumowane przez `include:`) — zmiany wspólne trafiają do repo szablonów, nie do projektów
- Artefakty: Nexus `registry.adscreen.net:8443` (creds w `~/.m2/settings.xml` — NIGDY w repo); obrazy: `registry.adscreen.net:9092`
- Upgrade biblioteki współdzielonej (np. `com.cn.fuse.common:consul`) propaguje się do konsumentów przez manualny job `propagate` w pipeline biblioteki

## 6. Dokumentacja

- Zmiana API / konfiguracji / builda = aktualizacja `README.md`/`docs/` w TEJ SAMEJ zmianie
- Decyzje architektoniczne przekrojowe = krótka notka ADR w `docs/`
- Nazewnictwo dokumentów: `YYYY-MM-DD-<slug>.md`
