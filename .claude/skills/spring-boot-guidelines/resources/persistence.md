# Persystencja: JPA + Flyway + Redis + Elasticsearch (stack CN)

Warstwa danych CN: PostgreSQL zarządzany wyłącznie migracjami Flyway, dostęp przez Spring Data JPA
za portem domenowym, cache w Redis, wyszukiwanie pełnotekstowe w Elasticsearch (przez indexer).

---

## 1. Migracje Flyway

### Nazewnictwo i lokalizacja

Migracje żyją w `src/main/resources/db/migration/`, nazwy w formacie `V<nr>__opis.sql`
(numer zero-padowany, opis po angielsku, snake_case) — realny łańcuch z `tag-service`:

```
db/migration/
├── V001__init_tag_table.sql
├── V002__seed_system_tags.sql
└── V003__seed_system_tags_dsl.sql
```

### Reguły twarde

- **Nigdy nie edytuj zaaplikowanej migracji.** Flyway waliduje checksumy — zmiana istniejącego
  pliku wywala start każdego środowiska, które migrację już wykonało. Poprawka = NOWA migracja
  (`V004__fix_...`), nawet jeśli poprzednią napisałeś pięć minut temu, ale trafiła już na dev.
- Schemat tworzy **wyłącznie** Flyway. Hibernate tylko waliduje:

```yaml
spring:
  flyway:
    enabled: true
  jpa:
    hibernate:
      ddl-auto: validate
```

- Jedna migracja = jedna spójna zmiana (tabela + jej indeksy + constrainty razem; niepowiązane
  zmiany rozdzielaj).
- Migracje piszemy w czystym SQL Postgresa — bez wersji Java-based, dopóki nie są niezbędne.

### Seedy — zawsze idempotentne

Seedy (dane systemowe, dane e2e) muszą przeżyć wielokrotne wykonanie — wzorzec z
`V002__seed_system_tags.sql`:

```sql
INSERT INTO tag (name, filters, owner)
VALUES
    ('NBA News', 'category: sport, nba', NULL),
    ('Football', 'category: sport, football', NULL)
ON CONFLICT (name) WHERE owner IS NULL DO NOTHING;
```

`ON CONFLICT ... DO NOTHING` na częściowym indeksie unikalności zamiast gołego `INSERT`.
Ta sama zasada dotyczy seedów e2e (`e2e/seeds/*.sql` uruchamianych psql-em) — skrypt seedujący
odpalony drugi raz nie może ani failować, ani duplikować danych. Idempotencję seedu
weryfikuje test integracyjny (patrz `resources/testing.md`, sekcja Testcontainers).

### Przykład migracji init

```sql
CREATE TABLE tag (
    id         BIGSERIAL PRIMARY KEY,
    name       VARCHAR(128) NOT NULL,
    filters    TEXT         NOT NULL,
    owner      VARCHAR(128),
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_tag_system_name ON tag (name) WHERE owner IS NULL;
CREATE UNIQUE INDEX uq_tag_owner_name ON tag (owner, name) WHERE owner IS NOT NULL;
```

Unikalność egzekwuj w bazie (indeksy), nie tylko w Javie — serwis i tak łapie
`DataIntegrityViolationException` jako ochronę przed race condition (patrz `DefaultTagService`).

---

## 2. Encje JPA

Wzorzec encji z `tag-service` — Lombok, timestampy od Hibernate, kolumny jawnie opisane:

```java
@Entity
@Table(name = "tag")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Tag {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 128)
    private String name;

    @Column(nullable = false, columnDefinition = "TEXT")
    private String filters;

    @Column(length = 128)
    private String owner;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @UpdateTimestamp
    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;
}
```

Zasady:

- Ograniczenia kolumn (`nullable`, `length`) w encji mają odzwierciedlać migrację 1:1 —
  `ddl-auto: validate` wychwyci rozjazd przy starcie.
- Czas w encjach jako `Instant` (UTC); strefy i formatowanie to sprawa DTO/API
  (`OffsetDateTime` w odpowiedzi).
- `@CreationTimestamp`/`@UpdateTimestamp` zamiast ręcznego ustawiania dat w serwisie.

### equals/hashCode encji

**Nie generuj** `@EqualsAndHashCode`/`@Data` na encjach. Domyślna tożsamość referencyjna jest
zwykle wystarczająca. Jeśli encja ląduje w `Set`/mapach i equals jest potrzebny — porównuj
wyłącznie po identyfikatorze, z obsługą encji jeszcze niezapisanej (id `null` ≠ nic):

```java
@Override
public boolean equals(Object o) {
    if (this == o) {
        return true;
    }
    if (!(o instanceof Tag other)) {
        return false;
    }
    return id != null && id.equals(other.id);
}

@Override
public int hashCode() {
    return getClass().hashCode();
}
```

