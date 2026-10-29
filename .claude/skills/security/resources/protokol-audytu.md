# Protokół audytu bezpieczeństwa

Protokół systematycznego audytu bezpieczeństwa projektu Spring Boot + Vue 3 (review przed deployem, podejrzenie luki, audyt na prośbę operatora). Reguły dla kodu pisanego w trakcie implementacji są w `SKILL.md` tego skilla.

## Kiedy Uzywac

Audyt to osobna praca, nie krok implementacji — piszacy kod stosuje reguly z `SKILL.md`, a review fazy ma wlasnego reviewera bezpieczenstwa.

- Review bezpieczenstwa przed deployem na produkcje
- Pre-deploy audit po wiekszych zmianach (nowe endpointy, zmiany auth/authz, nowe tabele, dane osobowe, nowe integracje)
- Podejrzenie o luke bezpieczenstwa w istniejacym kodzie
- Audyt na prosbe operatora

---

## Sześć obszarów audytu

### Input Validation

Znajdz wszystkie punkty wejscia danych od uzytkownika i zweryfikuj walidacje.

1. **Zmapuj punkty wejscia:**
   - Kontrolery: `@RequestBody`, `@RequestParam`, `@PathVariable`, `@RequestHeader`
   - Konsumenci kolejek, webhooki, callbacki z zewnatrz
   - Formularze Vue (`BaseForm` + `src/utils/validators.ts`), parametry trasy (`useRoute().params`, `query`)
   - File uploads (`MultipartFile`)
2. **Sprawdz walidacje Jakarta** na kazdym punkcie wejscia:
   - Czy parametr kontrolera ma `@Valid` i jest rekordem DTO (nie encja)?
   - Czy walidacja jest na granicy systemu (nie glebiej)?
   - Czy ograniczenia sa restrykcyjne (`@Email`, `@Pattern`, nie goly `String`)?
   - Czy sa limity dlugosci (`@Size(max = 500)`) zgodne z kolumna w migracji?
3. **Szukaj brakujacej walidacji** -- kazdy `@RequestBody` bez `@Valid` to finding.

### SQL/Query Safety

Spring Data i `@Query` z parametrami sa bezpieczne, ale sa pulapki.

1. **Sprawdz `@Query` i `createNativeQuery`** -- czy nie konkatenuja stringow z inputem
2. **Sprawdz `EntityManager.createQuery`** -- JPQL sklejany z inputem to injection jak w SQL
3. **Sprawdz dynamiczne sortowanie i filtry** -- nazwa kolumny z inputu tylko przez whitelist -> `Sort`/`Pageable`
4. **Sprawdz zapytania do innych silnikow** (Elasticsearch, Redis) -- czy fraza uzytkownika nie jest sklejana w JSON/komende
5. **Sprawdz migracje Flyway** -- czy uprawnienia rol bazy sa minimalne, czy nie ma danych testowych z haslami
6. **Sprawdz mass-assignment** -- czy zadna encja JPA nie jest `@RequestBody` ani nie wychodzi w odpowiedzi

### XSS Detection

Vue domyslnie escapuje interpolacje, ale istnieja wyjatki.

1. **Szukaj `v-html`** -- kazde uzycie na danych spoza kodu to potencjalny XSS (czy jest DOMPurify?)
2. **Sprawdz user-generated URLs:**
   - `:href="userInput"` -- czy jest walidacja protokolu? (`javascript:` protocol attack)
   - `:src="userInput"` -- czy jest whitelist domen?
3. **Content Security Policy** -- czy istnieje i czy jest restrykcyjna?
4. **Third-party content** -- czy jest sandboxowany (iframe sandbox)?
5. **Szukaj renderowania raw HTML** z zewnetrznych zrodel (markdown, CMS) i deep-merge niezaufanych obiektow (prototype pollution)

### Auth/Authz Audit

Zmapuj endpointy vs wymagania autoryzacji.

1. **Stworz macierz dostepu:**

| Endpoint / Akcja | Anon | Authenticated | Owner | Admin |
|-------------------|------|---------------|-------|-------|
| GET /api/v1/posts        | tak  | tak           | tak   | tak   |
| POST /api/v1/posts       | nie  | tak           | -     | tak   |
| DELETE /api/v1/posts/{id} | nie  | nie           | tak   | tak   |

2. **Zweryfikuj `SecurityFilterChain`** -- czy konczy sie `anyRequest().denyAll()`, czy `PUBLIC_ENDPOINTS` nie ma zbyt szerokich wzorcow (`/api/**`)
3. **Zweryfikuj `@PreAuthorize` / `AuthorizationManager`** -- czy odzwierciedlaja macierz dostepu
4. **Sprawdz weryfikacje JWT** -- `JwtDecoder` sprawdza podpis, `exp` i `iss`; zaden serwis nie parsuje tokena dekoderem base64
5. **Sprawdz zrodlo tozsamosci i rol** -- tylko zweryfikowane claimy (`sub`, `userId`, `roles`), nie naglowek ani pole requestu; brak hardcoded email/ID
6. **Sprawdz IDOR** -- kazdy endpoint z `{id}` porownuje wlasciciela zasobu z `sub` tokenu w serwisie
7. **Fail-closed** -- blad sprawdzenia dostepu = odmowa, nigdy przyznanie (A10:2025)

### Sensitive Data Exposure

Szukaj wyciekow danych wrazliwych.

