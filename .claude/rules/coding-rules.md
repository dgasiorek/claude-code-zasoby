---
paths:
  - "**/*.{ts,tsx,js,jsx,mjs,cjs}"
  - "**/*.sql"
  - "**/*.vue"
  - "**/*.java"
  - "**/application*.yml"
  - "**/pom.xml"
---

# Reguły kodu

Reguły pisania, testowania i naprawiania kodu projektu. Do reguły odwołujesz się po nazwie sekcji.

## Pilnuje ESLint i bramki domknięcia

W projekcie z konfiguracją ESLint z szablonu te reguły sprawdza maszyna; bez niej obowiązują tak samo. Błąd lintera naprawiasz w kodzie.

- Próg rozmiaru: 360 linii na plik TS/TSX i 60 na funkcję (bez pustych linii i komentarzy); większe dzielisz na moduły i pod-funkcje.
- Zamiast `any` — `unknown` z type guardem albo własny typ.
- Bez pustego bloku `catch` i bez `console.*` w kodzie produkcyjnym.
- Importy w grupach (wbudowane, zewnętrzne, lokalne), alfabetycznie; bez cykli importów między modułami.
- Każdy promise ma `await`, `return`, `.catch` albo `void`.
- Bez nieużywanych importów, zmiennych, funkcji i eksportów.
- Test ma asercję `expect` poza warunkiem; wywołanie atrapy sprawdzasz z argumentami (`toHaveBeenCalledWith`).

## Rozmiar i struktura

- Funkcja z więcej niż 6 argumentami dostaje obiekt opcji.
- Przy zagnieżdżeniu głębszym niż 2 poziomy wychodzisz wcześniej (early return).
- Jedna odpowiedzialność na moduł, klasę i funkcję; funkcja działa na jednym poziomie abstrakcji; plik komponentu nie zawiera logiki biznesowej.

## Testowanie

- Czerwony test naprawiasz w implementacji. Test zmieniasz tylko wtedy, gdy zmienia się zamówione zachowanie, i nazywasz tę zmianę w raporcie albo commicie.
- Test usuwasz razem z funkcjonalnością, którą sprawdza. Jedyny inny przypadek: zielony test niefalsyfikowalny, którego asercji nie da się przepisać — usuwasz go z wpisem w raporcie fazy. Czerwonego testu nie usuwasz.
- Asercji nie osłabiasz (`toBe(429)` → `toBeDefined()`): słabsza asercja przepuszcza błąd, który test miał łapać.
- Atrapy tylko dla usług zewnętrznych; testowany moduł działa naprawdę, inaczej test sprawdza atrapę. Atrapa usługi z kluczem testowym (Turnstile, reCAPTCHA, Stripe test mode, Resend test) ma też wariant odpowiedzi tego klucza wg dokumentacji dostawcy (brakujące pola, stałe wartości), a kod rozpoznający klucz testowy ma test na tej odpowiedzi — atrapa znająca tylko odpowiedź produkcyjną przepuszcza kod, który na e2e odrzuca każde żądanie.
- Zanim zostawisz test, pytasz, czy przeszedłby, gdyby każda importowana funkcja zwracała `undefined`. Jeśli tak — dajesz jedno konkretne wejście i dosłowny wynik albo obserwowalny skutek.
- Każda nowa funkcja publiczna ma test ścieżki poprawnej i test błędu.
- Unit testy pracują na małych fixture'ach w `tests/fixtures/`, nie na pełnych zbiorach danych.
- Układ testu: Arrange-Act-Assert w blokach describe/it.
- Testujesz zachowanie widoczne z zewnątrz (wynik, DOM, zapis w bazie), nie stan wewnętrzny; komponent — przez Testing Library, tak jak używa go użytkownik.
- Testy piszesz wertykalnie: jeden test → jego implementacja → następny test. Wszystkie testy naraz, a potem cała implementacja, dają testy kształtu (struktur i sygnatur), które przechodzą, gdy zachowanie się psuje.
- Refaktoryzujesz przy zielonych testach; czerwony najpierw doprowadzasz do zielonego.

## Organizacja kodu

