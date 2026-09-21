# REST API (stack CN)

Projektowanie i implementacja endpointów w serwisach CN: kontrakty DTO, walidacja,
spójna obsługa błędów, dokumentacja OpenAPI, komunikacja między serwisami.

---

## 1. Projekt endpointów

- Ścieżki pod `/api/v1/<zasób>`; rzeczowniki w liczbie mnogiej (`/api/v1/tags`,
  `/api/v1/assets/search`, `/api/v1/categories/{id}`).
- Kody statusów niosą semantykę: `200` odczyt/aktualizacja, `201` utworzenie, `204` usunięcie
  bez body, `400` walidacja, `401` brak/zły JWT, `403` brak uprawnień, `404` brak zasobu,
  `409` konflikt.
- Wzorzec upsert z rozróżnieniem insert/update (realny z `tag-service`): serwis zwraca rekord
  wynikowy z flagą, kontroler wybiera status:

```java
public record UpsertTagResult(TagResponse tag, boolean created) {
}
```

```java
@PostMapping
public ResponseEntity<TagResponse> upsertUserTag(@Valid @RequestBody CreateTagRequest requestBody,
                                                 HttpServletRequest request) {
    String sub = tagRequestUserResolver.resolveRequiredUserSub(request);
    UpsertTagResult result = tagService.upsertUserTag(requestBody, sub);
    HttpStatus status = result.created() ? HttpStatus.CREATED : HttpStatus.OK;
    return ResponseEntity.status(status).body(result.tag());
}
```

- Kontroler jest cienki: tożsamość z JWT (resolver), delegacja do serwisu, status + body.
  Zero logiki domenowej i zero mapowania wyjątków w kontrolerze.
- Klasa kontrolera: `@Validated @RestController @RequestMapping("/api/v1/...") @RequiredArgsConstructor`.

## 2. DTO — rekordy + Jakarta Validation

DTO to kontrakt API: niemutowalne, walidowane na granicy, JSON camelCase.
Dla nowych DTO preferuj rekordy Java 21 (zwięzłość, `-parameters` w kompilacji załatwia
nazwy pól dla Jacksona i Springa):

```java
@Schema(description = "Żądanie utworzenia tagu użytkownika.")
public record CreateTagRequest(

        @NotBlank
        @Size(max = 128)
        @Schema(description = "Nazwa tagu użytkownika.", example = "NBA News", maxLength = 128)
        String name,

        @NotBlank
        @Size(max = 4096)
        @Schema(description = "Treść filtrów wyszukiwania.", example = "category:sport, nba")
        String filters) {
}
```

Istniejące moduły cn-mediaconnector używają wzorca Lombok — **bądź spójny z modułem**,
w którym pracujesz; nie mieszaj obu stylów w jednym pakiecie DTO:

```java
@Value
@Builder
@Jacksonized
public class TagResponse {
    Long id;
    String name;
    String filters;
    String owner;
    String type;
    OffsetDateTime createdAt;
    OffsetDateTime updatedAt;
}
```

Zasady:

- Walidacja techniczna (obecność, długości, zakresy) na DTO; semantyka (unikalność,
  uprawnienia) w serwisie. DTO nie interpretuje danych domenowych.
- `@Valid` na `@RequestBody`; walidacja parametrów ścieżki/zapytania przez `@Validated`
  na klasie + adnotacje na parametrach (`@PathVariable @Positive Long id`).
- Encja JPA nigdy nie jest DTO (patrz `resources/persistence.md`).
- Daty w odpowiedziach jako `OffsetDateTime` ISO-8601 UTC (`2026-05-25T09:15:00Z`).
- Wewnętrzne wyniki wielowartościowe: małe rekordy (`UpsertTagResult`) zamiast `Pair`/map.

## 3. Obsługa błędów — `AppException` + `@RestControllerAdvice`

Jeden spójny format błędu w całym stacku — `ErrorDto` z biblioteki `com.cn.fuse.common:consul`:

```java
public record ErrorDto(int statusCode, String statusName, String title, String detail, String instance) {
}
```

Przykładowa odpowiedź (realny snapshot z tag-service):

```json
{
  "statusCode": 400,
  "statusName": "BAD_REQUEST",
  "title": "Validation failed",
  "detail": "name: must not be blank",
  "instance": "/api/v1/tags"
}
```