Stały `hashCode` klasy jest celowy: id zmienia się z `null` na wartość przy zapisie, więc hash
oparty o id psułby kontrakt w kolekcjach. Nigdy nie wliczaj pól mutowalnych ani relacji LAZY.

### Encja vs DTO — twarda granica

- **Encja NIGDY nie jest typem odpowiedzi API** ani argumentem kontrolera. Zawsze mapper
  (dedykowana klasa, np. `TagMapper`) przepisuje encję na DTO (`TagResponse`).
- Encje nie wychodzą też do cache Redis ani do payloadów między serwisami — serializujesz DTO.
- Kierunek zależności: `api/dto` → `service` → `domain`; encja żyje w `domain`,
  DTO w `api/dto`, mapper w `service/mapper`.

### Repozytorium za portem domenowym

Interfejs repozytorium definiuje domena, implementację dostarcza adapter JPA
(układ z `tag-service`: `domain/TagRepository` ← `domain/sql/SqlTagRepository` + `JpaTagRepository`):

```java
public interface TagRepository {
    List<Tag> findVisibleToUser(String owner);
    Optional<Tag> findByIdVisibleToUser(Long id, String owner);
    Tag save(Tag tag);
    void delete(Tag tag);
}
```

Dzięki temu serwis testujesz mockiem portu, a szczegóły Spring Data (metody derived,
`@Query`) zostają w adapterze.

---

## 3. N+1 i pobieranie relacji

- Relacje `@ManyToOne`/`@OneToMany` domyślnie **LAZY** (`@ManyToOne(fetch = FetchType.LAZY)` —
  jawnie, bo domyślne dla `@ManyToOne` jest EAGER).
- Listy z relacjami pobieraj świadomie: `@EntityGraph` albo `join fetch` — nigdy nie licz na
  "jakoś się doładuje" (N+1 przy serializacji to klasyka):

```java
public interface JpaOrderRepository extends JpaRepository<Order, Long> {

    @EntityGraph(attributePaths = {"items", "items.product"})
    List<Order> findByOwner(String owner);

    @Query("select o from Order o join fetch o.items where o.id = :id")
    Optional<Order> findByIdWithItems(@Param("id") Long id);
}
```

- Nie łącz `join fetch` kolekcji z paginacją (Hibernate pagniuje w pamięci) — dla stron
  pobierz identyfikatory, potem doładuj kolekcje drugim zapytaniem.
- Podejrzenie N+1 weryfikuj w teście integracyjnym: włącz logowanie SQL w profilu test
  i sprawdź liczbę zapytań, zanim "zoptymalizujesz".
- Odczyty oznaczaj `@Transactional(readOnly = true)` na metodzie serwisu; zapisy — `@Transactional`.

---

## 4. Redis — cache aplikacyjny

### Konwencje

- **Klucze cache wersjonowane**: `nazwa:v1` (`categories:v1`, `nestedCategories:v1`,
  `assetStatuses:v1`, `daletFieldsCache:v1`). Zmiana formatu wartości = bump do `:v2`,
  stary klucz wygasa sam — zero migracji cache.
- **Jawne TTL per cache**, wartości sterowane konfiguracją (Consul), nie hardcodem.
  Realne TTL: kategorie 60 s, statusy assetów 7 dni, pola Dalet 1 godz.
- **Cache wyłączony w profilu `test`**: klasa konfiguracji cache ma `@Profile("!test")`.
- Cache jest optymalizacją, nie źródłem prawdy — awaria Redisa nie może wywalać żądań
  (biblioteka `com.cn.fuse.common:consul` dostarcza `RedisCacheErrorHandler`, który degraduje
  do przejścia mimo cache).

### Wzorzec konfiguracji (realny z `category-service`)

```java
@Configuration
@Profile("!test")
public class CategoryCacheConfig {

    public static final String CATEGORIES_CACHE = "categories:v1";
    public static final String NESTED_CATEGORIES_CACHE = "nestedCategories:v1";

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory connectionFactory,
                                          RedisCacheConfiguration defaultRedisCacheConfiguration,
                                          CategoriesCachePropertiesView categoriesCacheProperties,
                                          NestedCategoriesCachePropertiesView nestedCategoriesCacheProperties) {
        RedisCacheConfiguration categoriesConfig = defaultRedisCacheConfiguration
                .disableCachingNullValues()
                .serializeValuesWith(/* typed JacksonJsonRedisSerializer */);

        return RedisCacheManager.builder(connectionFactory)
                .cacheDefaults(defaultRedisCacheConfiguration)
                .withInitialCacheConfigurations(Map.of(
                        CATEGORIES_CACHE,
                        categoriesConfig.entryTtl((key, value) -> categoriesCacheProperties.ttl())
                ))
                .build();
    }
}
```

