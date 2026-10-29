---
paths:
  - "**/*.vue"
  - "**/*.java"
  - "**/application*.yml"
  - "**/pom.xml"
---

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