### Wyjątki domenowe

Bazowy `AppException` niesie `detail`, `title` i docelowy `HttpStatus`:

```java
public abstract class AppException extends RuntimeException {
    private final String detail;
    private final String title;
    private final HttpStatus httpStatus;
}
```

Konkretne wyjątki: prywatny konstruktor + **statyczne fabryki nazwane od scenariusza**
(wzorzec z `TagConflictException` / `TagNotFoundException`):

```java
public class TagNotFoundException extends AppException {

    private static final String TITLE = "Tag not found";

    private TagNotFoundException(String detail) {
        super(detail, TITLE, NOT_FOUND);
    }

    public static TagNotFoundException forSystemTag(Long id) {
        return new TagNotFoundException("Tag systemowy o id " + id + " nie istnieje.");
    }
}
```

Serwis rzuca (`orElseThrow(() -> TagNotFoundException.forSystemTag(id))`), a współdzielony
`GlobalExceptionHandler` (`@RestControllerAdvice`) mapuje na odpowiedź:

```java
@ExceptionHandler(AppException.class)
public ResponseEntity<ErrorDto> handleAppException(AppException ex, HttpServletRequest request) {
    ErrorDto dto = new ErrorDto(
            ex.getHttpStatus().value(),
            ex.getHttpStatus().name(),
            ex.getTitle(),
            ex.getDetail(),
            request.getRequestURI());
    return ResponseEntity.status(ex.getHttpStatus()).body(dto);
}
```

Handler obsługuje też: `MethodArgumentNotValidException` (`@Valid` na body → 400 z listą
`pole: komunikat`), `ConstraintViolationException` (parametry → 400),
`HttpMessageNotReadableException` (zepsuty JSON → 400), `MissingServletRequestParameterException`.

Reguły:

- **Nie twórz per-serwis własnych formatów błędów** — zawsze `ErrorDto`. Serwisowy
  `@RestControllerAdvice` dodawaj tylko dla przypadków, których globalny handler nie zna
  (np. multipart upload w asset-service), i też zwracaj `ErrorDto`.
- Nie łap `Exception` szeroko "na wszelki wypadek" — nieznany wyjątek ma polecieć do handlera
  i logów, nie zostać zamieciony.
- `detail` pisz konkretnie, ale **bez sekretów i tokenów** (checkstyle DEV-502 pilnuje logów,
  ty pilnujesz payloadów błędów).

## 4. Wersjonowanie — nowe ścieżki, nigdy łamanie kontraktu w miejscu

- Kontrakt opublikowanego endpointu jest nienaruszalny: nie zmieniaj znaczenia pól, typów,
  kodów statusów ani semantyki istniejącego `/api/v1/...`.
- Zmiany **addytywne** (nowe opcjonalne pole odpowiedzi, nowy endpoint) są OK w ramach v1.
- Zmiana łamiąca → **nowa ścieżka** (`/api/v2/tags`), stara działa równolegle do czasu migracji
  konsumentów (UI, inne serwisy). Usunięcie starej wersji to osobna, komunikowana zmiana
  (commit z `!`/`BREAKING CHANGE`).
- Konsumenci są poza twoim repo (cn-mediaconnector-ui, api-gateway) — nie masz jak
  "poprawić wszystkich wywołań przy okazji".

## 5. Dokumentacja — springdoc-openapi

Każdy serwis wystawia `/swagger-ui.html` i `/v3/api-docs` (springdoc-openapi z parenta).
Endpointy dokumentuj przy kodzie, opisy **po polsku**:

```java
@Operation(
        summary = "Pobierz listę tagów użytkownika",
        description = """
                Zwraca tagi widoczne dla aktualnie zalogowanego użytkownika.

                Endpoint wymaga poprawnego nagłówka `Authorization: Bearer <jwt>`.
                """)
@ApiResponse(responseCode = "200", description = "Zwrócono listę tagów",
        content = @Content(mediaType = "application/json",
                array = @ArraySchema(schema = @Schema(implementation = TagResponse.class))))
@ApiResponse(responseCode = "401", description = "Brak lub niepoprawny token JWT",
        content = @Content(mediaType = "application/json",
                schema = @Schema(implementation = ErrorDto.class)))
@GetMapping
public List<TagResponse> getVisibleTags(HttpServletRequest request) { ... }
```

