# Testowanie backendu (stack CN)

Piramida testów CN — od najszybszych i najliczniejszych do najcięższych:

1. **Testy jednostkowe** — JUnit 5 + AssertJ + Mockito (serwisy, mappery, polityki, walidacja DTO)
2. **Testy warstwy web** — `@WebMvcTest` + MockMvc (kontrolery, kontrakt HTTP, mapowanie błędów)
3. **Testy integracyjne z WireMock** — `@SpringBootTest` + stuby zewnętrznych serwisów (Dalet, indexer, auth)
4. **Testy integracyjne bazy** — Testcontainers 2.x Postgres + realne migracje Flyway
5. **Testy auto-konfiguracji** — `ApplicationContextRunner` (biblioteki typu `com.cn.fuse.common:consul`)

Zasada nadrzędna: **NIGDY realny HTTP w testach**. Każde wywołanie zewnętrzne
(Dalet WebService, storage-indexer, monitoring, auth-service) przechodzi przez stub WireMock.
Test, który wymaga sieci lub działającego środowiska, jest błędem projektowym.

---

## Konwencje wspólne dla wszystkich testów

### Nazewnictwo i opisy — po polsku dla ludzi

Identyfikatory (nazwy metod) zostają po angielsku — jak wszystkie identyfikatory w kodzie CN —
ale **opis testu jest po polsku**: przez `@DisplayName` (obowiązkowe dla nowych testów)
i/lub polski Javadoc klasy testowej (wzorzec z istniejącego kodu):

```java
/**
 * Testy jednostkowe orkiestratora {@link DefaultTagService}.
 */
@ExtendWith(MockitoExtension.class)
class DefaultTagServiceTest {

    @Test
    @DisplayName("Zwraca tagi systemowe i tagi użytkownika widoczne dla zalogowanego użytkownika")
    void shouldReturnVisibleTagsForUser() {
        // ...
    }
}
```

Schemat nazw metod: `should<Oczekiwanie>` lub `metoda_scenariusz_shouldOczekiwanie`
(np. `upsertUserTag_insert_shouldCreateTagAndReturnCreatedTrue`) — realny wzorzec z `tag-service`.

### Struktura AAA i asercje

- Każdy test w układzie **Arrange–Act–Assert** (sekcje rozdzielone pustą linią, bez komentarzy `// given`).
- **Minimum jedna asercja na test** — test bez asercji (albo tylko z `verify` bez sprawdzenia efektu)
  nie przechodzi review. `verify(...)` uzupełnia asercje, nie zastępuje ich.
- Asercje wyłącznie **AssertJ** (`assertThat`, `assertThatThrownBy`) — nie mieszaj z asercjami JUnit.
- Jeden test = jeden scenariusz. Wiele niezależnych scenariuszy → osobne testy albo `@ParameterizedTest`.

### Mockowanie — granice

- **Nie mockuj testowanego kodu** — mock zastępuje wyłącznie zależności klasy pod testem.
  Spy na klasie testowanej to niemal zawsze zapach; przemyśl podział odpowiedzialności.
- Nie mockuj typów, których nie kontrolujesz, gdy istnieje lekka prawdziwa implementacja
  (np. mapper bez zależności — użyj prawdziwego).
- Nie stubuj więcej, niż test potrzebuje — Mockito w trybie strict zgłosi zbędne stuby jako błąd.

### Klasy testowe

- Klasy i metody testowe pakietowe (bez `public`) — konwencja JUnit 5.
- Test leży w tym samym pakiecie co klasa testowana (`src/test/java/...`).
- Dane testowe budują prywatne metody pomocnicze / buildery, nie pola współdzielone między testami.

---

## 1. Testy jednostkowe — JUnit 5 + AssertJ + Mockito

Domyślny poziom dla logiki domenowej. Bez Springa, bez kontekstu — czysty Mockito:

