# Konfiguracja i obserwowalność (stack CN)

Konfiguracja serwisów CN: Consul jako źródło wspólnych ustawień, profile Springa,
sekrety poza repo, logback z maskowaniem sekretów, actuator.

---

## 1. Consul — centralna konfiguracja

Każdy serwis importuje konfigurację z Consula przy starcie, **fail-fast** — serwis nie wstanie
bez Consula (to celowe: lepiej nie wystartować, niż działać na złej konfiguracji).
Realny `application.yml` z `tag-service`:

```yaml
spring:
  application:
    name: tag-service
  config:
    import: "consul:${CONSUL_HOST:192.168.69.25}:${CONSUL_PORT:8500}"
  cloud:
    consul:
      config:
        fail-fast: true
        format: YAML
        watch:
          enabled: true
          delay: 1000
        acl-token: "${CONSUL_TOKEN:}"

server:
  port: 30106
```

- **Współdzielona konfiguracja infrastruktury żyje w `consul-config/application.yml`**
  (URL Dalet, typy storage, mapowania pól metadanych, UID akcji, TTL cache, maskowanie logów) —
  wartość wspólną dla wielu serwisów dodawaj TAM, nie kopiuj do yml-i serwisów.
- `watch.enabled: true` — zmiany w Consulu propagują się bez restartu (dla propert
  obsługujących refresh).
- Kolejność źródeł: Consul nadpisuje lokalny `application.yml`; lokalny yml trzyma wartości
  specyficzne dla serwisu i defaulty developerskie.

## 2. Parametryzacja `${VAR:default}` i sekrety

Wszystko, co zależy od środowiska, przez placeholder ze zmiennej środowiskowej z defaultem
sensownym dla dev:

```yaml
app:
  jwt:
    secret_base64: "${JWT_SECRET_BASE64:bXVzdC1iZS0zMi1ieXRlcy1tdXN0LWJlLTMyYnl0ZXM=}"
  category-service:
    base-url: "${CATEGORY_SERVICE_URL:http://localhost:30102}"
```

Reguły twarde:

- **ZERO sekretów w `application*.yml`** i w ogóle w repo. Sekrety wyłącznie przez zmienne
  środowiskowe albo Consul (z ACL). Default w placeholderze może być tylko wartością
  developerską/nieprodukcyjną (jak testowy sekret JWT wyżej).
- Poświadczenia do Nexusa/Dockera w `~/.m2/settings.xml` (registry.adscreen.net) —
  nigdy w `pom.xml` ani w CI-plikach repo.
- Klucze konfiguracji po angielsku (jak identyfikatory); komentarze w yml po polsku.
- Nowy klucz konfiguracyjny bindujemy przez `@ConfigurationProperties` (rekord lub klasa z
  widokiem-interfejsem `...PropertiesView`), nie rozsiane `@Value` po kodzie.

## 3. Profile

| Profil | Zastosowanie |
|--------|--------------|
| (brak / default) | Praca ze środowiskiem dev: Consul, Redis, realne integracje |
| `test` | Testy: Consul wyłączony (`spring.cloud.consul.enabled: false`), cache off (`@Profile("!test")`), zależności na WireMock — patrz `resources/testing.md` |
| `e2e` | Uruchomienie pod testy end-to-end: `mvn spring-boot:run -Dspring-boot.run.profiles=e2e`, baza po migracjach Flyway, seedy idempotentne |
| `demo-offline` | Praca bez Daleta i Consula (patrz niżej) |

### Tryb runtime `app.runtime.mode` (standard | demo-offline)

Poza profilami Springa serwisy dotykające Daleta mają tryb runtime sterowany property:

```java
@Configuration
public class AssetCreatorConfiguration {

    @Bean
    @ConditionalOnProperty(name = "app.runtime.mode", havingValue = "standard", matchIfMissing = true)
    public AssetCreator daletAssetCreator(DaletClient daletClient) {
        return new DaletAssetCreator(daletClient);
    }

    @Bean
    @ConditionalOnProperty(name = "app.runtime.mode", havingValue = "demo-offline")
    public AssetCreator demoOfflineAssetCreator() {
        return new DemoOfflineAssetCreator();
    }
}
```

- `standard` — domyślny (`matchIfMissing = true`), pełna integracja Dalet/MonitorRT.
- `demo-offline` — implementacje lokalne; profil `demo-offline` dodatkowo wyłącza
  `spring.cloud.consul.config` (serwis wstaje bez infrastruktury).
- W Consulu: `app.runtime.mode: "${APP_RUNTIME_MODE:standard}"`.
- **Dodając use-case dotykający Daleta, dorzuć wariant `DemoOffline*` obok `Default*`/`Standard*`.**
- Bindowanie trybu i helpery (`RuntimeModeProperties.isDemoOffline()`) dostarcza biblioteka
  `com.cn.fuse.common:consul` (`RuntimeAutoConfiguration`).

## 4. Logowanie — logback + maskowanie sekretów

Poziomy standardowe dla wszystkich serwisów:

```yaml
logging:
  level:
    root: INFO
    com.cn: DEBUG
  file:
    name: "${smb.mounted.storage}/logs/${spring.application.name}.log"
  logback:
    rollingpolicy:
      file-name-pattern: "${smb.mounted.storage}/logs/${spring.application.name}-%d{yyyy-MM-dd}.%i.log"
      max-history: 10
      max-file-size: 64MB
```