- Każdy kod błędu z `@ApiResponse` wskazuje `ErrorDto` jako schemat.
- `@Schema(description, example, maxLength)` na polach DTO; `@ExampleObject` z realistycznym
  payloadem dla request body.
- Opisy `@Operation.description` jako text blocks — mogą dokumentować reguły biznesowe
  (walidację, konflikty, semantykę upsert), bo to jedyne miejsce, które widzi konsument API.

## 6. Komunikacja między serwisami — `RestTemplate`

Standard CN: `RestTemplate` konfigurowany per serwis w `RestTemplateConfig`, z timeoutami
z konfiguracji (realny wzorzec z `config-service`):

```java
@Configuration
@RequiredArgsConstructor
public class RestTemplateConfig {

    private final HttpClientTimeoutPropertiesView httpClientTimeoutProperties;

    @Bean
    public RestTemplate restTemplate() {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(httpClientTimeoutProperties.connectionTimeoutMillis());
        requestFactory.setReadTimeout(httpClientTimeoutProperties.readTimeoutMillis());
        return new RestTemplate(requestFactory);
    }
}
```

Zasady:

- **Zawsze jawne timeouty** — `RestTemplate` bez timeoutów wisi w nieskończoność przy awarii
  partnera. Wartości z properties (Consul), nie hardcode.
- Bazowe URL-e partnerów przez konfigurację: `app.category-service.base-url:
  "${CATEGORY_SERVICE_URL:http://localhost:30102}"`.
- Klient do innego serwisu opakuj w dedykowaną klasę (`CategoryServiceRestClient`) —
  serwis domenowy nie widzi `RestTemplate` bezpośrednio; łatwiej mockować i stubować.
- JWT użytkownika przekazuj dalej 1:1 (nagłówek `Authorization`) — wzorzec forwardu tokenu
  do indexera w asset-service; nie buduj po drodze własnych tożsamości.
- Błędy partnera mapuj na wyjątki domenowe (`ConfigServiceException`), nie przepuszczaj
  gołych `HttpClientErrorException` wyżej.
- W testach partner = stub WireMock (patrz `resources/testing.md`) — nigdy realny serwis.

## 7. Paginacja

- Wyszukiwania/listy zwracaj stronami z jawnym kontraktem strony; limit rozmiaru strony
  waliduj (`@Max`), z bezpiecznym domyślnym:

```java
public record PageResponse<T>(
        List<T> items,
        int page,
        int pageSize,
        long totalItems,
        int totalPages) {
}
```

- Proste listy repozytoriów: Spring Data `Pageable` + mapowanie `Page<Encja>` →
  `PageResponse<Dto>` w serwisie (nie zwracaj surowego `Page` z internals Springa w API).
- Wyszukiwanie assetów (kryteria złożone) idzie POST-em z kryteriami i paginacją w body —
  wzorzec `POST /api/v1/assets/search`; parametry paginacji tak samo walidowane.
- Sortowanie jako jawna, biała lista pól — nie przekazuj surowego stringa sortowania do JPA/ES.

---

## Anty-wzorce API

| Anty-wzorzec | Co zamiast |
|--------------|------------|
| Logika domenowa / try-catch w kontrolerze | Serwis + wyjątki domenowe + globalny handler |
| Własny format JSON błędu w jednym serwisie | Wspólny `ErrorDto` |
| Zmiana semantyki istniejącego endpointu | Nowa ścieżka `/api/v2/...` |
| Encja JPA w `@RequestBody`/response | DTO + mapper |
| `RestTemplate` bez timeoutów / `new RestTemplate()` w serwisie | `RestTemplateConfig` + properties |
| Mutowalne DTO z setterami | Rekord lub `@Value @Builder @Jacksonized` |
| Walidacja semantyczna w adnotacjach DTO | Technika na DTO, semantyka w serwisie |
| `Page<Encja>` bezpośrednio w odpowiedzi | `PageResponse<Dto>` |
| Angielskie opisy w `@Operation`/`@ApiResponse` | Opisy po polsku (czyta je człowiek) |