- Testy leżą obok plików źródłowych.
- Wspólny moduł wydzielasz przy trzecim użyciu tej samej logiki; przy dwóch prosta duplikacja jest lepsza niż abstrakcja. Wyjątek: stała albo kontrakt (schemat, typ, próg) w dwóch miejscach — od razu jedno źródło, bo kopie rozjeżdżają się po cichu.
- Nową logikę wydzielasz do nowego modułu zamiast rozbudowywać istniejący, gdy rozbudowa utrudnia jego zrozumienie.
- Konfiguracja tylko dla wartości, które się zmieniają.
- Przed napisaniem funkcji szukasz istniejącej (grep).
- Liczby o znaczeniu domenowym trzymasz w nazwanych stałych.

## Obsługa błędów

- Każdy `catch` (także `.catch(() => …)`) zostawia ślad dla operatora — log z kodem błędu i przyczyną — albo rzuca błąd dalej.
- Rzucasz typowany błąd (klasa z kodem), nie string.
- Łapiesz konkretne typy błędów, nie ogólny `Error`.
- Wejście walidujesz na początku funkcji (fail fast).
- Trasy API odpowiadają kopertą `{ data, error: { code, message } }`. W Hono `app.onError` mapuje `HTTPException` (status, message) na kopertę zamiast zwracać `err.getResponse()`; trasy z własnym protokołem (MCP, JSON-RPC) mają własny format.
- Logujesz strukturalnie (JSON z kodem błędu, np. pino).

## Zakres zmian i bramki

- Obsługujesz scenariusze, które mogą wystąpić w tym kodzie; dla niemożliwych nie dodajesz gałęzi, konfiguracji ani abstrakcji.
- Zmianę szerszą niż zadanie (refaktor wielu plików) najpierw uzgadniasz z operatorem; w workflowie zgłaszasz ją jako następny krok.
- Reguł z tego pliku i konfiguracji bramek (ESLint, tsconfig, progi, hooki) nie luzujesz, żeby zmiana przeszła, i nie wyłączasz ich w linii (`eslint-disable`, `@ts-expect-error`) — błąd naprawiasz w kodzie; regułę zmienia operator. Wiedzę projektu zapisuje compound według swojego skilla.
- Zablokowane narzędzie albo hook to sygnał do zatrzymania i zgłoszenia, nie do obejścia innym narzędziem (sed, python -c).
- Przy niejasnej instrukcji pytasz; w workflowie zwracasz status `blocked` z pytaniem.
- Defekt w kodzie sprzed zmiany nie jest powodem do pominięcia — naprawiasz go albo zgłaszasz z miejscem (plik:linia).
- Zanim zgłosisz koniec: typecheck, testy i lint dla zmienionych plików; pełny zestaw robi domknięcie fazy.
- Commit robisz, gdy prosi o to operator albo polecenie workflowu; commit nie zawiera plików `.env` ani nowych TODO/FIXME.

## Nazewnictwo

- Boolean: prefiks `is` / `has` / `should` / `can` (`isActive`, `hasPermission`, `shouldRetry`).
- Obsługa zdarzeń: prefiks `handle` (`handleClick`, `handleSubmit`).
- Stałe: `UPPER_SNAKE_CASE`.
- Typy i interfejsy: `PascalCase`, bez prefiksu `I`.
- Funkcje i zmienne: `camelCase`.
- Pliki: kebab-case (`user-service.ts`, nie `UserService.ts`), chyba że framework wymusza inną konwencję.
- Nazwa mówi, co robi, nie jak (`getUserById`, nie `fetchAndParseAndValidateUser`); rozumiesz ją w 5 sekund.
- Bez akronimów i skrótów poza powszechnie znanymi (`url`, `id` tak; `usrMgr` nie).

## Zależności

- Przed użyciem biblioteki sprawdzasz manifest (package.json, requirements.txt, go.mod).
- Nową zależność zgłaszasz operatorowi (w workflowie: w odchyleniach); pierwszeństwo mają biblioteki, które projekt już ma.
- Jeden menedżer pakietów — ten z lockfile projektu.
- W monorepo pakiety importują się przez warstwę wspólną, nie bezpośrednio.
- Wersje w package.json przypinasz dokładnie.

## Bezpieczeństwo

