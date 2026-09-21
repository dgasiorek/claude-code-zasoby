# Logowanie backendowe — SLF4J + logback (wzorce CN)

## Konfiguracja

Każdy serwis ma `src/main/resources/logback-spring.xml`, który **includuje współdzielony
fragment maskujący** z biblioteki `com.cn.fuse.common:consul` — to on odpowiada za maskowanie
sekretów (`app.logging.masking.*`). Nie pisz własnego appendera od zera; rozszerzaj fragment.

Poziomy (konwencja CN):

```yaml
logging:
  level:
    root: INFO
    com.cn: DEBUG
```

## Wzorce

### Logger przez Lombok

```java
@Slf4j
@Service
public class AssetService {

    public Asset findById(String id) {
        log.debug("Pobieram asset id={}", id);
        ...
    }
}
```

- Zawsze placeholdery `{}` — nigdy konkatenacja stringów (koszt liczony nawet gdy poziom wyłączony).
- Wyjątek przekazuj jako OSTATNI argument (pełny stacktrace): `log.error("Blad pobierania assetu id={}", id, e);`

### Co logować na jakim poziomie

| Poziom | Kiedy | Przykład |
|--------|-------|----------|
| ERROR | operacja nieodwracalnie padła; wymaga uwagi | nieudany zapis, wyczerpane retry, 5xx z zależności |
| WARN | zdarzenie nietypowe, obsłużone degradacją | fallback na cache, retry, brak opcjonalnej konfiguracji |
| INFO | kamienie milowe cyklu życia | start serwisu, załadowana konfiguracja, wykonana migracja |
| DEBUG | przebieg logiki `com.cn` | wejścia/wyjścia metod serwisowych, decyzje routingu |

### MDC / correlation id

Przy wywołaniach między serwisami propaguj identyfikator korelacji i wkładaj go do MDC,
żeby dało się skleić przebieg jednego żądania w logach kilku serwisów:

```java
MDC.put("correlationId", correlationId);
try {
    ...
} finally {
    MDC.remove("correlationId");
}
```

W interceptorze RestTemplate przekazuj go dalej nagłówkiem (np. `X-Correlation-Id`).

## Anty-wzorce (finding na review)

| Anty-wzorzec | Poprawka |
|--------------|----------|
| `System.out.println(...)` / `System.err` | logger SLF4J z poziomem |
| `e.printStackTrace()` | `log.error("kontekst", e)` albo rzuć wyjątek domenowy |
| pusty `catch {}` | zaloguj + rzuć/obsłuż; połknięty wyjątek to defekt |
| logowanie sekretu/tokenu/hasła | ZAKAZ — pilnuje checkstyle **DEV-502** (regexp guard na `log.*` z podejrzanymi frazami) i maskowanie logback; nie obchodź ich |
| logowanie całego obiektu żądania/encji | loguj identyfikatory i pola istotne dla diagnozy |
| `log.info` w pętli po rekordach | DEBUG albo jedna sumaryczna linia po pętli |

Guard DEV-502 działa też na testach (`includeTestSourceDirectory=true`) i failuje `mvn verify`.
Wyjątkowe, uzasadnione tłumienie: `@SuppressWarnings("checkstyle:RegexpSinglelineJava")` na klasie —
wymaga uzasadnienia w opisie zmiany.

## Wyjątki a logowanie — nie dubluj

Wyjątek domenowy rzucony z serwisu loguje CENTRALNIE `@RestControllerAdvice` przy mapowaniu
na odpowiedź HTTP. Nie loguj tego samego błędu na każdym poziomie stosu (log-and-rethrow to anty-wzorzec):
loguj tam, gdzie błąd jest OBSŁUGIWANY, albo tam, gdzie dokładasz kontekst niedostępny wyżej.