Każdy serwis ma `src/main/resources/logback-spring.xml`, który **includuje współdzielony
fragment maskujący** z biblioteki `com.cn.fuse.common:consul` — to jest obowiązkowy element
każdego nowego serwisu:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <include resource="com/cn/fuse/common/consul/logging/logback-secret-masking.xml"/>
    <include resource="org/springframework/boot/logging/logback/defaults.xml"/>
    <include resource="org/springframework/boot/logging/logback/console-appender.xml"/>
    <include resource="org/springframework/boot/logging/logback/file-appender.xml"/>

    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
        <appender-ref ref="FILE"/>
    </root>
</configuration>
```

Maskowanie konfigurowane w Consulu pod `app.logging.masking.*` (współdzielony
`consul-config/application.yml`):

```yaml
app:
  logging:
    masking:
      enabled: true                   # globalny kill switch
      mask-passwords: true            # password/haslo/hasło + URI credentials + XML <password>
      mask-usernames: false           # login nie jest sekretem — domyślnie wyłączone
      mask-tokens: true               # JWT i Bearer + XML <token>/<jwt>/<accessToken>
      mask-authorization-header: true
      mask-dalet-token: true          # daletToken (claim JWT + XML)
      mask-secrets: true              # secret/credential/apiKey + X-Consul-Token
```

Dyscyplina logowania:

- Nie loguj tokenów, haseł ani pełnych nagłówków `Authorization` — maskowanie to siatka
  bezpieczeństwa, nie przyzwolenie.
- SLF4J z placeholderami (`log.debug("Asset {} rendered", assetId)`), nie konkatenacja.
- Brak Sentry w stacku — obserwowalność to logi + actuator; wyjątki mają docierać do logów
  przez globalny handler, nie być połykane.

## 5. Checkstyle guard DEV-502 — wycieki sekretów w logach

`maven-checkstyle-plugin` (faza `verify`, `failOnViolation: true`, skanuje też testy) z regułą
`RegexpSinglelineJava` wykrywającą słowo wrażliwe obok placeholdera w wywołaniu logera:

```xml
<module name="RegexpSinglelineJava">
    <property name="id" value="LogSecretLeakGuard"/>
    <property name="format"
              value="log\.(trace|debug|info|warn|error)\s*\([^;]*\b(password|pass|haslo|hasło|token|authorization|bearer|jwt|secret)\b[^;]{0,80}\{\}"/>
    <property name="ignoreCase" value="true"/>
    <property name="ignoreComments" value="true"/>
</module>
```

- Build padnie np. na `log.info("User token: {}", token)` — przeformułuj komunikat albo
  zaloguj wartość zamaskowaną/skrót.
- Komentarze i Javadoc są ignorowane automatycznie (`ignoreComments=true`).
- Świadome pominięcie (np. test regresji maskowania, który celowo używa słów wrażliwych):
  `@SuppressWarnings("checkstyle:RegexpSinglelineJava")` **na poziomie klasy** — z uzasadnieniem
  w opisie MR.
- Konfiguracja: `config/checkstyle/dev-502-log-leaks.xml` w root repo. Poza DEV-502 nie ma
  spotless/PMD — formatowanie ogarnia IDE.

## 6. Actuator

Standardowa ekspozycja (realna z `tag-service`) — tylko potrzebne endpointy, nie `*`:

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,loggers
  endpoint:
    health:
      show-details: always
```

- `health` służy za healthcheck w e2e i deploy (`curl localhost:<port>/actuator/health`).
- `loggers` pozwala podbić poziom logowania na żywo bez restartu (diagnostyka).
- `info` zasilane przez `build-info` z `spring-boot-maven-plugin` (goal `build-info`) —
  widać dokładną wersję artefaktu na środowisku.
- Nowych endpointów actuatora nie wystawiaj bez potrzeby; wszystko poza health jest
  za security serwisu.

## 7. Springdoc / Swagger

```yaml
springdoc:
  api-docs:
    enabled: true
    path: /v3/api-docs
  swagger-ui:
    enabled: true
    path: /swagger-ui.html
```

Stałe ścieżki we wszystkich serwisach — nie zmieniaj per serwis.

---

## Checklist konfiguracji nowego serwisu

- [ ] `spring.application.name` + port z puli projektu (3010x)
- [ ] `spring.config.import: "consul:${CONSUL_HOST:...}:${CONSUL_PORT:8500}"` + `fail-fast: true`
- [ ] Wartości środowiskowe przez `${VAR:default}`; zero sekretów w yml
- [ ] `logback-spring.xml` z includem maskowania z `com.cn.fuse.common:consul`
- [ ] `logging.level`: root INFO, `com.cn` DEBUG
- [ ] Actuator: `health,info,loggers`
- [ ] `src/test/resources/application-test.yml` z wyłączonym Consulem i `wiremock.server.port: 0`
- [ ] Wspólne wartości infrastruktury → `consul-config/application.yml`, nie kopiuj lokalnie
- [ ] Jeśli serwis dotyka Daleta: warianty `standard`/`demo-offline` przez `app.runtime.mode`