Szczegóły warte uwagi:

- Nazwy cache jako `public static final String` — użycie w `@Cacheable(CATEGORIES_CACHE)`
  bez literałów rozsianych po kodzie.
- **Typowany serializer wartości** (`JacksonJsonRedisSerializer` z konkretnym `JavaType`,
  Jackson 3: pakiety `tools.jackson.databind`) zamiast domyślnej serializacji JDK — payload
  w Redis jest czytelnym JSON-em i nie łamie się przy zmianie classpath.
- `disableCachingNullValues()` — nie cache'ujemy nulli.
- TTL wstrzykiwane przez widok properties (interfejs `...PropertiesView` z metodą `ttl()`),
  wartość przychodzi z Consula.

### Użycie

```java
@Cacheable(cacheNames = CategoryCacheConfig.CATEGORIES_CACHE)
public List<CategoryDto> getCategories(String daletToken) {
    return daletCategoryClient.fetchCategories(daletToken);
}
```

Do cache trafiają **DTO**, nie encje. Metody `@Cacheable` wołaj z innego beana
(self-invocation omija proxy).

---

## 5. Elasticsearch — podstawy query-shape

W stacku CN Elasticsearch stoi za wyszukiwaniem assetów, ale serwisy **nie budują zapytań ES
bezpośrednio** — `asset-service` przekazuje kryteria do indexera (JSON body na
`POST /api/v1/assets/search`), a indexer tłumaczy je na zapytanie ES. Zasady, które z tego wynikają:

- **Nie parsuj składni wyszukiwania po swojej stronie** — `filters` (`pole:wartość`) i `freeText`
  forwardujesz 1:1; interpretacja (CONTAINS vs STRICT `+`, operatory Lucene) należy do indexera/ES.
- `freeText` ląduje w ES jako `query_string` — operatory Lucene (`+`, `AND`, `OR`, nawiasy)
  interpretuje Elasticsearch; wiele elementów listy łączy się semantyką AND.
- **Bezpieczeństwo fail-closed**: filtrowanie po uprawnieniach robi indexer na podstawie `userId`
  i ról z JWT — serwis forwarduje token 1:1 i NIE dobudowuje własnego filtra widoczności.
  Brak dostępu = pusta strona wyników, nie błąd.
- Wyniki mają semantykę **eventual consistency** (stan indeksu, nie bazy) — UI i testy nie mogą
  zakładać natychmiastowej widoczności świeżo zapisanych danych.

Jeśli budujesz zapytanie ES bezpośrednio (nowa integracja), trzymaj kształt:

```json
{
  "query": {
    "bool": {
      "must": [
        { "query_string": { "query": "lebron +bukiecik", "default_operator": "AND" } }
      ],
      "filter": [
        { "term":  { "assetType": "Video" } },
        { "range": { "createdAt": { "gte": "now-7d/d" } } }
      ]
    }
  },
  "from": 0,
  "size": 25,
  "sort": [{ "createdAt": "desc" }]
}
```

- Warunki binarne (typ, status, zakresy dat) do `filter` (cache'owalne, bez scoringu),
  tekst do `must`/`query_string`.
- Paginacja `from`/`size` z twardym limitem rozmiaru strony; głęboka paginacja → `search_after`.
- W testach ES/indexer stubujesz WireMockiem jak każdy inny serwis HTTP — nigdy realny klaster.

---

## Anty-wzorce persystencji

| Anty-wzorzec | Co zamiast |
|--------------|------------|
| Edycja zaaplikowanej migracji | Nowa migracja `V<nr+1>__fix_...` |
| `ddl-auto: update` / tworzenie schematu przez Hibernate | Flyway + `validate` |
| Seed bez idempotencji | `ON CONFLICT ... DO NOTHING` / `WHERE NOT EXISTS` |
| Encja jako response/request API | DTO + mapper |
| `@Data`/`@EqualsAndHashCode` na encji | Getter/Setter + ewentualnie equals po id |
| EAGER wszędzie / brak planu na N+1 | LAZY + `@EntityGraph`/`join fetch` |
| `join fetch` kolekcji + `Pageable` | Dwufazowe pobranie (id → kolekcje) |
| Klucz cache bez wersji, TTL "domyślne" | `nazwa:v1` + jawne TTL z konfiguracji |
| Cache aktywny w testach | `@Profile("!test")` na konfiguracji cache |
| Własny filtr uprawnień do wyszukiwania w serwisie | Token JWT 1:1 do indexera, fail-closed |
