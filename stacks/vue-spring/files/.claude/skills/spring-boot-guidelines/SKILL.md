---
name: spring-boot-guidelines
description: Wytyczne backendowe CN - Java 21, Spring Boot 4, Maven multi-module, JPA/Flyway/Postgres, Redis, Consul, JWT, WireMock, Testcontainers. Uzywaj przy pracy z kontrolerami, serwisami, encjami, migracjami, konfiguracja yml, pom.xml i testami backendu.
paths:
  - "**/*.java"
  - "**/pom.xml"
  - "**/application*.yml"
  - "**/db/migration/**"
---

# Spring Boot Guidelines (stack CN)

## Cel

Przewodnik pracy z backendem CN: mikroserwisy Spring Boot 4 na Javie 21, zorganizowane w monorepo Maven
(kanoniczny przykład: `cn-mediaconnector` — auth/category/config/asset/action/tag-service).
Wytyczne odzwierciedlają realne wzorce z kodu CN, nie generyczne tutoriale.

## Kiedy używać tego skilla

- Tworzenie lub modyfikacja kontrolerów REST, serwisów, repozytoriów, DTO
- Migracje Flyway i praca z encjami JPA / PostgreSQL
- Konfiguracja `application*.yml`, Consul, profile, cache Redis
- Zmiany w `pom.xml` (zależności, pluginy, wersje)
- Pisanie testów: jednostkowych, warstwy web, WireMock, Testcontainers

---

## Przegląd stacka

| Warstwa | Technologia |
|---------|-------------|
| Język | Java 21 (rekordy, text blocks, pattern matching), kompilacja z `-parameters` |
| Framework | Spring Boot 4.0.x + Spring Cloud 2025.1.x |
| Web | spring-boot-starter-web/webmvc, `RestTemplate` między serwisami, springdoc-openapi (`/swagger-ui.html`, `/v3/api-docs`) |
| Security | JWT przez `spring-security-oauth2-jose` (Nimbus), deny-by-default, per-serwis `JwtConfig` |
| Dane | PostgreSQL + JPA + Flyway; Redis (cache); Elasticsearch (wyszukiwanie, przez indexer); commons-vfs2 (storage) |
| Konfiguracja | Consul (`spring-cloud-starter-consul-config`, fail-fast), `${VAR:default}`, tryb `app.runtime.mode` |
| Build | Maven multi-module, wersje w `dependencyManagement` rodzica, Nexus `registry.adscreen.net:8443` |
| Testy | JUnit 5 + AssertJ + Mockito + WireMock (`spring-cloud-contract-wiremock`) + Testcontainers 2.x + `ApplicationContextRunner` |
| Jakość | JaCoCo 95% LINE na `verify`; checkstyle DEV-502 (guard wycieku sekretów w logach); Lombok |
| Logi | SLF4J + logback, root INFO / `com.cn` DEBUG, współdzielone maskowanie sekretów z `com.cn.fuse.common:consul` |

## Mapa zasobów skilla

| Plik | Kiedy sięgnąć |
|------|---------------|
| `resources/testing.md` | Piramida testów CN: unit, `@WebMvcTest`, WireMock, Testcontainers, `ApplicationContextRunner`, JaCoCo — **czytaj przed każdym testem** |
| `resources/persistence.md` | JPA, migracje Flyway, encje vs DTO, N+1, Redis cache, Elasticsearch |
| `resources/rest-api.md` | Endpointy, DTO, walidacja, obsługa błędów, wersjonowanie, OpenAPI, paginacja, `RestTemplate` |
| `resources/configuration.md` | Consul, profile, sekrety, logback + maskowanie, actuator, checkstyle DEV-502 |
| `resources/maven-build.md` | Multi-module, `dependencyManagement`, flatten/`${revision}`, security-overrides, spring-boot-maven-plugin, Nexus |

---

## Najważniejsze zasady (TL;DR)

### 1. Zależności: wersje należą do rodzica