```java
@ExtendWith(MockitoExtension.class)
class DefaultTagServiceTest {

    @Mock
    private TagRepository tagRepository;

    @Mock
    private TagMapper tagMapper;

    @Mock
    private TagSecurityPolicy tagSecurityPolicy;

    @InjectMocks
    private DefaultTagService service;

    @Test
    @DisplayName("Upsert bez istniejącego tagu tworzy nowy tag i zwraca created=true")
    void upsertUserTag_insert_shouldCreateTagAndReturnCreatedTrue() {
        CreateTagRequest request = CreateTagRequest.builder()
                .name("My tag").filters("category: sport").build();
        Tag persisted = buildTag(41L, "My tag", "category: sport", "jan.kowalski");
        TagResponse response = TagResponse.builder().id(41L).name("My tag").build();
        when(tagSecurityPolicy.requireAuthenticatedUser("jan.kowalski")).thenReturn("jan.kowalski");
        when(tagRepository.existsByOwnerIsNullAndName("My tag")).thenReturn(false);
        when(tagRepository.findByOwnerAndName("jan.kowalski", "My tag")).thenReturn(Optional.empty());
        when(tagRepository.save(any(Tag.class))).thenReturn(persisted);
        when(tagMapper.toResponse(persisted)).thenReturn(response);

        UpsertTagResult result = service.upsertUserTag(request, "jan.kowalski");

        assertThat(result.created()).isTrue();
        assertThat(result.tag()).isEqualTo(response);
        ArgumentCaptor<Tag> captor = ArgumentCaptor.forClass(Tag.class);
        verify(tagRepository).save(captor.capture());
        assertThat(captor.getValue().getOwner()).isEqualTo("jan.kowalski");
    }

    @Test
    @DisplayName("Żądanie nieistniejącego tagu kończy się TagNotFoundException")
    void shouldThrowNotFoundWhenVisibleTagDoesNotExist() {
        when(tagSecurityPolicy.requireAuthenticatedUser("jan.kowalski")).thenReturn("jan.kowalski");
        when(tagRepository.findByIdVisibleToUser(99L, "jan.kowalski")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.getVisibleTagForUser(99L, "jan.kowalski"))
                .isInstanceOf(TagNotFoundException.class)
                .hasMessageContaining("99");
    }
}
```

Wzorce warte skopiowania (realne z `tag-service`):

- `ArgumentCaptor` do sprawdzenia, **co** poszło do repozytorium — nie tylko że poszło.
- Wyjątki testuj `assertThatThrownBy(...).isInstanceOf(...).hasMessageContaining(...)`.
- Kolekcje testuj semantycznie: `containsExactly`, `extracting(Tag::getName)`,
  `allSatisfy(...)`, `Tuple.tuple(...)` — nie porównuj ręcznie elementów w pętli.

### Walidacja DTO bez podnoszenia kontekstu

Adnotacje Jakarta Validation na DTO testuj bezpośrednio `Validator`-em
(wzorzec `CreateTagRequestValidationTest`):

```java
class CreateTagRequestValidationTest {

    private static final Validator VALIDATOR =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    @DisplayName("Pusta nazwa tagu jest odrzucana przez walidację")
    void shouldRejectBlankName() {
        CreateTagRequest request = CreateTagRequest.builder()
                .name("   ").filters("category:sport").build();

        Set<ConstraintViolation<CreateTagRequest>> violations = VALIDATOR.validate(request);

        assertThat(violations)
                .extracting(v -> v.getPropertyPath().toString())
                .containsExactly("name");
    }
}
```

---

## 2. Testy warstwy web — `@WebMvcTest`

Kontrakt HTTP kontrolera testuj wycinkiem web, z mockowaną warstwą serwisową.
Uwaga na pakiety Spring Boot 4: `org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest`
oraz `@MockitoBean` (następca `@MockBean`):