- Sekrety tylko w zmiennych środowiska poza repo.
- Klucz testowy dostawcy (odpowiedź bez `action`, host testowy) kod przyjmuje tylko w konfiguracji lokalnej albo e2e (warunek z trybu aplikacji albo `SITE_URL`), z testem odmowy w konfiguracji produkcyjnej — bez warunku klucz testowy w produkcji omija weryfikację.
- Sekretów i danych osobowych nie logujesz — także do Sentry: redakcja przed wysłaniem.
- SQL tylko z parametrami, bez sklejania z danymi użytkownika.
- Bez dynamicznego wykonania kodu z danych użytkownika.
- Dane z zewnątrz (ciało, query, parametry ścieżki, nagłówki, cookies, pliki, odpowiedzi usług zewnętrznych) parsujesz schematem Zod przed użyciem; kopertę — `z.strictObject`. W Hono walidator (`validator` albo `zValidator`, jeśli projekt go ma) dostaje hook zwracający kopertę błędu; bez pasującego Content-Type ciało przychodzi jako `{}`, więc test na brak nagłówka.
- Rola pochodzi z tabeli ról (w polityce przez funkcję albo claim z Custom Access Token Hook) albo z `app_metadata` ustawianego po stronie serwera; nie z `user_metadata` — użytkownik zmienia je przez `updateUser` — ani z top-level claimu `role`.
- Polityki RLS: `(select auth.uid())` i `(select auth.jwt())` zamiast wywołania wprost (wynik liczony raz na zapytanie), indeks na kolumnie filtra polityki, każda polityka z `TO <rola>`.
- Funkcja `security definer`: `set search_path = ''`, EXECUTE odebrane od `public` i `anon` i nadane roli, która ją woła, kontrola uprawnień w ciele funkcji.
- Skrypty migracyjne, ETL, importy i seedy walidują dane źródłowe jak wejście z granicy API — tożsamość (`from_user`/`owner_id` nie przepisujesz z danych źródłowych), limity długości, kształt payloadu, przynależność do zasobu. „Jednorazowy” albo „usuwany później” nie znosi walidacji ani nie obniża wagi findingu.
- Uprawnienia minimalne — tyle, ile potrzeba.
- `rm -rf` tylko za wyraźną zgodą operatora.
- Produkcyjnej bazy nie zmieniasz bezpośrednio.
- Każdy publiczny endpoint ma limit częstości, limit rozmiaru ciała i limit rozmiaru strony; operacje wrażliwe (logowanie, reset hasła, wysyłka) — osobny, niższy limit.

## Type safety

- Zamiast `as` — `satisfies` albo type guard; `as` tylko przy zawężaniu DOM i `as const`.
- Zamiast `!` — zawężenie albo early return.
- Stan opisujesz unią dyskryminowaną, nie zestawem flag boolean.
- Funkcje publiczne mają jawny typ zwracany; komponent React i hook, który zwraca wynik hooka biblioteki (`useQuery`, `useForm`), mają typ wywnioskowany z JSX albo z tego wywołania, bo ręczny zapis tylko go powtarza.
- tsconfig: `strict` i `verbatimModuleSyntax`; w nowym projekcie także `erasableSyntaxOnly` (bez `enum`, `namespace` z kodem i parameter properties).

## Performance

- Złożoność O(n²) i gorsza ma komentarz, dlaczego nie da się lepiej.
- Zapytanie do bazy w pętli to N+1 — zamiast tego batch, join albo include.
- Pobierasz tylko potrzebny podzbiór: paginacja, limit, wybrane kolumny.
- Nową zależność w kodzie klienta sprawdzasz pod kątem rozmiaru przed dodaniem; budżet paczki pilnuje size-limit w domknięciu.
- Komponent większy niż 50 KB ładujesz dynamicznie (`React.lazy`, dynamic import).
- Optymalizujesz po pomiarze, nie na zapas.

## Async i React