Nowe zależności dodawaj w POM modułu **bez `<version>`** — wersja żyje w `dependencyManagement`
root POM (albo w BOM-ach `spring-boot-dependencies` / `spring-cloud-dependencies`).

```xml
<!-- POM modułu: BEZ wersji -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-jpa</artifactId>
</dependency>
```

Wyjątek: BOM specyficzny dla modułu (np. `testcontainers-bom` w `tag-service`) importujesz
w `dependencyManagement` tego modułu.

### 2. Każdy moduł ma WŁASNY literalny `<version>`

Wersjonowanie jest automatyczne i osobne per serwis — pipeline robi `versions:set` na module,
więc wersja modułu **nie może być dziedziczona** z rodzica:

```xml
<parent>
    <groupId>com.cn</groupId>
    <artifactId>mediaconnector</artifactId>
    <version>${revision}${changelist}</version>
    <relativePath>../pom.xml</relativePath>
</parent>

<artifactId>tag-service</artifactId>
<version>1.2.6</version>
```

**Nie edytuj `<version>` ręcznie** — bumpuje go pipeline na podstawie hasła commita
(`feature:` → minor, `fix:` → patch, `!`/`BREAKING CHANGE` → major).

### 3. DTO: niemutowalne kontrakty + Jakarta Validation

Dla nowych DTO preferuj rekordy Java 21; istniejące moduły używają też Lomboka
(`@Value @Builder @Jacksonized`) — **bądź spójny z modułem, w którym pracujesz**.
Zawsze waliduj wejście adnotacjami Jakarta Validation i włączaj walidację przez `@Valid`:

```java
public record CreateTagRequest(
        @NotBlank @Size(max = 128) String name,
        @NotBlank @Size(max = 4096) String filters) {
}
```

JSON zawsze camelCase. Encja JPA **nigdy** nie wychodzi z API — mapper przepisuje ją na DTO odpowiedzi.

### 4. Wyjątki domenowe → status HTTP

Wyjątki domenowe dziedziczą po `com.cn.fuse.common.consul.exception.AppException`
i niosą swój status HTTP; współdzielony `GlobalExceptionHandler` (`@RestControllerAdvice`)
mapuje je na `ErrorDto {statusCode, statusName, title, detail, instance}`:

```java
public class TagConflictException extends AppException {

    private static final String TITLE = "Tag conflict";

    private TagConflictException(String detail) {
        super(detail, TITLE, CONFLICT);
    }

    public static TagConflictException forNamespaceCollision(String name) {
        return new TagConflictException(
                "Nazwa '" + name + "' jest zajęta w drugiej przestrzeni nazw (użytkownik / system).");
    }
}
```

Serwis rzuca wyjątek domenowy, kontroler NIE łapie i NIE mapuje statusów ręcznie.
Nie łap ogólnego `Exception` bez konkretnego powodu.

### 5. Zero sekretów w yml i logach

- `application*.yml` parametryzuj przez `${VAR:default}`; sekrety tylko ze zmiennych środowiskowych
  lub Consula. Poświadczenia do Nexusa w `~/.m2/settings.xml`, nigdy w repo.
- Checkstyle DEV-502 zatrzymuje build, gdy `log.info(...)` zawiera słowa wrażliwe
  (`password`, `token`, `bearer`, `secret`, ...) obok placeholdera `{}`.
- Każdy serwis includuje fragment maskujący z `com.cn.fuse.common:consul` w `logback-spring.xml`.

### 6. Profil `test` odcina infrastrukturę

`src/test/resources/application-test.yml` wyłącza Consula i wskazuje lokalne zależności;
konfiguracje cache mają `@Profile("!test")`. Testy NIGDY nie wołają realnego HTTP —
zewnętrzne serwisy (Dalet, indexer, auth) stubuje WireMock. Szczegóły: `resources/testing.md`.

```yaml
spring:
  config:
    import: ""
  cloud:
    consul:
      enabled: false
      config:
        enabled: false
        import-check:
          enabled: false
wiremock:
  server:
    port: 0
```

### 7. Warstwy i odpowiedzialności

