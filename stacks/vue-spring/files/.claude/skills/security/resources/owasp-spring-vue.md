# OWASP Top 10 (2025) — Mapowanie na Spring Boot + Vue

Przewodnik mapujący każdą kategorię **OWASP Top 10:2025** (finalna wersja: styczeń 2026) na konkretne
scenariusze, checklisty i wzorce kodu dla stacku CN: Spring Boot 4 (Java 21, JWT stateless,
JPA/PostgreSQL, Redis, Consul, RestTemplate między serwisami) + Vue 3 (TypeScript, Vite, `useFetchWrapper`).

**Co zmieniło się względem 2021 (istotne dla nas):**
- **SSRF** nie jest już osobną kategorią — wchłonięty do **A01 Broken Access Control** (u nas: `RestTemplate` na URL od użytkownika).
- **Security Misconfiguration** awansuje z #5 na **A02** (u nas: actuator, CORS, springdoc na produkcji).
- **A03 Software Supply Chain Failures** — NOWA, szersza kategoria (Maven + npm, rejestry, pipeline).
- **A10 Mishandling of Exceptional Conditions** — NOWA (fail-open, wyciek stack trace, puste catch).
- Injection spada z #3 na **A05**, Insecure Design na **A06**.

---

## A01:2025 — Broken Access Control

