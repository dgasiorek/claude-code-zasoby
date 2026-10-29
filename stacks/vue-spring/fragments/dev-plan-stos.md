## Stos projektu (Vue 3 + Spring Boot)

Sekcję dopisuje `tools/apply-stack.sh --stack vue-spring`. Punkty niżej zastępują odpowiadające im miejsca skilla wyżej, które zakładają React i Supabase; reszta skilla obowiązuje bez zmian.

### 1.6 Krok A — klasyfikacja

Feature dotyka UI, gdy wymagania opisują ekrany, komponenty, layouty, nawigację, animacje albo stany widoczne dla użytkownika, lub research wskazuje pliki `*.vue` w `src/components/` i `src/views/`, composables prezentacyjne w `src/composables/`, `*.css` albo `src/assets/`. Praca w `src/main/java/`, `src/main/resources/db/migration/`, `application*.yml`, `pom.xml`, testach i konfiguracji to pure-data.

### 3.4 Pole Weryfikacja

Komendy bierzesz z `package.json` i `pom.xml` modułu, którego dotyczy IU: front `pnpm type-check` (vue-tsc) i `pnpm vitest run <ścieżka>`, backend `mvn -f <moduł>/ test -Dtest=<Klasa>`. Pełny `mvn -f <moduł>/ clean verify` (checkstyle, JaCoCo) zostawiasz domknięciu fazy.

### 3.5 Builder IU

Tabela zastępuje tabelę z 3.5:

| Pliki IU | Delegate to | Skills in play |
|---|---|---|
| tylko UI: `*.vue` w `src/components/` i `src/views/`, composables prezentacyjne w `src/composables/`, `*.css`, `src/assets/` | `feature-builder-ui` | vue-tailwind-guidelines, ux-ui-guidelines |
| tylko backend: `src/main/java/`, `src/main/resources/db/migration/`, `src/test/java/`, `application*.yml`, `pom.xml` | `feature-builder-data` | spring-boot-guidelines, security, observability-guidelines |
| kontrakt API w obu warstwach (rekord DTO + endpoint + wrapper w `src/api.ts` + komponent) | `feature-builder-fullstack` | vue-tailwind-guidelines, ux-ui-guidelines, spring-boot-guidelines, security, observability-guidelines |

Wrapper w `src/api.ts` z typami odwzorowującymi DTO idzie do IU, która zmienia kontrakt: z endpointem w tej samej IU — `feature-builder-fullstack`; do istniejącego endpointu, bez zmian w backendzie — `feature-builder-ui`. W workspace z wieloma repo IU nie łączy plików dwóch repo, chyba że zmienia kontrakt, który oba czytają — wtedy tabela plików podaje repo przy każdej ścieżce. Warianty `-figma` wybiera planner fazy jak wyżej.

### 3.6 Tabela plików

- `plan.mjs linie` i progi 300/360 dotyczą plików JS/TS. Dla `*.vue` liczysz linie bloku `<script setup>`, a dla `*.java` wpisujesz linie z `wc -l`; próg rozmiaru w Javie pilnuje checkstyle w `mvn verify`, więc ocenę wymiarów robisz przy tych samych progach co dla TS.
- Test Javy (`src/test/java/**/*Test.java`, `*IT.java`) ma w tabeli akcję `Test (unit)`, bo walidacja planu rozpoznaje plik testu po akcji albo po rozszerzeniu JS/TS.
- Migracja Flyway (`src/main/resources/db/migration/V<nr>__opis.sql`) to wiersz `Stwórz`. Uwagę `plan.mjs sprawdz` „opis wspomina migrację, a pole Pliki nie ma pliku w supabase/migrations/” przy IU z plikiem Flyway pokazujesz w handoffie jako znany fałszywy alarm tego stosu.

### 3.4b Scenariusze E2E

Punkty o Supabase (`supabase db push`, smoke RLS przez `psql "$SUPABASE_E2E_DB_URL"`, limity maili Supabase Auth) nie dotyczą tego stosu. Odmowę dostępu w scenariuszu `[E2E]` sprawdzasz żądaniem do endpointu z tokenem użytkownika bez uprawnienia (oczekiwane 403/404), a środowisko e2e (backend, baza, `E2E_START`) wymaga pozycji w checkliście przygotowania (3.7), dopóki projekt nie ma `.env.e2e` dla tego stosu.