- Efekt z async w cleanupie unieważnia wynik: flaga `ignore` albo abort i sprawdzenie, czy odpowiedź dotyczy bieżących parametrów. Gdy projekt ma bibliotekę cache (TanStack Query) albo loader routera, nowy kod pobierający dane idzie przez nią.
- Każde wywołanie sieciowe ma limit czasu (`AbortSignal.timeout`). W efekcie, który przerywa żądanie w cleanupie, limit łączysz z flagą `ignore` zamiast łączyć dwa sygnały; w supabase-js limit daje opakowany `fetch` w `createClient({ global: { fetch } })`.
- `setTimeout` i `setInterval` w efekcie mają cleanup (`clearTimeout`, `clearInterval`).
- Stan ładowania z więcej niż jedną flagą opisujesz unią dyskryminowaną; formularz — `useActionState` / `useOptimistic` zamiast ręcznych flag.
- Równoległe operacje, które mogą zawieść niezależnie — `Promise.allSettled`.
- Sprzątanie i przejścia stanu w `Promise.finally()`, bez powielania logiki w gałęziach sukcesu i błędu.
- Pętla `requestAnimationFrame` sprawdza flagę anulowania przed kolejną klatką.
- Operację wykluczającą się z poprzednią (np. ładowanie podglądu) uruchamiasz dopiero po zakończeniu albo porażce poprzedniej.
- Przy włączonym React Compilerze (`babel-plugin-react-compiler` w projekcie) nie dodajesz ręcznie `useMemo` ani `useCallback` — kompilator memoizuje; wyjątek: stabilna zależność efektu.

## Architektura

- Warstwy: strona → komponent → hook → serwis → klient bazy; komponent nie woła bazy bezpośrednio.
- Kontrakty API (interfejsy, typy propsów) są stabilne — zmiana interfejsu to świadoma decyzja, nie skutek uboczny refaktoru.
- Nową zależność między modułami sprawdzasz pod kątem nieodwracalnego couplingu.

<!-- stack:vue-spring:start -->

## Stos projektu (Vue 3 + Spring Boot)

Sekcję dopisuje `tools/apply-stack.sh --stack vue-spring`. Reguły tej sekcji mają pierwszeństwo przed regułami wyżej wszędzie, gdzie tamte zakładają React, Supabase albo Hono; reguły wyżej bez takiego założenia obowiązują bez zmian — w plikach `.vue` tak jak w `.ts`, a w Javie te, które nie dotyczą składni TypeScriptu.

### Zamiast sekcji Pilnuje ESLint i bramki domknięcia

- Pliki `.vue` sprawdza ESLint projektu tak jak `.ts`; progi rozmiaru liczysz dla bloku `<script setup>`.
- W Javie te same reguły (rozmiar, puste `catch`, nieużywany kod) pilnuje checkstyle w `mvn verify`, z regułą DEV-502 na wycieki sekretów w logach. Błąd checkstyle naprawiasz w kodzie, a konfiguracji checkstyle nie ruszasz.

### Zamiast sekcji Async i React

- Efekt w Vue (`watch`, `watchEffect`) z async unieważnia wynik w `onCleanup`: abort albo sprawdzenie, czy odpowiedź dotyczy bieżących parametrów; sprzątanie composable (timery, nasłuchy, `AbortController`) robisz w `onScopeDispose`.
- Każde wywołanie sieciowe ma limit czasu (`AbortSignal.timeout` we froncie, timeouty połączenia i odczytu w `RestTemplate` na backendzie).
- Stan ładowania z więcej niż jedną flagą opisujesz unią dyskryminowaną; `Promise.allSettled`, `Promise.finally()`, flaga anulowania w pętli `requestAnimationFrame` i blokada operacji wykluczających się obowiązują jak wyżej.
- Wartości pochodne liczysz przez `computed`, a nie metody wołane w szablonie; argumenty composables przyjmujesz jako `MaybeRefOrGetter` i czytasz `toValue()`.

### Zamiast sekcji Architektura

- Front: widok → komponent → composable (`src/composables/use*.ts`) → wrapper w `src/api.ts` na `useFetchWrapper` → backend. Komponent nie woła `fetch`, stan globalny trzyma store Pinia (`src/store.ts`), preferencje `usePersistedStorage`.
- Backend: kontroler → serwis → repozytorium albo klient, podział pakietów `api/service/domain/infra`; kontroler nie woła repozytorium, a encje JPA nie wychodzą przez API — kontroler mówi rekordami DTO.
- Kontrakt API to rekord DTO; typy TS w `src/api.ts` go odwzorowują pole po polu (camelCase), nigdy odwrotnie. Zmiana kontraktu jest świadomą decyzją, nie skutkiem ubocznym refaktoru.

