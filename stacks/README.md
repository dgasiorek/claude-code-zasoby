# stacks/ — warstwa stosu nakładana na maszynerię z upstreamu

To repo (`dgasiorek/claude-code-zasoby`) jest forkiem `AIBiz-Automatyzacje/claude-code-starter`.
Upstream dowozi maszynerię `.claude/` napisaną pod **React 19 + Supabase**. Projekty, które ją
konsumują, stoją na innych stosach (`cn-projects`: Vue 3 + Spring Boot; `gio-projects`: Vue 3 +
Capacitor + NestJS + Python/C++). Ten katalog trzyma różnicę — nakładaną deterministycznie,
po każdym zaciągnięciu upstreamu.

## Dlaczego overlay, a nie seria patchy

`git format-patch` / `git apply` konfliktuje przy **każdym** dotknięciu pliku w upstreamie i przy
niepowodzeniu zostawia drzewo w połowie stanu — a to drzewo jest tym, co projekty zaciągają
`/sync-template`. Overlay bierze plik na własność: nałożenie jest deterministyczne i idempotentne,
więc nigdy nie ma „częściowo zaaplikowanego" stosu. Jedyne, co tracimy względem patchy —
informację „upstream ruszył plik, którego kopię trzymasz" — odzyskuje `baseline.sha256`:
ta sama wiedza, ale jako raport przed publikacją, nie jako konflikt w środku aplikowania.

## Podział własności (łam to i wracasz do forka, który nie umie się zsynchronizować)

| Co | Gdzie | Kto właścicielem |
|---|---|---|
| maszyneria workflow | `.claude/**` na gałęzi `main` | **upstream** — nigdy nie edytuj tego w `main` |
| warstwa stosu | `stacks/<id>/**` | ten fork |
| narzędzie nakładające | `tools/apply-stack.sh` | ten fork |
| gotowy produkt dla projektów | gałąź `stack/<id>` | generowana, nigdy edytowana ręcznie |

`main` jest czystym lustrem upstreamu **plus** `stacks/` i `tools/` (katalogi, których upstream
nie ma, więc merge z upstreamu ich nie dotyka i nie konfliktuje).

## Pętla po każdym synchronie

```bash
# 1. zaciągnij upstream do main (jednorazowa konfiguracja: git remote add upstream <url>)
git fetch upstream && git checkout main && git merge upstream/main
#    Zwykły merge, NIE --ff-only: main ma własne commity (stacks/, tools/, .github/), więc nie jest
#    już potomkiem upstreamu. Konfliktu nie będzie, bo upstream nie dotyka tych katalogów —
#    a jeśli kiedyś dotknie, konflikt jest dokładnie tym sygnałem, który chcesz zobaczyć.

# 2. sprawdź, czy overlay nadal pasuje do nowego upstreamu
tools/apply-stack.sh --stack vue-spring            # STATUS: OK  albo  WYMAGA_PRZEGLADU (kod 3)

# 3a. STATUS: OK  -> zbuduj gałąź, z której korzystają projekty
tools/apply-stack.sh --stack vue-spring --publish --push

# 3b. WYMAGA_PRZEGLADU -> raport mówi, co przejrzeć; skrypt podaje gotową komendę:
git diff $(cat stacks/vue-spring/base.ref) main -- .claude/agents/feature-builder-ui.md
#    przenieś zmiany upstreamu do stacks/vue-spring/files/..., potem:
tools/apply-stack.sh --stack vue-spring --accept-drift
tools/apply-stack.sh --stack vue-spring --publish --push
```

Krok 2–3 robi też GitHub Action (`.github/workflows/stack.yml`) na każdy push do `main`:
publikuje gałęzie stosów albo czerwieni się na drifcie.

## Jak projekt konsumuje gałąź stosu

`/sync-template` w projekcie klonuje repo wskazane zmiennymi środowiskowymi — domyślnie upstream.
Przekierowanie na ten fork i gałąź stosu wpisz do **`.claude/settings.local.json`**, bo to jedyny
plik, którego `sync-template.sh` nigdy nie nadpisuje (`EXCLUDE_PATHS`):

```json
{
  "env": {
    "TEMPLATE_REPO_URL": "https://github.com/dgasiorek/claude-code-zasoby.git",
    "TEMPLATE_BRANCH": "stack/vue-spring"
  }
}
```

Po synchronie projekt ma w `.claude/.stack-applied` informację, z jakiego stosu i z jakiego commitu
upstreamu pochodzi jego maszyneria.

## Format `overlay.tsv`

Kolumny rozdzielone **tabem**: `<op>` `<cel w .claude/>` `<źródło w stacks/<id>/>`.

| op | znaczenie | baseline |
|---|---|---|
| `replace` | bierzemy plik upstreamu na własność | tak |
| `new` | plik, którego upstream nie ma (kolizja = błąd, sygnał żeby zmienić na `replace`) | nie |
| `append` | fragment dopisywany między markerami `<!-- stack:<id>:start/end -->`, idempotentnie | tak |
| `delete` | usuwamy plik upstreamu; cel z ukośnikiem = **cały katalog** | tak |

`baseline.sha256` trzyma sha256 **upstreamowej** wersji każdego celu z chwili, gdy override był
ostatnio przeglądany, a `base.ref` — commit, względem którego to było. Stąd wykrywanie driftu:
zmiana pliku u góry nie psuje drzewa, tylko zapala raport. Cel katalogowy hashuje listing drzewa,
więc dorzucenie nowego pliku do kasowanego skilla też wychodzi jako drift (inaczej React wyciekłby
do projektów Vue przy pierwszej okazji).

Kody wyjścia: `0` OK, `2` błąd użycia/manifestu, `3` wymaga przeglądu człowieka.

## Znane luki (do zgłoszenia upstreamowi, nie do obejścia tutaj)

1. `.claude/workflows/freshness-audit-wf.js` ma listę `DOMYSLNE_SKILLE` zaszytą pod React/Supabase.
   Nadpisywanie 1000-linijkowego workflowu dla pięciu linii się nie opłaca — uruchamiaj
   `/freshness-audit` z zawężeniem (`args.skille`) na skille stosu, a upstreamowi zgłoś czytanie
   tej listy z `.claude/.stack-applied`.
2. `dev-autopilot-wf.js` ma zaszyte `vite build`, rozgrzewkę `vitest`, dev server na `:5173`
   i `supabase db push` w db-sync. Docelowo: komendy walidacyjne w pliku kontraktu projektu
   (`.claude/stack/commands.json`), czytane przez workflow.
3. Bramki git zakładają jedno repo w katalogu projektu. `cn-projects` i `gio-projects` to
   workspace'y z kilkoma repo i workspace root **nie jest** repozytorium — potrzebna mapa repo.

## Nowy stos

1. `mkdir -p stacks/<id>/{files,fragments}` i wrzuć pliki stosu pod ścieżkami docelowymi
   (`files/.claude/...`).
2. Napisz `overlay.tsv`.
3. `tools/apply-stack.sh --stack <id> --accept-drift` — pierwsza akceptacja baseline; wcześniej
   **przeczytaj** każdy plik upstreamu, który bierzesz na własność, i przenieś z niego to, co nie
   jest stosem (inaczej zamrażasz starą wersję i tracisz poprawki upstreamu).
4. `tools/apply-stack.sh --stack <id> --publish --push`.
5. `node --test tools/__tests__/apply-stack.test.mjs` przed commitem.
