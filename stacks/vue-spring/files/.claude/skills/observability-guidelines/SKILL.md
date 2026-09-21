---
name: observability-guidelines
description: Obserwowalność stacku CN — SLF4J + logback z maskowaniem sekretów, Spring Boot Actuator, obsługa wyjątków przez @RestControllerAdvice, MDC/correlation id; frontend Vue: AppMessenger + useFetchWrapper, zero console.log. Aktywuje się przy pracy z błędami, logowaniem, monitoringiem, diagnostyką, logger, exception, wyjątek, crash, awaria, metryki, health check, actuator, MDC.
---

# Observability Guidelines

Przewodnik obserwowalności dla stacku CN: Spring Boot 4 (SLF4J + logback, Actuator) + Vue 3
(AppMessenger, `useFetchWrapper`). Bez zewnętrznego APM/error trackera — obserwowalność opiera się
na zdyscyplinowanych logach, metrykach actuatora i centralnej obsłudze błędów na obu warstwach.

## Filozofia

1. **Log to interfejs dla operatora** — piszesz go dla osoby debugującej incydent o 3 w nocy,
   nie dla siebie. Każdy wpis ma odpowiadać na: co się stało, dla kogo (`userId`), na czym (`assetId`,
   `tagId`), i co dalej.
2. **Błąd obsłużony ≠ błąd niewidoczny** — każdy wyjątek zostawia ślad: wpis w logu z kontekstem
   (backend) albo komunikat w AppMessenger (frontend). Cichy `catch` to bug.
3. **Centralizacja zamiast dyscypliny rozproszonej** — `@RestControllerAdvice` na backendzie
   i `useFetchWrapper` na froncie to JEDYNE miejsca, gdzie błąd jest tłumaczony na odpowiedź/komunikat.
   Kod domenowy rzuca wyjątki domenowe i nie zajmuje się prezentacją błędu.
4. **Sekrety i PII nie istnieją w logach** — dwie warstwy ochrony: guard checkstyle DEV-502
   (build-time) + maskowanie logback z `com.cn.fuse.common:consul` (runtime). Obie muszą być aktywne.
5. **Metryki są darmowe, używaj ich** — Actuator daje health/metrics bez kodu; świadomie
   eksponujemy tylko to, co potrzebne.

## Table of Contents