```java
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

/**
 * Testy warstwy HTTP dla {@link TagController} z mockowaną warstwą serwisową.
 */
@WebMvcTest(controllers = TagController.class)
@AutoConfigureMockMvc(addFilters = false)
@Import(GlobalExceptionHandler.class)
class TagControllerTest {

    @MockitoBean
    private TagService tagService;

    @MockitoBean
    private TagRequestUserResolver tagRequestUserResolver;

    @MockitoBean
    private JwtTokenService jwtTokenService;

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("POST /api/v1/tags przy wstawieniu zwraca 201 i utworzony tag")
    void upsertUserTag_insert_shouldReturn201() throws Exception {
        when(tagRequestUserResolver.resolveRequiredUserSub(any())).thenReturn("dalet_admin");
        TagResponse tag = TagResponse.builder()
                .id(15L).name("NBA News").filters("nba:true").owner("dalet_admin").build();
        when(tagService.upsertUserTag(any(), eq("dalet_admin")))
                .thenReturn(new UpsertTagResult(tag, true));

        mockMvc.perform(post("/api/v1/tags")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {
                                  "name": "NBA News",
                                  "filters": "nba:true"
                                }
                                """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").value(15))
                .andExpect(jsonPath("$.owner").value("dalet_admin"));
    }

    @Test
    @DisplayName("Konflikt przestrzeni nazw mapuje się na 409 ze spójnym ErrorDto")
    void upsertUserTag_whenNamespaceCollision_shouldReturn409() throws Exception {
        when(tagRequestUserResolver.resolveRequiredUserSub(any())).thenReturn("dalet_admin");
        when(tagService.upsertUserTag(any(), eq("dalet_admin")))
                .thenThrow(TagConflictException.forNamespaceCollision("NBA News"));

        mockMvc.perform(post("/api/v1/tags")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name": "NBA News", "filters": "nba:true"}
                                """))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.statusCode").value(409))
                .andExpect(jsonPath("$.title").value("Tag conflict"));
    }
}
```

Kluczowe elementy wzorca:

- `@AutoConfigureMockMvc(addFilters = false)` — filtry security wyłączone; autoryzację testują
  osobne testy integracyjne security, nie każdy test kontrolera.
- `@Import(GlobalExceptionHandler.class)` — handler z biblioteki `com.cn.fuse.common:consul`
  nie jest częścią wycinka `@WebMvcTest`, importujesz go jawnie, żeby przetestować mapowanie
  wyjątków domenowych na `ErrorDto`.
- Body żądań jako text blocks — czytelny JSON w teście.
- Testuj także ścieżki błędów: 400 (walidacja), 404, 409 — z asercją na pola `ErrorDto`
  (`statusCode`, `statusName`, `title`, `detail`, `instance`).

### Pełny stack HTTP: `spring-boot-resttestclient`

Rodzicielski POM dostarcza `spring-boot-resttestclient` (test-scope). Przy testach
`@SpringBootTest(webEnvironment = RANDOM_PORT)`, gdzie chcesz przejść przez prawdziwy serwer
(filtry JWT włącznie), używaj `RestTestClient` zamiast ręcznego `RestTemplate` + `@LocalServerPort`:

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("test")
class TagEndpointHttpTest {

    @Autowired
    private RestTestClient restTestClient;