1. **Hardcoded secrets:**
   - Szukaj: API keys, tokeny, hasla w kodzie zrodlowym i `application*.yml` (dozwolone tylko `${VAR:default}` / Consul)
   - Sprawdz `.env.example` i `application-test.yml` -- czy nie zawieraja prawdziwych wartosci
   - Sprawdz git history -- `git log --diff-filter=A -- "*.env*" "*application*.yml"`
   - Sprawdz zmienne `VITE_*` -- trafiaja do paczki przegladarki
2. **Dane w logach:**
   - `log.info/debug` z obiektami user/token/request; maskowanie w logback (DEV-502 w checkstyle)
   - `console.*` we froncie z obiektami user/session/error
3. **Actuator i narzedzia:**
   - Czy `env`, `heapdump`, `configprops` sa niedostepne z zewnatrz?
   - Czy springdoc/swagger jest wylaczony na produkcji?
4. **Propagacja tokenu:**
   - Czy Bearer idzie tylko do serwisow CN (interceptor z lista hostow)?
5. **Odpowiedzi API:**
   - Czy endpointy zwracaja rekordy DTO z potrzebnymi polami, nie encje?
   - Czy bledy nie ujawniaja stack trace ani bledu Postgresa?

### OWASP Top 10 Compliance

Przejdz kazda kategorie **OWASP Top 10:2025** pod katem naszego stacku. Zwroc uwage na zmiany 2025: SSRF wchloniety do A01 (u nas: `RestTemplate` na URL od uzytkownika), nowe A03 (Software Supply Chain -- Maven + npm, rejestry, pipeline) i A10 (Mishandling of Exceptional Conditions -- fail-open, wyciek bledow).

Pelne mapowanie kategorii na stack Spring Boot + Vue:
**[Przewodnik: owasp-spring-vue.md](owasp-spring-vue.md)**

---

## Klasyfikacja Findings

Wagi odpowiadaja wagom pipeline'u: Krytyczna i Wysoka = P1, Srednia = P2, Niska = P3.

```
Krytyczna -- Exploit mozliwy w produkcji, wymaga natychmiastowej naprawy
   Przyklady: SecurityFilterChain bez denyAll() z otwartym endpointem danych,
   SQL/JPQL injection, sekret w application.yml, brak auth na endpoincie z danymi

Wysoka -- Powazna luka, exploit mozliwy przy okreslonych warunkach
   Przyklady: IDOR bez weryfikacji wlasciciela, @RequestBody bez @Valid,
   v-html z user content, SSRF przez RestTemplate, actuator env/heapdump na zewnatrz

Średnia -- Potencjalne ryzyko, wymaga analizy kontekstu
   Przyklady: brak rate limiting, zbyt szerokie CORS, encja w odpowiedzi
   zamiast DTO, brak CSP headers, swagger na produkcji

Niska -- Hardening, defense-in-depth
   Przyklady: brak Strict-Transport-Security header, outdated dependencies
   bez znanych CVE, brak audit logging dla niekrytycznych operacji
```

---

## Format Raportu

```markdown
## Security Audit Report: [nazwa projektu / zakres]

### Executive Summary
[1-3 zdania: ogolna ocena bezpieczenstwa, liczba findings, najwazniejsze ryzyka]

### Findings

#### Krytyczna
1. **[plik:linia]** -- [tytul]
   - Impact: [co moze sie stac]
   - Remediation: [jak naprawic, z przykladem kodu]

#### Wysoka
[jak wyzej]

#### Średnia
[jak wyzej]

#### Niska
[jak wyzej]

### Risk Matrix

| Kategoria          | Status | Findings |
|--------------------|--------|----------|
| Input Validation   | [OK/WARN/FAIL] | X |
| SQL/Query Safety   | [OK/WARN/FAIL] | X |
| XSS                | [OK/WARN/FAIL] | X |
| Auth/Authz         | [OK/WARN/FAIL] | X |
| Data Exposure      | [OK/WARN/FAIL] | X |
| OWASP Compliance   | [OK/WARN/FAIL] | X |

### Remediation Roadmap
1. [Krytyczna] [opis] -- termin: natychmiast
2. [Wysoka] [opis] -- termin: przed deployem
3. [Średnia] [opis] -- termin: nastepny sprint
4. [Niska] [opis] -- termin: backlog
```

---

## Zasady

1. **Mysl jak atakujacy** -- zakladaj najgorszy scenariusz, nie optymistyczny
2. **Worst-case scenario** -- kazdy finding opisuj przez pryzmat "co najgorszego moze sie stac"
3. **Zawsze podawaj rozwiazanie** -- finding bez remediation jest bezuzyteczny
4. **Nie dismissuj jako pre-existing** -- istniejace luki sa nadal lukami
5. **Weryfikuj, nie zakladaj** -- "Spring Security domyslnie to robi" nie wystarczy, sprawdz konfiguracje lancucha
6. **Najmniejsze uprawnienia** -- kazdy komponent powinien miec minimum potrzebnych uprawnien
7. **Defense in depth** -- jedna warstwa ochrony to za malo, waliduj na kazdej granicy
8. **Dokumentuj zakres** -- jasno okresl co zostalo sprawdzone, a co nie

---

## Dokumentacja Referencyjna

- **OWASP Top 10 dla naszego stacku** -- `owasp-spring-vue.md`