### Testowanie

- Front: Vitest + @vue/test-utils; komponent testujesz przez wyrenderowany DOM i interakcję użytkownika, nie przez stan instancji (`wrapper.vm`).
- Backend: JUnit 5 + AssertJ + Mockito, integracyjne na Testcontainers, integracje między serwisami na stubach WireMock (`src/test/resources/__files`) — nigdy prawdziwe HTTP. Pytanie „undefined” w Javie brzmi: czy test przeszedłby, gdyby każda wywołana metoda zwracała `null` albo pusty wynik.
- Próg JaCoCo modułu (90–95%) jest twardą bramką: brak pokrycia uzupełniasz testem, progu nie obniżasz.

### Obsługa błędów

- Backend: wyjątek domenowy mapuje na status HTTP istniejący `@RestControllerAdvice`, w formacie odpowiedzi błędu, którego używa serwis; bez `ResponseEntity` składanego w kontrolerze i bez `catch (Exception e)`. Logujesz przez SLF4J (logback z maskowaniem sekretów) z kodem błędu i przyczyną.
- Front: błąd żądania obsługuje `useFetchWrapper` i komunikat AppMessenger; bez `console.*` w kodzie produkcyjnym.

### Bezpieczeństwo

- Dane z zewnątrz walidujesz na granicy: na backendzie `@Valid` i adnotacje Jakarta na rekordzie DTO, we froncie walidatory z `src/utils/validators.ts`. Zoda nie dodajesz tylko po to, żeby spełnić literę reguły wyżej.
- Rolę czytasz z claimów JWT walidowanych przez `JwtConfig` serwisu; autoryzacja to `@PreAuthorize` i reguły filter chain, deny-by-default. Reguły wyżej o `user_metadata`, RLS i funkcjach `security definer` nie dotyczą tego stosu.
- Zapytania JPA i `@Query` (także natywne) tylko z parametrami, bez sklejania z danymi użytkownika.
- Sekrety czytasz z `${VAR:default}` albo Consula; w `application*.yml`, kodzie frontu i logach nie ma haseł, tokenów ani kluczy. Dane uwierzytelniające Nexusa leżą w `~/.m2/settings.xml`, nie w repo.

### Type safety

- W `.vue` i `.ts` obowiązuje sekcja Type safety wyżej; composable publiczny ma jawny typ zwracany, a propsy deklarujesz `defineProps<...>()`.
- Typecheck frontu to `vue-tsc`, nie `tsc` — `tsc` nie widzi bloków `<template>`.
- W Javie: bez raw types i niesprawdzanych rzutowań, `Optional` zamiast `null` w zwracanych wartościach, DTO jako `record`.

### Performance

- N+1 w JPA rozwiązujesz `JOIN FETCH` albo `@EntityGraph`, a kolekcje stronicujesz (`Pageable`).
- Ciężki widok ładujesz dynamicznie (`defineAsyncComponent` albo `() => import()` w routerze) zamiast `React.lazy`.

### Zależności i build

- Wersje zależności Mavena tylko w `<dependencyManagement>` rodzica; moduł deklaruje zależność bez `<version>`. Wersja modułu różni się od wersji rodzica (pilnuje `maven-enforcer-plugin`), a `<version>` modułów bumpuje pipeline.
- Front używa pnpm; paczki workspace importujesz przez nazwę (`@fuse/*`) z wersjami z `catalog:`, nie po ścieżce względnej.
- Komendy walidacyjne bierzesz z `package.json` i `pom.xml` konkretnego modułu: front `pnpm -r type-check` + `vitest run`, backend `mvn -f <moduł>/ clean verify`.

### Wiele repozytoriów

- W workspace z wieloma repo (`cn-projects`, `gio-projects`) każde repo ma własny branch i własny commit. Zmiana kontraktu API to commit w każdym repo, które ten kontrakt czyta, w jednym zadaniu.
<!-- stack:vue-spring:end -->