    @Test
    @DisplayName("GET /api/v1/tags bez tokenu zwraca 401 (deny-by-default)")
    void shouldReturn401WithoutToken() {
        restTestClient.get().uri("/api/v1/tags")
                .exchange()
                .expectStatus().isUnauthorized();
    }
}
```

---

## 3. WireMock — stubowanie zewnętrznych serwisów

Zależność: `spring-cloud-contract-wiremock` (test-scope, wersja z BOM Spring Cloud).
Reguły twarde:

- **Nigdy realny HTTP** — każdy test dotykający Dalet/indexer/auth stubuje odpowiedzi.
- Payloady odpowiedzi jako pliki w `src/test/resources/__files/` (WireMock czyta je przez
  `withBodyFile("plik.xml")`) — nie inline'uj wielkich XML-i/JSON-ów w Javie.
- Port WireMocka dynamiczny, propagowany do konfiguracji Springa property
  `wiremock.server.port`; `application-test.yml` używa go w URL-ach zależności.

### Wzorzec bazowej klasy testowej (realny z `category-service`)

Jeden serwer WireMock na JVM, wystartowany zanim Spring zbuduje kontekst
(inicjalizator statyczny), żeby placeholder `${wiremock.server.port}` był już rozwiązywalny:

```java
@SpringBootTest(
        classes = CategoryServiceApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
public class BaseTestConfig {

    private static final WireMockServer DYNAMIC_WIRE_MOCK =
            new WireMockServer(options().dynamicPort());

    static {
        DYNAMIC_WIRE_MOCK.start();
        wireMockServer = DYNAMIC_WIRE_MOCK;
        System.setProperty("wiremock.server.port", String.valueOf(DYNAMIC_WIRE_MOCK.port()));
    }

    @BeforeAll
    static void setup() {
        WireMock.configureFor("localhost", wireMockServer.port());
        wireMockServer.checkForUnmatchedRequests();
    }

    @AfterAll
    static void tearDown() {
        if (wireMockServer != null) {
            wireMockServer.stop();
        }
        System.clearProperty("wiremock.server.port");
    }
}
```

Stuby trzymaj w klasie pomocniczej (`WireMockHelper`), z payloadem z `__files`:

```java
public static void stubGetSubCategories(String responseFile, int status) {
    wireMockServer.stubFor(post(urlEqualTo("/DaletWebService/services/CategoryService"))
            .withRequestBody(WireMock.containing("getSubCategories"))
            .willReturn(aResponse()
                    .withStatus(status)
                    .withHeader("Content-Type", "text/xml; charset=utf-8")
                    .withBodyFile(responseFile)));
}
```

Test wywołuje stub po nazwie pliku — scenariusz jest czytelny na pierwszy rzut oka:

```java
@Test
@DisplayName("Awaria Daleta (500) mapuje się na kontrolowany błąd domenowy")
void shouldMapDaletFailureToDomainError() {
    WireMockHelper.stubGetSubCategories("getSubCategoriesError.xml", 500);
    // ... wywołanie serwisu + asercje na wyjątek domenowy
}
```

Dla przepływów wieloetapowych (login → zapytanie → odświeżenie tokenu) używaj
scenariuszy WireMock (`inScenario(...)`, `whenScenarioStateIs(...)`, `willSetStateTo(...)`).

### `application-test.yml` — profil testowy

Profil `test` odcina Consula i kieruje zależności na WireMock/lokalne zasoby
(realny plik z `tag-service`):

```yaml
spring:
  application:
    name: tag-service
  config:
    import: ""
  cloud:
    consul:
      enabled: false
      config:
        enabled: false
        import-check:
          enabled: false
  datasource:
    url: "jdbc:postgresql://localhost:5432/fusedb"
    username: "postgres"
    password: "postgres"
  flyway:
    enabled: true
  jpa:
    hibernate:
      ddl-auto: validate

app:
  jwt:
    secret_base64: "${JWT_SECRET_BASE64:bXVzdC1iZS0zMi1ieXRlcy1tdXN0LWJlLTMyYnl0ZXM=}"

wiremock:
  server:
    port: 0
```

Zauważ: `spring.config.import: ""` + trzy flagi `consul.*.enabled: false` — bez tego
kontekst testowy próbowałby się łączyć z Consulem i wywalał start (fail-fast).

Stubowanie issuera JWT (żeby security działało bez auth-service) — wzorzec z
`TagServiceIntegrationTestBase`:

```java
@BeforeEach
void stubJwtIssuerEndpoints() {
    WIRE_MOCK_SERVER.resetAll();
    stubFor(get(urlEqualTo("/.well-known/openid-configuration"))
            .willReturn(aResponse()
                    .withStatus(200)
                    .withHeader("Content-Type", "application/json")
                    .withBody("""
                            {
                              "issuer": "auth-service",
                              "jwks_uri": "http://localhost/__wiremock/jwks"
                            }
                            """)));
}
```

---

## 4. Testcontainers 2.x — integracja JPA/Flyway na realnym Postgresie

Testy repozytoriów i migracji chodzą na prawdziwym PostgreSQL (nie H2), z pełnym
łańcuchem migracji Flyway. Zależności (BOM w `dependencyManagement` modułu):

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>org.testcontainers</groupId>
            <artifactId>testcontainers-bom</artifactId>
            <version>2.0.5</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>

<dependencies>
    <dependency>
        <groupId>org.testcontainers</groupId>
        <artifactId>testcontainers-junit-jupiter</artifactId>
        <scope>test</scope>
    </dependency>
    <dependency>
        <groupId>org.testcontainers</groupId>
        <artifactId>testcontainers-postgresql</artifactId>
        <scope>test</scope>
    </dependency>
</dependencies>
```

### Wzorzec singleton-kontenera (realny z `tag-service`)

**Świadomie bez `@Testcontainers`/`@Container`** — te adnotacje zatrzymują kontener po każdej
klasie testowej, a przy cache'owanym kontekście Springa kończy się to `Connection refused`
(Spring trzyma stary URL z `DynamicPropertyRegistry`). Jeden kontener na JVM:

```java
@ActiveProfiles("test")
@SpringBootTest(classes = TagServiceApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK)
public abstract class TagServiceIntegrationTestBase {

    private static final PostgreSQLContainer<?> POSTGRESQL_CONTAINER =
            new PostgreSQLContainer<>("postgres:18.4")
                    .withDatabaseName("fusedb")
                    .withUsername("postgres")
                    .withPassword("postgres");

    static {
        if (DockerClientFactory.instance().isDockerAvailable()) {
            POSTGRESQL_CONTAINER.start();
        }
    }

    @BeforeAll
    static void requireDocker() {
        Assumptions.assumeTrue(DockerClientFactory.instance().isDockerAvailable(),
                "Docker is required for tag-service integration tests");
    }

    @DynamicPropertySource
    static void registerPostgresProperties(DynamicPropertyRegistry registry) {
        if (!DockerClientFactory.instance().isDockerAvailable()) {
            return;
        }
        registry.add("spring.datasource.url", POSTGRESQL_CONTAINER::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRESQL_CONTAINER::getUsername);
        registry.add("spring.datasource.password", POSTGRESQL_CONTAINER::getPassword);
    }
}
```

Elementy nie do pominięcia:

- Guard `DockerClientFactory.instance().isDockerAvailable()` **zarówno** w inicjalizatorze
  statycznym, jak i w `@DynamicPropertySource` — bez niego brak Dockera wywala
  `IllegalStateException` zamiast czystego skipa przez `Assumptions`.
- Flyway uruchamia migracje przy starcie kontekstu (`spring.flyway.enabled: true` w profilu test) —
  test integracyjny weryfikuje więc też same migracje i seedy.

Przykładowy test repozytorium na tej bazie:

```java
class TagRepositoryPostgresIntegrationTest extends TagServiceIntegrationTestBase {

    @Autowired
    private TagRepository tagRepository;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Test
    @Transactional
    @DisplayName("Migracje Flyway seedują komplet tagów systemowych")
    void shouldLoadSystemTagsSeededByFlyway() {
        List<Tag> systemTags = tagRepository.findByOwnerIsNull();

        assertThat(systemTags)
                .extracting(Tag::getName)
                .containsExactly("24h", "Audio Only", "Football", "Images Only",
                        "NBA News", "Project Only", "Video Only");
    }

    @Test
    @DisplayName("Seed systemowych tagów jest idempotentny (ON CONFLICT DO NOTHING)")
    void shouldBeSeedIdempotent() {
        long countBefore = tagRepository.findByOwnerIsNull().size();

        jdbcTemplate.update("""
                INSERT INTO tag (name, filters, owner)
                VALUES ('Video Only', 'typ: Video', NULL)
                ON CONFLICT (name) WHERE owner IS NULL DO NOTHING
                """);

        assertThat((long) tagRepository.findByOwnerIsNull().size()).isEqualTo(countBefore);
    }
}
```

Testy modyfikujące dane oznaczaj `@Transactional` (rollback po teście); testy sprawdzające
zachowanie constraintów DB (jak idempotencja seedu) — bez transakcji, żeby zobaczyć realny efekt.

---

## 5. `ApplicationContextRunner` — biblioteki auto-config

Auto-konfiguracje bibliotek współdzielonych (`com.cn.fuse.common:consul`) testuj bez pełnego
`@SpringBootTest` — `ApplicationContextRunner` podnosi minimalny kontekst per test
(realny wzorzec z `RuntimeAutoConfigurationTest`):

```java
class RuntimeAutoConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(RuntimeAutoConfiguration.class));

    @Test
    @DisplayName("Bez property tryb runtime domyślnie STANDARD")
    void shouldRegisterRuntimeModeProperties_withDefaultMode() {
        contextRunner.run(context -> {
            assertThat(context).hasSingleBean(RuntimeModeProperties.class);
            assertThat(context.getBean(RuntimeModeProperties.class).resolvedMode())
                    .isEqualTo(RuntimeMode.STANDARD);
        });
    }

    @Test
    @DisplayName("app.runtime.mode=demo-offline przełącza tryb na DEMO_OFFLINE")
    void shouldRegisterRuntimeModeProperties_withDemoOfflineMode() {
        contextRunner
                .withPropertyValues("app.runtime.mode=demo-offline")
                .run(context -> {
                    assertThat(context.getBean(RuntimeModeProperties.class).isDemoOffline())
                            .isTrue();
                });
    }
}
```

Testuj tym wzorcem: rejestrację beanów warunkowych (`@ConditionalOnProperty`),
back-off gdy użytkownik dostarczy własny bean, poprawność bindowania `@ConfigurationProperties`.

---

## 6. Pokrycie — JaCoCo 95% LINE

Moduły serwisowe mają JaCoCo z progiem podpiętym do `verify`:

```xml
<rule>
    <element>BUNDLE</element>
    <limits>
        <limit>
            <counter>LINE</counter>
            <value>COVEREDRATIO</value>
            <minimum>0.95</minimum>
        </limit>
    </limits>
</rule>
```

Reguły:

- **ZAKAZ obniżania progu** i zakaz dosypywania wykluczeń, żeby "przeszło". Jeśli pokrycie
  spada — brakuje testów, nie próg jest za wysoki.
- Nowy kod projektuj tak, by dało się go pokryć: cienkie kontrolery, logika w serwisach,
  zależności za interfejsami.
- Kodu nietestowalnego z natury (np. `main()`) nie kompensuj sztucznymi testami "odpal i zapomnij" —
  jeśli naprawdę trzeba, wyklucz świadomie w konfiguracji JaCoCo i uzasadnij w opisie MR.
- Raport lokalnie: `mvn clean verify`, wynik w `target/site/jacoco/index.html`.

---

## 7. Uruchamianie testów

```bash
mvn test                                        # wszystkie testy modułu (z katalogu modułu)
mvn test -Dtest=DefaultTagServiceTest           # jedna klasa
mvn test -Dtest=DefaultTagServiceTest#shouldReturnVisibleTagsForUser   # jedna metoda
mvn test -Dtest="TagControllerTest,TagMapperTest"                      # kilka klas
mvn test -DskipITs                              # bez testów integracyjnych (szybszy feedback)
mvn clean verify                                # pełny build: testy + JaCoCo check + checkstyle DEV-502
```

Wskazówki:

- Podczas iteracji nad jedną klasą używaj `-Dtest=Klasa#metoda` — pełny `verify` zostaw na koniec.
- Testy integracyjne wymagają Dockera (Testcontainers); bez Dockera są pomijane przez
  `Assumptions`, nie failują — ale przed MR odpal je z działającym Dockerem.
- `mvn clean verify` z roota buduje całe monorepo; z katalogu modułu — tylko moduł.

---

## Anty-wzorce (blokujące review)

| Anty-wzorzec | Co zamiast |
|--------------|------------|
| Realne wywołanie HTTP w teście | Stub WireMock + payload w `__files` |
| Test bez asercji / tylko `verify` | Minimum jedna asercja AssertJ na efekt |
| Mock/spy klasy testowanej | Mockuj tylko zależności |
| H2 do testów logiki SQL specyficznej dla Postgresa | Testcontainers Postgres + Flyway |
| Obniżenie progu JaCoCo lub nowe wykluczenie "bo nie zdąży" | Dopisz testy |
| `Thread.sleep` w teście | Awaitility / scenariusze WireMock / sterowanie zegarem |
| Test zależny od kolejności innych testów | Testy niezależne, dane budowane per test |
| `@SpringBootTest` dla czystej logiki domenowej | Zwykły test jednostkowy z Mockito |
| Angielskie opisy testów / brak opisu | `@DisplayName` po polsku + polski Javadoc klasy |
| Stuby WireMock inline z gigantycznym XML w Javie | `withBodyFile(...)` + plik w `src/test/resources/__files/` |