- **Kontroler** — tylko HTTP: walidacja wejścia, wyciągnięcie użytkownika z JWT, delegacja
  do serwisu, kontrakt API + adnotacje OpenAPI. Bez logiki domenowej.
- **Serwis** — reguły domenowe, transakcje (`@Transactional` na operacjach zapisu),
  rzucanie wyjątków domenowych. Nie zna HTTP i nie mapuje statusów.
- **Repozytorium** — Spring Data JPA za interfejsem-portem domenowym (np. `TagRepository`
  w `domain/`, implementacja JPA w `domain/sql/`).
- Wstrzykiwanie przez konstruktor: `@RequiredArgsConstructor` + pola `private final`.

### 8. Tryb runtime `app.runtime.mode`

Serwisy dotykające Daleta wybierają implementację use-case'u przez
`@ConditionalOnProperty(name = "app.runtime.mode")`: `standard` (domyślny, `matchIfMissing = true`)
i `demo-offline` (lokalnie, bez Daleta i Consula). Dodając use-case integrujący się z Daletem,
dorzuć wariant `DemoOffline*` obok `Default*`/`Standard*`.

### 9. Komendy Maven

```bash
mvn clean verify                       # pełny build monorepo (z roota) — testy + JaCoCo + checkstyle
mvn test                               # testy modułu (z katalogu modułu)
mvn test -Dtest=DefaultTagServiceTest  # jedna klasa testowa
mvn test -Dtest=DefaultTagServiceTest#shouldReturnVisibleTagsForUser   # jedna metoda
mvn test -DskipITs                     # bez testów integracyjnych (szybciej)
mvn spring-boot:run                    # uruchomienie serwisu (z katalogu modułu)
```

Brak `mvnw` w root — używaj systemowego `mvn` (wrappery tylko w wybranych modułach).

### 10. Konwencje zespołowe

- **Polski dla ludzi**: Javadoc, komentarze (tylko istniejące — nowych nie dodawaj), opisy testów,
  commity (`<hasło>: DEV-XXX <opis po polsku>`), dokumentacja, opisy w adnotacjach OpenAPI.
- **Angielski dla maszyn**: identyfikatory (klasy, metody, pola), nazwy plików, klucze konfiguracji.
- Minimalny diff; nie commituj/pushuj bez wyraźnego polecenia.
- Endpointy pod `/api/v1/...`; porty serwisów z zakresu 30101–30106 (cn-mediaconnector).

---

## Checklisty szybkiego startu

### Checklist nowego endpointu

- [ ] DTO żądania z Jakarta Validation (`@NotBlank`, `@Size`, ...) + `@Valid` w kontrolerze
- [ ] DTO odpowiedzi (nigdy encja JPA) + mapper
- [ ] Wyjątki domenowe dziedziczące po `AppException` z docelowym statusem HTTP
- [ ] Adnotacje OpenAPI: `@Operation`, `@ApiResponse` z `ErrorDto` dla błędów (opisy po polsku)
- [ ] Test `@WebMvcTest` warstwy HTTP + testy jednostkowe serwisu (Mockito)
- [ ] Zewnętrzne wywołania w testach stubowane WireMockiem

### Checklist nowej tabeli

- [ ] Migracja `V<nr>__opis.sql` w `src/main/resources/db/migration/` (nigdy nie edytuj zaaplikowanej)
- [ ] Encja JPA z `ddl-auto: validate` (schemat tworzy wyłącznie Flyway)
- [ ] Seedy idempotentne (`ON CONFLICT ... DO NOTHING`)
- [ ] Test integracyjny na Testcontainers Postgres z migracjami Flyway

### Checklist nowej zależności

- [ ] Wersja jest w `dependencyManagement` rodzica lub w BOM — moduł deklaruje bez `<version>`
- [ ] Nie duplikujesz konfiguracji pluginu, którą dostarcza rodzic
- [ ] Nie ruszasz bloków `SECURITY-OVERRIDES-BEGIN/END` bez procedury z `resources/maven-build.md`
