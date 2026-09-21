## Stos projektu (Vue 3 + Spring Boot) — nadpisania reguł

Ta sekcja jest dopisywana przez `tools/apply-stack.sh --stack vue-spring`. Reguły niżej
mają **pierwszeństwo** nad regułami wyżej wszędzie, gdzie tamte zakładają React/Supabase.

### Nie dotyczy tego stosu

- **§9, autoryzacja po `user_metadata` (Supabase)** — brak Supabase. Rolę czytamy z claimów JWT
  walidowanych przez `JwtConfig` danego serwisu; źródłem prawdy o uprawnieniach jest backend.
- **§13, `useEffect` + `AbortController`** — w Vue odpowiednikiem jest `onScopeDispose` /
  `watchEffect(onCleanup)`; `AbortController` wciąż obowiązkowy przy `fetch` w composable.
- **§10, Zod na granicach** — na froncie walidatory z `src/utils/validators.ts`, na backendzie
  Jakarta Validation na DTO. Nie dodawaj Zoda tylko po to, żeby spełnić literę reguły.

### Backend (Java 21 / Spring Boot / Maven multi-module)

- DTO jako `record`; walidacja wejścia adnotacjami Jakarta na granicy kontrolera.
- Wersje zależności WYŁĄCZNIE w `<dependencyManagement>` parent POM-u; dziecko bez `<version>`.
- Wersja modułu musi różnić się od wersji parenta (pilnuje `maven-enforcer-plugin`).
- Wyjątki domenowe mapowane na statusy HTTP; zakaz `catch (Exception e)` bez uzasadnienia.
- Testy: JUnit 5 + WireMock (stuby w `src/test/resources/__files`), próg JaCoCo 90–95% per moduł
  jest **twardą bramką** — obniżenie progu zamiast dopisania testu to `silent threshold change`.
- Konfiguracja przez `${VAR:default}` w `application.yml`; zero sekretów w plikach konfiguracyjnych.

### Frontend (Vue 3 SFC + Pinia + Vite)

- SFC `<script setup lang="ts">`, composables-first: logika w `src/composables/use*.ts`,
  komponent prezentuje. Argumenty composables jako `MaybeRefOrGetter` + `toValue()`.
- Komponent nigdy nie woła `fetch` bezpośrednio — tylko przez wrappery z `src/api.ts`.
- Stan globalny w Pinia; preferencje przez `usePersistedStorage`.
- Tailwind v4 CSS-first: tokeny w `src/assets/variables.css`, łączenie klas przez `tailwind-merge`.
- Typecheck to `vue-tsc`, nie `tsc` — `tsc --noEmit` nie widzi bloków `<template>`.

### Monorepo i wiele repozytoriów

- W workspace z wieloma repo (`cn-projects`, `gio-projects`) **każde repo ma własny branch i własny
  commit**. Zmiana kontraktu API = commit w każdym repo, które ten kontrakt czyta, w jednym zadaniu.
- Zakaz importów między paczkami pnpm po ścieżce względnej — tylko przez nazwę paczki (`@fuse/*`)
  i wersje z `catalog:`.
- Komendy walidacyjne bierz z `package.json` / `pom.xml` konkretnego modułu, nie z pamięci:
  frontend `pnpm -r type-check` + `vitest run`, backend `mvn -f <moduł>/ clean verify`.
