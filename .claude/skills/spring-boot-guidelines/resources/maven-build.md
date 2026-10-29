# Maven — build multi-module i konwencje CN

Zasady pracy z Mavenem w monorepo mikroserwisów (wzorzec: cn-mediaconnector) i bibliotekach
współdzielonych (wzorzec: com.cn.fuse.common:consul).

## Struktura multi-module

```
cn-mediaconnector/
├── pom.xml                  ← rodzic (packaging: pom), <modules>, dependencyManagement
├── auth-service/pom.xml     ← moduł: własny literalny <version>
├── asset-service/pom.xml
├── config-service/pom.xml
└── ...
```

Rodzic trzyma:
- `<dependencyManagement>` — WSZYSTKIE wersje zależności,
- `<pluginManagement>` + wspólne pluginy (surefire, jacoco, checkstyle, flatten),
- wspólne zależności dziedziczone przez każdy moduł (`<dependencies>` rodzica).

## Reguły twarde

### 1. Wersje zależności tylko w rodzicu

```xml
<!-- pom.xml modułu — DOBRZE: bez <version> -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
```

```xml
<!-- ŹLE: wersja w module — konflikt z dependencyManagement rodzica -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
    <version>4.0.6</version>
</dependency>
```

Nowa zależność = wpis w `<dependencyManagement>` rodzica (z wersją) + wpis w pom module (bez wersji).

### 2. Każdy moduł ma własny literalny `<version>`

Pipeline release'u (version-first, `versions:set`) wymaga, żeby każdy serwis miał
swoją niezależną, literalną wersję w pom — NIE `${revision}` odziedziczone z rodzica.
Enforcer pilnuje, żeby wersja modułu ≠ wersja rodzica. **Nigdy nie bumpuj wersji ręcznie** —
robi to pipeline na podstawie hasła commita (`feature:` → minor, `fix:` → patch).

### 3. flatten-maven-plugin i `${revision}` — nie ruszać

Rodzic używa CI-friendly versions (`${revision}${changelist}`), a `flatten-maven-plugin`
(tryb `resolveCiFriendliesOnly`) spłaszcza pom przy deployu do Nexusa. Usunięcie/zmiana
tego pluginu psuje publikację artefaktów.

### 4. Bloki SECURITY-OVERRIDES

Tymczasowe piny wersji łatające CVE żyją w rodzicu między znacznikami:

```xml
<!-- SECURITY-OVERRIDES-BEGIN -->
<dependency>...</dependency>
<!-- SECURITY-OVERRIDES-END -->
```

Zasady: każdy pin ma udokumentowany powód (CVE) i plan usunięcia (upgrade frameworka,
który przynosi łatkę transitive). Nie dodawaj/nie usuwaj pinów bez przejścia procedury
projektu (`docs/security-dependency-overrides.md` + skrypt kontrolny, jeśli projekt je ma).

### 5. spring-boot-maven-plugin

Moduły serwisów budują fat-jar przez `repackage` z layered jars (szybsze obrazy Docker)
i `build-info` (metadane do actuatora). Konfiguracja w rodzicu — nie nadpisuj w module bez powodu.

## Komendy

```bash
mvn clean verify                          # cały monorepo: testy + JaCoCo + checkstyle
mvn clean package -pl asset-service -DskipTests   # jar jednego modułu
mvn test -pl asset-service -Dtest=AssetServiceTest#zwracaAssetPoId
mvn spring-boot:run -pl asset-service     # serwis lokalnie (albo z katalogu modułu)
mvn dependency:tree -pl asset-service     # analiza transitive
mvn versions:display-dependency-updates   # co jest do podbicia (tylko raport)
mvn -o test                               # offline — szybciej, gdy ~/.m2 rozgrzane
```

Brak roota `mvnw` w projektach CN — używaj systemowego `mvn` (chyba że moduł ma własny wrapper).

## Rejestry artefaktów

- Nexus: `https://registry.adscreen.net:8443/` (snapshots / releases / thirdParty)
- Credentials w `~/.m2/settings.xml` — sekcja `<servers>` NIGDY nie trafia do repo
- Docker registry: `registry.adscreen.net:9092`
- Upgrade biblioteki współdzielonej propaguje się do konsumentów przez manualny job
  `propagate` w pipeline biblioteki — nie edytuj wersji w pom konsumenta ręcznie

## Checklist zmiany w pom.xml

- [ ] Zależność w module bez `<version>`; wersja w `dependencyManagement` rodzica
- [ ] Nie zmieniasz `<version>` modułów (robi to pipeline)
- [ ] Nie dotykasz flatten-plugina ani `${revision}`
- [ ] Nie wchodzisz w bloki `SECURITY-OVERRIDES-*` bez procedury
- [ ] Po zmianie: `mvn -q compile` a potem pełny `mvn verify` (w tle — patrz reguły długich komend)
- [ ] Zmiana wspólna dla większości modułów → rodzic; zmiana jednego serwisu → pom modułu