Najczęstszy problem bezpieczeństwa (#1 od lat). W naszym stacku manifestuje się przez dziury w
`SecurityFilterChain`, brak weryfikacji własności zasobu (IDOR), role spoza zweryfikowanego tokenu
oraz — od 2025 — **SSRF** (traktowany jako obejście kontroli dostępu do zasobów wewnętrznych).

**Scenariusze w naszym stacku:**
- Endpoint dodany do kontrolera, ale nieobjęty regułą w `authorizeHttpRequests` — jeśli łańcuch nie kończy się `denyAll()`, wisi otwarty
- `permitAll()` na zbyt szerokim wzorcu (`/api/**` zamiast konkretnej ścieżki logowania)
- IDOR: `GET /api/v1/tags/{id}` zwraca/modyfikuje cudzy zasób, bo serwis nie porównuje właściciela z `sub` tokenu
- Role brane z pola requestu / nagłówka custom zamiast z claimu `roles` zweryfikowanego JWT
- Operacja administracyjna bez `@PreAuthorize("hasRole('ADMIN')")` / dedykowanego `AuthorizationManager`
- **SSRF**: serwis wykonuje `restTemplate.getForObject(urlOdUzytkownika, ...)` → dostęp do Consula (`localhost:8500`), actuatora innych serwisów, metadata endpointów

**Checklist:**
- [ ] Każdy `SecurityFilterChain` kończy się `anyRequest().denyAll()` (deny-by-default)
- [ ] Lista `PUBLIC_ENDPOINTS` zawiera tylko świadomie publiczne ścieżki (health, swagger w dev)
- [ ] Każdy endpoint z `{id}` weryfikuje własność zasobu względem `sub`/`userId` z JWT (polityka domenowa, wzorzec `TagSecurityPolicy`)
- [ ] Role wyłącznie z claimu `roles` zweryfikowanego tokenu, zmapowane na `GrantedAuthority`
- [ ] Operacje wrażliwe za `@PreAuthorize` lub `AuthorizationManager` (nie "if w kontrolerze")
- [ ] `RestTemplate` NIGDY nie dostaje URL zbudowanego z inputu użytkownika — bazowe URL-e z konfiguracji (Consul), input tylko jako parametry/segmenty po walidacji
- [ ] Macierz dostępu (kto może co) jest udokumentowana i zweryfikowana

**Dobry wzorzec — deny-by-default:**
```java
http.authorizeHttpRequests(registry -> registry
        .requestMatchers(PUBLIC_ENDPOINTS).permitAll()
        .requestMatchers(HttpMethod.POST, "/api/v1/tags/system/**").access(adminAuthorizationManager)
        .requestMatchers("/api/v1/tags/**").authenticated()
        .anyRequest().denyAll());
```

**IDOR — weryfikacja własności w serwisie (fail-closed):**
```java
public void deleteTag(final long tagId, final Jwt jwt) {
    Tag tag = tagRepository.findById(tagId)
            .orElseThrow(() -> new TagNotFoundException(tagId));
    if (!tagSecurityPolicy.canModify(tag, jwt.getSubject())) {
        throw new AccessDeniedException("Brak uprawnień do tagu");
    }
    tagRepository.delete(tag);
}
```

**SSRF przez RestTemplate — walidacja przed wywołaniem:**
```java
private static final Set<String> ALLOWED_HOSTS = Set.of("dalet.internal.example", "indexer.internal.example");

public String fetchExternal(final String rawUrl) {
    URI uri = URI.create(rawUrl);
    if (!"https".equals(uri.getScheme()) || !ALLOWED_HOSTS.contains(uri.getHost())) {
        throw new IllegalArgumentException("Host niedozwolony");
    }
    return restTemplate.getForObject(uri, String.class);
}
```
> Preferuj brak URL-i z inputu w ogóle: baza z konfiguracji + `UriComponentsBuilder` z inputem
> wyłącznie jako zakodowane parametry. Filtr po hoście nie chroni w 100% przed DNS rebinding —
> przy wysokim ryzyku rozwiąż DNS i zwaliduj IP.

---

## A02:2025 — Security Misconfiguration

Awans z #5 (2021). Domyślne lub błędne ustawienia — w naszym stacku najczęściej **actuator**, CORS/CSRF
i springdoc.

**Scenariusze w naszym stacku:**
- `management.endpoints.web.exposure.include: '*'` — `/actuator/env` i `/actuator/heapdump` ujawniają sekrety i pamięć procesu
- CORS `allowedOrigins("*")` w połączeniu z `Authorization: Bearer` — dowolna strona wywołuje API tokenem ofiary
- CSRF wyłączony "bo tak było w przykładzie" bez potwierdzenia, że API jest w pełni stateless (JWT w nagłówku, `SessionCreationPolicy.STATELESS`, brak cookie-based auth)
- Swagger UI (`/swagger-ui.html`, `/v3/api-docs`) publiczny na produkcji — mapa ataku za darmo
- Verbose błędy Spring (`server.error.include-stacktrace: always`) na produkcji
- Konfiguracja Consul KV rozjeżdżająca się między środowiskami

**Checklist:**
- [ ] Actuator: `management.endpoints.web.exposure.include: health,info,metrics` — jawna lista, nigdy `'*'`; `env`/`heapdump`/`configprops` wyłączone lub za autoryzacją
- [ ] `management.endpoint.health.show-details: when-authorized` (szczegóły health ujawniają topologię)
- [ ] CORS ograniczony do znanych originów frontendu (nie `*` przy uwierzytelnianych żądaniach)
- [ ] CSRF disabled TYLKO dla stateless JWT API (token w nagłówku `Authorization`, sesja STATELESS); jeśli cokolwiek używa cookie do auth — CSRF wraca
- [ ] Springdoc na produkcji wyłączony (`springdoc.api-docs.enabled: false`) lub za autoryzacją
- [ ] `server.error.include-stacktrace: never`, `include-message: never` na produkcji
- [ ] Nagłówki bezpieczeństwa dla frontu: `X-Content-Type-Options: nosniff`, `frame-ancestors 'none'`, HSTS na domenie
- [ ] Konfiguracja per środowisko przez `${VAR:default}` / Consul — bez wartości produkcyjnych zaszytych w yml

**Stateless JWT API — poprawna konfiguracja bazowa:**
```java
http.csrf(AbstractHttpConfigurer::disable);          // OK tylko dla stateless Bearer API
http.sessionManagement(c -> c.sessionCreationPolicy(SessionCreationPolicy.STATELESS));
http.formLogin(AbstractHttpConfigurer::disable);
http.httpBasic(AbstractHttpConfigurer::disable);
```

**CSP dla bundla Vite (nagłówki serwera front):**
```
Content-Security-Policy:
  default-src 'self';
  connect-src 'self' https://api.example.com;
  img-src 'self' data:;
  script-src 'self';
  style-src 'self' 'unsafe-inline';
  frame-ancestors 'none';
  base-uri 'self'
```
> `connect-src` MUSI zawierać origin backendu, inaczej `useFetchWrapper` nie wykona żadnego żądania.

---

## A03:2025 — Software Supply Chain Failures (NOWA)

Rozszerzenie dawnego „Vulnerable and Outdated Components" o **cały łańcuch dostaw**: zależności Maven
i npm, rejestry, pipeline CI.

**Scenariusze w naszym stacku:**
- CVE w zależnościach transitywnych Spring/Jackson/Logback — root POM ma bloki `SECURITY-OVERRIDES-BEGIN/END` właśnie po to
- Wersje deklarowane w child POM zamiast w `dependencyManagement` rodzica → rozjazd wersji między serwisami
- `package-lock.json` niecommitowany → niereprodukowalny build frontu, ryzyko podmiany wersji
- Typosquatting / złośliwe paczki npm (postinstall scripts)
- Creds do Nexusa (`registry.adscreen.net`) w repo zamiast w `~/.m2/settings.xml`
- Artefakty spoza zaufanych rejestrów (Nexus CN + Maven Central)

**Checklist:**
- [ ] Wersje zależności TYLKO w `dependencyManagement` root POM; child moduły bez `<version>`
- [ ] Bloki `SECURITY-OVERRIDES` w root POM aktualne; przed zmianą uruchom skrypt weryfikacyjny
- [ ] `npm audit` bez krytycznych luk (w CI); `package-lock.json` commitowany
- [ ] Renovate/Dependabot lub cykliczny przegląd `mvn versions:display-dependency-updates` / `npm outdated`
- [ ] Poświadczenia rejestrów wyłącznie w `~/.m2/settings.xml` / zmiennych CI — nigdy w repo
- [ ] Weryfikacja źródła paczek przed dodaniem (pobrania, maintainer, data ostatniej publikacji)
- [ ] Pipeline GitLab CI używa centralnych szablonów — bez ad-hoc kroków pobierających kod z nieznanych źródeł

```bash
npm audit                                   # front
mvn org.owasp:dependency-check-maven:check  # backend (jeśli włączony w projekcie)
```

---

## A04:2025 — Cryptographic Failures

Wycieki danych wrażliwych przez brak/błędne szyfrowanie lub zarządzanie sekretami.

**Scenariusze w naszym stacku:**
- Sekret JWT / hasła DB wpisane w `application*.yml` w repo (zamiast `${VAR}`/Consul)
- Sekret JWT za krótki dla HS256 (< 256 bitów) lub współdzielony z innym systemem
- Tokeny w URL query params (logi serwera, referer, historia przeglądarki)
- PII (email, login) w logach bez maskowania — patrz guard DEV-502 i maskowanie logback
- Ruch między serwisami po HTTP bez TLS poza zaufaną siecią

**Checklist:**
- [ ] ZERO sekretów w `application*.yml` — tylko `${VAR:default}` lub Consul KV
- [ ] Sekret JWT ≥ 256 bitów (HS256), rotowalny bez zmiany kodu (konfiguracja)
- [ ] Hasła użytkowników (auth-service) hashowane adaptywnie (BCrypt/Argon2), nigdy plaintext/MD5/SHA-1
- [ ] JWT wyłącznie w nagłówku `Authorization: Bearer` — nigdy w query string
- [ ] Maskowanie logback aktywne (include `logback-secret-masking.xml`); checkstyle DEV-502 przechodzi
- [ ] TLS na ruchu zewnętrznym; cookie tokenu na froncie: `secure: true`, `sameSite: 'strict'`

```yaml
# DOBRZE: wartość z env/Consula, default tylko dla dev
app:
  security:
    jwt:
      secret: ${JWT_SECRET_BASE64:}
```

---

## A05:2025 — Injection

SQL/JPQL injection i XSS — dwa główne wektory.

**Scenariusze w naszym stacku:**
- Konkatenacja user input w JPQL: `em.createQuery("SELECT t FROM Tag t WHERE t.name = '" + name + "'")`
- `createNativeQuery` ze sklejanym stringiem; dynamiczny `ORDER BY` z inputu bez whitelisty
- Query Elasticsearch sklejane jako JSON string z frazą użytkownika
- **Mass-assignment**: encja JPA jako `@RequestBody` — atakujący ustawia pola, których nie ma w formularzu (`ownerId`, `role`, `systemTag`)
- **Deserializacja niezaufanych danych**: `ObjectInputStream` na danych z zewnątrz; Jackson z włączonym default typing (`activateDefaultTyping`) na niezaufanym JSON
- Vue: `v-html` z treścią użytkownika; `:href` z `javascript:`

**Checklist:**
- [ ] Wszystkie zapytania przez Spring Data derived queries / `@Query` z `:param` — zero konkatenacji
- [ ] Zapytania natywne parametryzowane; dynamiczne sortowanie przez whitelist → `Sort`/`Pageable`
- [ ] Kontrolery przyjmują DTO (rekordy) z jawną listą pól — nigdy encje JPA
- [ ] Brak deserializacji Javy (`ObjectInputStream`) na danych z zewnątrz; brak Jackson default typing
- [ ] Zero `v-html` na danych spoza kodu — a jeśli konieczne, DOMPurify + uzasadnienie w review
- [ ] Walidacja protokołu URL w dynamicznych `:href`/`:src` (whitelist `https:`)

```java
// BEZPIECZNE: parametr nazwany
@Query("SELECT t FROM Tag t WHERE t.owner = :owner AND t.name LIKE %:phrase%")
List<Tag> search(@Param("owner") String owner, @Param("phrase") String phrase);

// BEZPIECZNE: whitelist sortowania
private static final Set<String> SORTABLE = Set.of("name", "createdAt");
Sort sort = SORTABLE.contains(sortBy) ? Sort.by(sortBy) : Sort.by("createdAt");
```

```vue
<!-- NIEBEZPIECZNE -->
<div v-html="asset.description"></div>

<!-- BEZPIECZNE: interpolacja escapowana przez Vue -->
<div>{{ asset.description }}</div>
```

```typescript
// BEZPIECZNE: walidacja protokołu przed użyciem w :href
const isSafeUrl = (url: string) => /^https?:\/\//i.test(url);
```

**Prototype pollution (front):** nie merguj obiektów z API/inputu przez rekurencyjne kopiowanie
kluczy bez filtra (`__proto__`, `constructor`, `prototype`); używaj płytkich, jawnych mapowań pól
zamiast generycznych deep-merge na niezaufanych danych. `npm audit` wyłapuje podatne biblioteki merge.

---

## A06:2025 — Insecure Design

Brak mechanizmów bezpieczeństwa na poziomie architektury (rate limiting, limity, timeouts).

**Scenariusze w naszym stacku:**
- Brak rate limitingu na `/api/v1/auth/login` — brute force haseł
- Brak limitów rozmiaru requestu / uploadu (`MultipartFile`) — DoS
- `RestTemplate` bez timeoutów — jeden wolny serwis blokuje pulę wątków całego serwisu
- Brak limitów długości pól (`@Size`) — payload 10 MB w polu "name"
- Enumeracja użytkowników przez różne komunikaty błędów logowania

**Checklist:**
- [ ] Rate limiting na KAŻDYM publicznym endpoincie (login, reset) — filtr z licznikiem w Redis (mamy go w stacku) lub limiter na gateway'u
- [ ] `spring.servlet.multipart.max-file-size` / `max-request-size` ustawione świadomie
- [ ] `RestTemplate` budowany z `connectTimeout`/`readTimeout` (RestTemplateBuilder)
- [ ] `@Size(max=...)` na każdym polu tekstowym DTO
- [ ] Generyczne komunikaty błędów logowania (jeden komunikat dla złego loginu i złego hasła)

```java
// Rate limiting loginu — licznik w Redis, fail-closed
String key = "login-attempts:v1:" + clientIp;
Long attempts = redisTemplate.opsForValue().increment(key);
if (attempts != null && attempts == 1L) {
    redisTemplate.expire(key, Duration.ofMinutes(15));
}
if (attempts == null || attempts > MAX_ATTEMPTS) {
    throw new TooManyRequestsException();   // 429, bez szczegółów
}
```

---

## A07:2025 — Authentication Failures

Słabe mechanizmy autentykacji i zarządzania tożsamością.

**Scenariusze w naszym stacku:**
- Serwis ufa claimom tokenu bez weryfikacji podpisu (parsowanie JWT "gołym" dekoderem base64 zamiast `JwtDecoder`)
- Brak walidacji `exp` → wieczne tokeny; brak walidacji `iss` → tokeny z obcego wystawcy przechodzą
- Identyfikacja użytkownika z nagłówka `X-User-Id` zamiast z `sub` zweryfikowanego tokenu
- Token propagowany do serwisów zewnętrznych (poza CN) w nagłówku — wyciek poświadczeń
- Front: token w `localStorage` dostępny dla każdego skryptu; brak reakcji na 401

**Checklist:**
- [ ] Każdy serwis weryfikuje JWT przez `JwtDecoder` (Nimbus, `spring-security-oauth2-jose`): podpis + `exp` + `iss`
- [ ] Tożsamość i role WYŁĄCZNIE ze zweryfikowanych claimów (`sub`, `userId`, `roles`)
- [ ] Bearer propagowany TYLKO do serwisów CN (RestTemplate interceptor z listą hostów), nigdy do API zewnętrznych
- [ ] Front: cookie `secure` + `sameSite: 'strict'`, wygasanie zgodne z `exp` tokenu; 401 → wyczyszczenie tokenu i powrót do logowania (robi to `useFetchWrapper`)
- [ ] Czas życia tokenu ograniczony; operacje krytyczne mogą wymagać re-autentykacji

Szczegółowe wzorce: [auth-security-patterns.md](auth-security-patterns.md).

---

## A08:2025 — Software or Data Integrity Failures

Brak weryfikacji integralności danych z zewnętrznych źródeł.

**Scenariusze w naszym stacku:**
- Odpowiedzi Daleta/indexera mapowane bez walidacji — zepsuty/złośliwy payload przechodzi w głąb systemu
- Dopasowanie użytkownika po loginie/mailu (mutowalne) zamiast po `userId`
- Deserializacja formatów binarnych z zewnątrz bez ograniczeń
- Import/seed/migracja przepisujące `ownerId` z danych źródłowych bez weryfikacji

**Checklist:**
- [ ] Dane z integracji zewnętrznych (Dalet, indexer) walidowane jak input z granicy (DTO + Jakarta Validation / jawne sprawdzenia)
- [ ] Powiązanie użytkownika po niemutowalnym `userId` z JWT, nie po loginie/mailu
- [ ] Webhooki/callbacky (jeśli dojdą) weryfikowane sygnaturą przed przetworzeniem
- [ ] Skrypty importu/seedy traktują dane źródłowe jak niezaufane — walidacja tożsamości i kształtu
- [ ] Brak dynamicznego wykonywania kodu z danych zewnętrznych

---

## A09:2025 — Security Logging and Alerting Failures

Brak logowania zdarzeń bezpieczeństwa i brak alertów na incydenty.

**Scenariusze w naszym stacku:**
- Nieudane logowania / odmowy 403 nielogowane — brute force niewidoczny
- Sekrety/PII w logach (guard DEV-502 wyłączony przez `@SuppressWarnings` bez uzasadnienia)
- `System.out.println` / `printStackTrace` zamiast SLF4J — poza kontrolą poziomów i maskowania
- Brak korelacji logów między serwisami (MDC / correlation id)
- Brak alertów na skoki 5xx (metryki actuatora nieobserwowane)

**Checklist:**
- [ ] Zdarzenia bezpieczeństwa logowane na WARN: nieudane logowanie, 401/403, przekroczenie rate limitu (bez PII, z `userId`/IP)
- [ ] Wyłącznie SLF4J (`@Slf4j`) — zero `System.out` / `printStackTrace`
- [ ] Checkstyle DEV-502 aktywny (fail-on-violation na `verify`); maskowanie logback włączone
- [ ] Correlation id propagowany między serwisami (MDC) — analiza incydentu przekrojowo
- [ ] `/actuator/metrics` + `health` obserwowane przez monitoring; alert na skok błędów

Szczegóły wzorców logowania: skill `observability-guidelines`.

---

## A10:2025 — Mishandling of Exceptional Conditions (NOWA)

Błędna obsługa błędów prowadząca do luk — **fail-open**, wyciek szczegółów błędu do klienta, ciche
połknięcie wyjątków, złe kody statusu.

**Scenariusze w naszym stacku:**
- **Fail-open w autoryzacji**: `try { checkAccess() } catch (Exception e) { /* leci dalej */ }`
- Pusty `catch {}` — błąd weryfikacji tokenu zignorowany, żądanie przetworzone
- Stack trace / błąd Postgresa w odpowiedzi API (ujawnia schemat, wersje)
- Zwrócenie `200` mimo błędu → front i użytkownik myślą, że operacja się udała
- Łapanie ogólnego `Exception` bez mapowania na błąd domenowy (zakazane w konwencjach CN)

**Checklist:**
- [ ] Autoryzacja **fail-closed** — wyjątek przy sprawdzaniu dostępu = 403/500, nigdy przepuszczenie
- [ ] Zero pustych `catch` — loguj z kontekstem albo re-throw (patrz `coding-rules` §4)
- [ ] `@RestControllerAdvice` mapuje wyjątki na spójny format `{ error: { code, message } }` — generyczny komunikat dla klienta, szczegóły do logu
- [ ] Poprawne kody statusu: 400 walidacja, 401 brak/zły token, 403 brak uprawnień, 404 brak zasobu, 5xx błąd serwera
- [ ] Łap KONKRETNE wyjątki i mapuj na błędy domenowe — nie ogólny `Exception`

```java
// ŹLE: fail-open — wyjątek przepuszcza użytkownika
try {
    if (accessPolicy.canRead(userId, assetId)) {
        return asset;
    }
} catch (Exception e) {
    return asset;                       // KATASTROFA: błąd = dostęp
}

// DOBRZE: fail-closed + generyczny błąd dla klienta, szczegóły do logu
try {
    if (!accessPolicy.canRead(userId, assetId)) {
        throw new AccessDeniedException("Brak dostępu do zasobu");
    }
    return asset;
} catch (AccessPolicyEvaluationException e) {
    log.error("Błąd ewaluacji polityki dostępu, assetId={}", assetId, e);
    throw new ServiceUnavailableException();   // 5xx, bez szczegółów dla klienta
}
```

---

## Podsumowanie — najwyższe ryzyko w stacku Spring Boot + Vue

| Priorytet | Kategoria 2025 | Główne ryzyko w naszym stacku |
|-----------|----------------|-------------------------------|
| 1 | A01 Broken Access Control | Brak `denyAll()`, IDOR bez weryfikacji własności, SSRF przez RestTemplate |
| 2 | A02 Security Misconfiguration | Ekspozycja actuatora (`env`/`heapdump`), CORS `*`, swagger na produkcji |
| 3 | A05 Injection | Konkatenacja w JPQL/native query, mass-assignment encji, `v-html` |
| 4 | A07 Authentication Failures | Claims bez weryfikacji podpisu/`iss`/`exp`, tożsamość spoza tokenu |
| 5 | A04 Cryptographic Failures | Sekrety w `application*.yml`/logach (DEV-502), token w URL |
| 6 | A10 Mishandling of Exceptional Conditions | Fail-open w autoryzacji, wyciek błędów do klienta |

**Zobacz także:**
- [auth-security-patterns.md](auth-security-patterns.md) — wzorce JWT, method security, token po stronie Vue