- [Critical Rules](#critical-rules)
- [Backend: logowanie (SLF4J + logback)](#backend-logowanie-slf4j--logback)
- [Backend: Spring Boot Actuator](#backend-spring-boot-actuator)
- [Backend: wyjątki](#backend-wyjątki)
- [Poziomy logowania](#poziomy-logowania)
- [Frontend: błędy i logowanie](#frontend-błędy-i-logowanie)
- [Scrubbing PII / GDPR](#scrubbing-pii--gdpr)
- [Checklist dla Nowego Kodu](#checklist-dla-nowego-kodu)
- [Common Mistakes](#common-mistakes)
- [Resources](#resources)

---

## Critical Rules

**NIGDY NIE ŁAMIESZ TYCH ZASAD:**

1. **KAŻDY BŁĄD ZOSTAWIA ŚLAD** — log z kontekstem na backendzie, AppMessenger na froncie; zero pustych `catch`
2. **NIGDY `System.out.println` / `printStackTrace`** — wyłącznie SLF4J (`@Slf4j`), inaczej wpis omija poziomy, appendery i maskowanie
3. **NIGDY sekrety/PII w logach** — hasła, tokeny (JWT/Bearer/daletToken), klucze API; guard DEV-502 zatrzyma build, ale nie licz na niego — nie loguj ich wcale
4. **ZERO `console.log` w produkcyjnym kodzie frontu** — komunikaty dla użytkownika przez AppMessenger; diagnostyka tylko za flagą dev
5. **UŻYWAJ WŁAŚCIWYCH POZIOMÓW** — `ERROR` tylko gdy operacja się nie powiodła i ktoś powinien zareagować; nie inflacjonuj poziomów

---

## Backend: logowanie (SLF4J + logback)

### Konfiguracja bazowa

Poziomy: **root INFO**, **`com.cn` DEBUG** (nasze pakiety gadatliwe, biblioteki ciche).
Każdy serwis ma własny `src/main/resources/logback-spring.xml` z `<include>` fragmentu
maskującego sekrety z biblioteki `com.cn.fuse.common:consul`:

```xml
<configuration>
    <include resource="com/cn/fuse/common/consul/logging/logback-secret-masking.xml"/>
    <include resource="org/springframework/boot/logging/logback/defaults.xml"/>
    <include resource="org/springframework/boot/logging/logback/console-appender.xml"/>

    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
    </root>
</configuration>
```

Fragment maskujący MUSI być w każdym serwisie — sama obecność biblioteki na classpath niczego nie
aktywuje (logback bierze pierwszy znaleziony plik konfiguracji). Konfiguracja runtime maskowania:
`app.logging.masking.*` w Consulu (kill switch `enabled` + flagi per wzorzec).

### Wzorzec logowania z kontekstem

```java
@Slf4j
@Service
public class AssetRenderService {

    public RenderResult render(final RenderRequest request, final String userId) {
        log.debug("Start renderowania, assetId={}, profile={}, userId={}",
                request.assetId(), request.profile(), userId);
        try {
            RenderResult result = renderClient.submit(request);
            log.info("Render zlecony, assetId={}, executionId={}", request.assetId(), result.executionId());
            return result;
        } catch (RenderClientException e) {
            log.error("Render nie powiódł się, assetId={}, userId={}", request.assetId(), userId, e);
            throw new RenderFailedException(request.assetId(), e);
        }
    }
}
```

- Parametry przez placeholdery `{}` (leniwe formatowanie), wyjątek jako OSTATNI argument (pełny stack trace)
- Identyfikatory domenowe zawsze (`assetId`, `userId`, `executionId`) — log bez identyfikatorów jest bezużyteczny
- Komunikaty po polsku (konwencja CN), klucze kontekstu po angielsku (`assetId=...`) — grep-owalne

### MDC / correlation id

Żądanie przechodzące przez kilka serwisów (front → asset-service → indexer) musi być korelowane.
Correlation id trafia do MDC na wejściu, do nagłówka przy wywołaniach RestTemplate i jest czyszczony
w `finally`. Wzorce: [resources/backend-logging.md](resources/backend-logging.md).

---

## Backend: Spring Boot Actuator

Actuator to podstawowe źródło sygnałów operacyjnych — health, info, metrics — bez pisania kodu.

**Świadoma ekspozycja (bezpieczeństwo!):**

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics    # jawna lista, NIGDY '*'
  endpoint:
    health:
      show-details: when-authorized     # szczegóły (Redis, DB, Consul) nie dla anonima
```

- `/actuator/health` — liveness/readiness; używany przez deploy i E2E (`curl localhost:<port>/actuator/health`)
- `/actuator/info` — wersja artefaktu/build info; przydatne przy "co jest wdrożone?"
- `/actuator/metrics` — JVM, HTTP (`http.server.requests` z percentylami), pule połączeń, cache
- `/actuator/env`, `/heapdump`, `/configprops` — UJAWNIAJĄ KONFIGURACJĘ I SEKRETY; nigdy publicznie
- W `SecurityFilterChain` ścieżki actuatora dopuszczaj wąsko (`/actuator/health`), nie `/actuator/**`,
  chyba że ekspozycja i tak jest przycięta do bezpiecznej listy

Nowa integracja zewnętrzna = rozważ własny `HealthIndicator` (np. dostępność Daleta), żeby health
mówił prawdę o gotowości serwisu.

---

## Backend: wyjątki

1. **Nigdy pusty catch** — loguj z kontekstem albo re-throw; połknięty wyjątek to najdroższy bug do znalezienia
2. **Łap konkretne typy** — nie ogólny `Exception` bez mapowania na błąd domenowy (konwencja CN)
3. **`@RestControllerAdvice` to centralny punkt** — mapuje wyjątki domenowe na spójny format
   `{ error: { code, message } }`; klient dostaje generyczny komunikat i kod, szczegóły + stack trace idą do logu
4. **Loguj raz** — wyjątek logowany tam, gdzie jest obsługiwany (zwykle w advice); nie na każdym
   szczeblu propagacji (duplikaty zaciemniają obraz)
5. **Fail-closed w ścieżkach bezpieczeństwa** — błąd sprawdzenia dostępu = odmowa + log, nigdy przepuszczenie

```java
@Slf4j
@RestControllerAdvice
public class ApiExceptionHandler {

    @ExceptionHandler(TagNotFoundException.class)
    ResponseEntity<ApiError> handleNotFound(final TagNotFoundException e) {
        return ResponseEntity.status(HttpStatus.NOT_FOUND)
                .body(ApiError.of("TAG_NOT_FOUND", "Tag nie istnieje"));
    }

    @ExceptionHandler(Exception.class)
    ResponseEntity<ApiError> handleUnexpected(final Exception e) {
        log.error("Nieobsłużony wyjątek", e);                     // pełny stack trace do logu
        return ResponseEntity.internalServerError()
                .body(ApiError.of("INTERNAL", "Wystąpił błąd serwera"));   // zero szczegółów dla klienta
    }
}
```

---

## Poziomy logowania

| Poziom | Kiedy używać | Przykład |
|--------|--------------|----------|
| `ERROR` | Operacja nie powiodła się, użytkownik dotknięty, ktoś powinien zareagować | Render nie wystartował, brak połączenia z bazą |
| `WARN`  | Problem odwracalny / degradacja, nie wymaga natychmiastowej akcji | Retry po timeout Daleta, cache miss przy niedostępnym Redis, nieudane logowanie, 403 |
| `INFO`  | Zdarzenia operacyjne — kamienie milowe flow | Serwis wystartował, render zlecony, użytkownik zalogowany |
| `DEBUG` | Diagnostyka developerska — parametry, decyzje w flow | Payload zapytania do indexera, wybór wariantu use-case |
| `TRACE` | Bardzo szczegółowe dane, włączane punktowo | Pełne odpowiedzi integracji (po maskowaniu) |

Zasada: `ERROR` w logach = coś do obejrzenia. Jeśli codzienne działanie generuje ERROR-y "normalne",
poziomy są źle dobrane i prawdziwe awarie giną w szumie.

---

## Frontend: błędy i logowanie

1. **Zero `console.log` w kodzie produkcyjnym** — quality gate (`npm run lint`) i review to egzekwują;
   diagnostyka lokalna tylko za flagą dev (`import.meta.env.DEV`)
2. **Błędy widoczne dla użytkownika przez AppMessenger** —
   `useAppMessengerStore().addMessage({ variant: 'error', text, persistent })`; komunikaty po polsku,
   zrozumiałe dla człowieka (nie surowe `error.message` z fetch)
3. **Błędy API centralnie w `useFetchWrapper`** — komponenty NIE robią własnych try/catch na fetch:
   wrapper obsługuje 401 (czyszczenie tokenu → powrót do logowania), pomija Abort/Timeout,
   resztę raportuje do AppMessenger. Nowe wywołania REST zawsze przez `src/api.ts` + wrapper
4. **Klasyfikuj błąd zanim pokażesz** — walidacja (napraw pole) vs sieć (spróbuj ponownie) vs
   401/403 (sesja/uprawnienia) vs 5xx (błąd serwera) — różne komunikaty i zachowania
5. **`console.error` tylko za flagą dev** — nigdy jako kanał raportowania w produkcji

Szczegóły i wzorce: [resources/frontend-errors.md](resources/frontend-errors.md).

---

## Scrubbing PII / GDPR

- **Tokeny i hasła** — nigdy w logach; maskowanie logback łapie wzorce (JWT, Bearer, Authorization,
  daletToken, password, secret), guard DEV-502 blokuje build przy podejrzanym `log.*(...)`,
  ale pierwszą linią obrony jest NIE logować ich wcale
- **Email/login** — identyfikuj użytkownika po `userId` w logach; login (`username`) domyślnie
  niemaskowany (pomaga w diagnostyce) — dla scenariuszy GDPR włącz `app.logging.masking.mask-usernames=true`
- **Maskowanie emaili w komunikatach**, gdy musi się pojawić: `user@example.com` → `us***@example.com`
- **Frontend** — nie loguj obiektów user/session/response do konsoli nawet w dev; DevTools widzi każdy
- **Odpowiedzi błędów** — nie odbijaj danych wejściowych użytkownika w komunikatach błędów API

---

## Checklist dla Nowego Kodu

Przed każdym MR sprawdź:

- [ ] Każdy blok try/catch loguje z kontekstem albo re-throwuje — zero pustych catch
- [ ] Log zawiera identyfikatory domenowe (`userId`, `assetId`, ...) — bez PII i sekretów
- [ ] Użyto właściwego poziomu (ERROR tylko dla faktycznych niepowodzeń)
- [ ] Brak `System.out.println` / `printStackTrace` / `console.log`
- [ ] Nowe wyjątki domenowe zmapowane w `@RestControllerAdvice` (kod + polski komunikat)
- [ ] Nowe wywołania REST na froncie idą przez `src/api.ts` + `useFetchWrapper`
- [ ] Komunikaty dla użytkownika po polsku, zrozumiałe (AppMessenger)
- [ ] Checkstyle DEV-502 przechodzi bez `@SuppressWarnings` (a jeśli z — jest uzasadnienie)
- [ ] Przetestowano ścieżki błędów (test error case — wymóg coding-rules)

---

## Common Mistakes

**NIE RÓB:**
```java
// Połykanie błędów — nikt się nie dowie
try {
    daletClient.updateMetadata(assetId, fields);
} catch (Exception e) {
    // nic
}

// Sekret w logu — DEV-502 zatrzyma build, a maskowanie to ostatnia deska ratunku
log.debug("Login z tokenem={}", token);

// printStackTrace — omija appendery, poziomy i maskowanie
} catch (DaletException e) {
    e.printStackTrace();
}
```

**RÓB:**
```java
try {
    daletClient.updateMetadata(assetId, fields);
} catch (DaletClientException e) {
    log.error("Aktualizacja metadanych nie powiodła się, assetId={}, userId={}", assetId, userId, e);
    throw new MetadataUpdateException(assetId, e);
}
```

**NIE RÓB (front):**
```typescript
// Cichy błąd + console.log w produkcji
try {
	await api.deleteTag(tagId);
} catch (error) {
	console.log(error);
}
```

**RÓB (front):**
```typescript
// useFetchWrapper sam zaraportuje błąd do AppMessenger — komponent reaguje na stan
const { error, execute } = api.deleteTag(tagId);
// ...a komunikat sukcesu jawnie:
useAppMessengerStore().addMessage({ variant: 'success', text: 'Tag został usunięty' });
```

---

## Resources

Szczegółowe wzorce znajdują się w:

- **[backend-logging.md](resources/backend-logging.md)** — logback-spring.xml, maskowanie (`app.logging.masking.*`), poziomy, anty-wzorce, MDC/correlation id między serwisami
- **[frontend-errors.md](resources/frontend-errors.md)** — useFetchWrapper/AppMessenger, klasyfikacja błędów, komunikaty po polsku, `console.error` za flagą dev
