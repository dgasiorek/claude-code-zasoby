---
name: security
description: "Reguły bezpieczeństwa dla kodu Spring Boot (Java 21, Spring Security, JWT, JPA/Flyway, RestTemplate) + Vue 3 (autoryzacja, walidacja wejścia, sekrety, XSS, SSRF) i protokół audytu bezpieczeństwa w resources. Używaj przy pisaniu kodu z auth/authz, regułami SecurityFilterChain i @PreAuthorize, walidacją inputów, integracjami między serwisami i danymi osobowymi, a także przy review bezpieczeństwa, audycie przed deployem i OWASP Top 10."
---

# Bezpieczeństwo implementacji

Reguły dla kodu, który piszesz w projekcie Spring Boot + Vue 3. Uzupełniają sekcję Bezpieczeństwo w `.claude/rules/coding-rules.md` razem z jej sekcją stosu (sekrety, SQL z parametrami, walidacja wejścia, źródło roli, limity) i jej nie powtarzają. Przy każdej regule stoi powód, żeby przypadek spoza przykładu dało się rozstrzygnąć tym samym rozumowaniem.

## Spring Security i autoryzacja

- Każdy `SecurityFilterChain` kończy się `anyRequest().denyAll()`, a `permitAll()` dostają tylko konkretne, świadomie publiczne ścieżki z listy `PUBLIC_ENDPOINTS`, bo endpoint dodany do kontrolera bez reguły w łańcuchu bez `denyAll()` jest otwarty.
- Tożsamość i role bierzesz wyłącznie ze zweryfikowanego tokenu (`JwtDecoder`: podpis, `exp`, `iss`) — `sub`, `userId`, claim `roles` zmapowany na `GrantedAuthority` — a nie z pola w ciele, parametru ani nagłówka (`X-User-Id`), bo te podrobi każdy klient.
- Endpoint z identyfikatorem zasobu w ścieżce sprawdza w serwisie własność zasobu względem `sub` tokenu przed odczytem i zmianą, bo `@PreAuthorize` na roli nie odróżnia cudzego zasobu od własnego (IDOR).
- Operację wrażliwą chronisz `@PreAuthorize` albo `AuthorizationManager` w łańcuchu, a nie warunkiem `if` w kontrolerze, bo warunek w kontrolerze znika przy pierwszym nowym endpoincie obok.
- Błąd sprawdzenia uprawnień (wyjątek polityki, przekroczony limit czasu, brak danych roli) kończy się odmową albo 5xx, bo gałąź `catch`, która przepuszcza, daje dostęp przy każdej awarii.
- Ukryty przycisk i chroniona trasa w routerze Vue to wygoda interfejsu; tę samą regułę egzekwuje backend, bo klient omija każdy warunek w JS.

## Dane wejściowe i baza

- Kontroler przyjmuje rekord DTO z jawną listą pól i `@Valid`, nigdy encję JPA, bo encja jako `@RequestBody` pozwala ustawić pola spoza formularza (`ownerId`, rola, status) — mass-assignment.
- Każde pole DTO ma ograniczenie: tekst `@Size(max = …)` zgodne z długością kolumny w migracji, format (`@Email`, `@Pattern`, UUID, data) ma walidator, a kolekcja limit rozmiaru, bo walidator przepuszczający dowolny string przenosi błąd do bazy albo odbiorcy.
- Zapytania idą przez derived queries Spring Data albo `@Query` z parametrami nazwanymi, także natywne; dynamiczne sortowanie i filtr po kolumnie z wejścia przechodzą przez listę dozwolonych nazw do `Sort`/`Pageable`, bo nazwy kolumny nie da się sparametryzować, a sklejony `ORDER BY` to SQL injection.
- Danych z zewnątrz nie deserializujesz przez `ObjectInputStream` ani Jacksona z włączonym default typing, bo typ wskazany przez atakującego wykonuje kod przy deserializacji.

## Integracje między serwisami

- `RestTemplate` dostaje bazowy URL z konfiguracji (Consul), a wejście użytkownika tylko jako zakodowane parametry przez `UriComponentsBuilder`; żądanie pod adres z wejścia (podgląd linku, import z URL) idzie tylko do hostów z listy dozwolonych, po sprawdzeniu schematu `https`, bo inaczej serwis czyta Consula, actuatory innych serwisów i adresy wewnętrzne (SSRF).
- Token Bearer propagujesz tylko do serwisów CN (interceptor z listą hostów), nigdy do API zewnętrznych, bo token w obcym logu to przejęte konto.
- Webhook i callback z zewnątrz weryfikuje podpis na surowym ciele przed parsowaniem i jakimkolwiek zapisem, bo bez podpisu każdy wyśle zdarzenie.

## Konfiguracja

- Actuator wystawia na zewnątrz tylko `health` (i `info`, gdy nie ujawnia wersji); `env`, `heapdump`, `configprops` i `metrics` zostają za autoryzacją albo wyłączone, bo `env` i `heapdump` oddają sekrety z pamięci.
- CORS ma jawną listę originów, bez `*` przy żądaniach z poświadczeniami; springdoc i swagger są wyłączone w profilu produkcyjnym.
- Sekrety czytasz z `${VAR:default}` albo Consula; w `application*.yml`, kodzie frontu (zmienne `VITE_*` trafiają do paczki przeglądarki) i logach ich nie ma.

## Dane w odpowiedziach i logach

- Odpowiedź zawiera pola potrzebne odbiorcy — rekord DTO, nie encja — bo encja wysyła klientowi każdą kolumnę, także dodaną później, i ciągnie relacje lazy.
- Klient dostaje kod i komunikat z `@RestControllerAdvice`, a stack trace i błąd bazy (tabela, ograniczenie, treść SQL) idą do logu, bo ujawniają schemat i wersje.
- W logu użytkownika identyfikuje jego identyfikator, nie email ani imię; tokeny, hasła i klucze maskuje logback (reguła DEV-502 w checkstyle), a maskowanie opisuje skill observability-guidelines.

## Interfejs (Vue)

- Treść użytkownika albo CMS renderujesz interpolacją `{{ }}`; `v-html` tylko na HTML po sanitizacji (DOMPurify) z uzasadnieniem w review, bo Vue escapuje interpolację, a nie gotowy HTML.
- URL z danych użytkownika w `:href` i `:src` przechodzi przez `new URL()` z listą dozwolonych protokołów (`https:`, `http:`, `mailto:`), bo `javascript:` w linku wykonuje kod po kliknięciu.
- Obiektów z API i wejścia nie scalasz rekurencyjnie bez filtra kluczy (`__proto__`, `constructor`, `prototype`), tylko jawnym mapowaniem pól, bo deep-merge na niezaufanych danych to prototype pollution.
- Token trzymasz tak, jak robi to `useFetchWrapper` (cookie `secure` + `sameSite: 'strict'`, 401 czyści token), a nie w `localStorage` dostępnym dla każdego skryptu.

## Testy

- Każdy endpoint i polityka z kontrolą dostępu ma test odmowy — bez tokenu (401), rola bez uprawnienia (403), cudzy zasób (403/404) — przez MockMvc z tokenem testowym, bo test tylko na właścicielu przechodzi także przy łańcuchu z `permitAll()`.
- Walidacja DTO ma test złego wejścia (400) dla każdego ograniczenia, które chroni bazę albo odbiorcę.

## Audyt

Audyt bezpieczeństwa (review przed deployem, podejrzenie luki, audyt na prośbę operatora) prowadzisz według `resources/protokol-audytu.md`. Mapowanie OWASP Top 10:2025 na stack jest w `resources/owasp-spring-vue.md`.
