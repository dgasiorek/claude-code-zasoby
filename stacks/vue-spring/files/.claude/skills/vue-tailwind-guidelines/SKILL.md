---
name: vue-tailwind-guidelines
description: Frontend Vue 3.5 + TypeScript 5.9 + Vite 7 + Pinia 3 + TailwindCSS v4 dla SPA CN. Komponenty SFC (script setup), composables-first, data fetching przez src/api.ts + useFetchWrapper, formularze (BaseForm + validators), testowanie (Vitest + @vue/test-utils), stylowanie CSS-first (@theme, tokeny, tailwind-merge). Używaj przy tworzeniu komponentów, composables, stylowaniu, data fetchingu, formularzach, testach, konfiguracji Vite.
paths:
  - "**/*.vue"
  - "**/*.css"
  - "src/**/*.ts"
  - "vite.config.*"
  - "vitest.config.*"
---

# Vue Tailwind Guidelines

## Cel

Przewodnik frontendowy dla projektów CN: Vite 7 + Vue 3.5 SPA (wzorzec kanoniczny: cn-mediaconnector-ui).
Stack: Vue 3.5 SFC + `<script setup lang="ts">`, TypeScript 5.9, Pinia 3, Tailwind CSS v4 (CSS-first),
`@vueuse/core`, Node >= 22.18. Bez routera (renderowanie warunkowe), bez axios, bez TanStack Query.

## Kiedy Używać Tego Skilla

- Tworzenie nowych komponentów Vue (SFC)
- Pisanie composables (`src/composables/use*.ts`)
- Data fetching przez `src/api.ts` + `useFetchWrapper`
- Formularze z `BaseForm` + `BaseTextField` + walidatorami
- Stylowanie z Tailwind v4 (tokeny z `variables.css`)
- Testowanie z Vitest + @vue/test-utils
- Stany loading/error/empty i komunikaty przez AppMessenger

---

## Zasady Twarde (nie negocjuj)

1. **Zawsze `<script setup lang="ts">`** — nigdy Options API, nigdy `defineComponent` z obiektem opcji.
   Kolejność bloków w SFC: `<script setup>` → `<template>` → (opcjonalnie) `<style>`.
2. **Cały REST przez `src/api.ts` + `useFetchWrapper`** — NIGDY surowy `fetch()`/`axios` w komponencie.
   Wrapper daje spójnie: auto `Authorization: Bearer`, czyszczenie tokenu przy 401, błędy do globalnego
   messengera (`AppMessenger`), abort poprzedniego żądania do tego samego endpointu.
3. **Composables-first** — logika wielokrotnego użytku w `src/composables/use*.ts`, nie w komponentach.
   Komponent = template + orkiestracja; logika biznesowa i efekty w composable.
4. **`usePersistedStorage(key, default)` zamiast surowego `localStorage`** — preferencje UI trafiają do
   store'a Pinia jako `Ref` z persystencją. Cache większych danych: `localforage`/IndexedDB.
5. **Jeden globalny store Pinia** — `src/store.ts` (`useStore`). Nie mnóż store'ów per feature;
   stan lokalny feature'u trzymaj w composable lub komponencie.
6. **Tokeny Tailwind zamiast wartości arbitralnych** — `bg-primary`, `text-error`, `shadow-md`
   z `src/assets/variables.css`; NIGDY `bg-[#3B82F6]`, `text-[#eee]` ani inline hexy.
7. **Prettier: TABY, szerokość 100**, pojedyncze cudzysłowy, średniki, trailing commas, LF.
   ESLint 9 flat config. Nie zmieniaj konfiguracji formatera, żeby "przeszło".
8. **Argumenty API jako `MaybeRefOrGetter` + `toValue()`** — funkcje w `api.ts` i composables przyjmują
   wartość, ref albo getter i rozwiązują je `toValue()` w miejscu użycia.
9. **Quality gate przed "gotowe"**: `npm run lint` (html-validate → `vue-tsc --build` → eslint --fix →
   prettier --write) + testy Vitest. Type-check musi być zielony.

---

## Quick Start Checklist

### Nowy Komponent
- [ ] Katalog `src/components/<Nazwa>/` + barrel `index.ts` (`export { default as Nazwa } from './Nazwa.vue'`)
- [ ] `<script setup lang="ts">` z typowanymi `defineProps` / `defineEmits`
- [ ] Prymityw UI? → prefiks `Base*` (BaseButton, BaseModal, BaseTextField...)
- [ ] Klasa główna = nazwa komponentu (`:class="['BaseTextField', ...]"`), merge klas z zewnątrz przez `twMerge`
- [ ] Import aliasem `@/` (`@/components/BaseButton`, `@/composables/useAuth`)
- [ ] Ikony przez `<SvgIcon>` / `BaseIcon` (sprite z `unplugin-svg-component`), nie inline SVG

### Data Fetching
- [ ] Nowy endpoint = nowa metoda w `src/api.ts` (cienka otoczka nad `useFetchWrapper<T>`)
- [ ] Typ odpowiedzi w `src/types.ts`, przekazany jako generyk (`useFetchWrapper<Category[]>`)
- [ ] W komponencie: `const { data, isFetching, error, execute } = api.getX(...)` + jawne `execute()`
- [ ] Stany w template: loading (`isFetching`) → error → empty → data
- [ ] Feedback użytkownika przez `useAppMessengerStore().addMessage({ variant, text })`

### Formularz
- [ ] `BaseForm` (`@submit` z `.prevent` w środku) + pola `BaseTextField`
- [ ] Walidatory z `src/utils/validators.ts` przekazane propsem `:validators="[validators.required]"`
- [ ] Pola wystawiają `validate()` przez `defineExpose`; rodzic woła przez `useTemplateRef`
- [ ] Submit blokowany dopóki walidacja nie przejdzie; przycisk z `:loading="isFetching"`

### Nowy Composable
- [ ] Plik `src/composables/useNazwa.ts`, nazwa funkcji `useNazwa`
- [ ] Wejścia elastyczne: `MaybeRefOrGetter<T>` + `toValue()`
- [ ] Cleanup: `onUnmounted`/`onBeforeUnmount` dla listenerów, timerów, obserwatorów
- [ ] Test w Vitest bez montowania komponentu (jeśli composable nie dotyka DOM)

---

## Import Aliasy

| Alias | Ścieżka | Przykład |
|-------|---------|----------|
| `@/` | `src/` | `import { api } from '@/api'` |
| `@/components` | `src/components` | `import { BaseButton } from '@/components/BaseButton'` |
| `@/composables` | `src/composables` | `import { useAuth } from '@/composables/useAuth'` |
| `@/utils` | `src/utils` | `import { validators } from '@/utils/validators'` |

Zdefiniowane w `vite.config.ts` (`resolve.alias`) i `tsconfig.json`.

---

## Organizacja Plików

```
src/
  main.ts               # createApp + createPinia + mount
  App.vue               # renderowanie warunkowe (auth-gate zamiast routera)
  store.ts              # JEDEN globalny store Pinia (useStore)
  api.ts                # WSZYSTKIE wywołania REST (otoczki nad useFetchWrapper)
  types.ts              # współdzielone typy domenowe
  constants.ts          # stałe aplikacji
  components/
    BaseButton/         # prymitywy Base* — katalog + barrel index.ts
      BaseButton.vue
      index.ts
    AppMessenger/       # globalny messenger (toasty) — lekki reactive store
    LoginForm/          # komponenty feature'owe — ta sama struktura katalogowa
  composables/
    useFetch.ts         # niskopoziomowy fetch (AbortController, timeout)
    useFetchWrapper.ts  # auth + messenger + baseUrl ze store'a
    usePersistedStorage.ts
    useValidation.ts
    use*.ts
  utils/
    validators.ts       # walidatory pól formularzy
    date.ts, array.ts, object.ts
  assets/
    styles.css          # @import 'tailwindcss' + warstwy bazowe
    variables.css       # @theme — tokeny kolorów/cieni
    images/icons/       # źródła sprite'a SVG
```

---

## Topic Guides

### Wzorce Komponentów
SFC z `<script setup lang="ts">`, typowane `defineProps`/`defineEmits`/`defineModel`, `defineExpose`
(wzorzec `validate()`), katalogi z barrel `index.ts`, prefiks `Base*`, sloty, `provide/inject` vs Pinia,
ikony `SvgIcon`.
**[Pełny przewodnik: resources/component-patterns.md](resources/component-patterns.md)**

---

### Composables
Konwencje `use*.ts`, `MaybeRefOrGetter` + `toValue()`, cleanup lifecycle'owy, AbortController
w `useFetch`, wzorce `useEventListener`/`useDebounce`, `@vueuse/core`, granica composable vs store Pinia.
**[Pełny przewodnik: resources/composables.md](resources/composables.md)**

---

### Formularze i Walidacja
`BaseForm` + `BaseTextField`, `useValidation`, `src/utils/validators.ts`, `defineExpose({ validate })`,
walidacja na granicy API, błędy przez AppMessenger, stany loading/error/empty.
**[Pełny przewodnik: resources/forms-validation.md](resources/forms-validation.md)**

---

### Testowanie
Vitest + @vue/test-utils (STANDARD startera dla nowego kodu): konfiguracja `vitest.config.ts`,
testy composables bez montowania, testy komponentów z `mount` + happy-dom, mockowanie `api.ts`
przez `vi.mock`, nazwy testów po polsku, AAA, `vue-tsc --build` w quality gate.
**[Pełny przewodnik: resources/testing.md](resources/testing.md)**

---

### Stylowanie z TailwindCSS v4
CSS-first (`@import 'tailwindcss'`, `@theme` w `variables.css`), tokeny z wariantami
lighten/darken (`color-mix`), `tailwind-merge` dla klas nadpisywalnych z zewnątrz,
`prettier-plugin-classnames`, responsywność, zakaz arbitralnych hexów.
**[Pełny przewodnik: resources/styling-guide.md](resources/styling-guide.md)**

---

## Wzorzec Referencyjny: przepływ danych

```ts
// src/api.ts — jedyne miejsce definiowania wywołań REST
import { type MaybeRefOrGetter, toValue } from 'vue';
import type { Category } from '@/types';
import { useFetchWrapper, type UseFetchWrapperOptions } from '@/composables/useFetchWrapper';

export const api = {
	getCategory(
		categoryId: MaybeRefOrGetter<number>,
		fetchOptions?: Omit<UseFetchWrapperOptions, 'url' | 'query'>,
	) {
		return useFetchWrapper<Category[]>({
			url: () => `/categories/${toValue(categoryId)}`,
			...fetchOptions,
		});
	},
};
```

```vue
<script setup lang="ts">
import { api } from '@/api';
import { useStore } from '@/store';
import { storeToRefs } from 'pinia';

const { currentCategoryId } = storeToRefs(useStore());
// url jest getterem — refetch reaguje na zmianę categoryId
const { data, isFetching, error, execute } = api.getCategory(currentCategoryId);
await execute();
</script>

<template>
	<BasePreloader v-if="isFetching" />
	<p v-else-if="error" class="text-error">{{ error.message }}</p>
	<p v-else-if="!data?.length" class="text-primary-darken-2">Brak kategorii</p>
	<CategoryList v-else :categories="data" />
</template>
```

Zasada warstw: komponent → `api.ts` → `useFetchWrapper` → `useFetch`. Komponent nigdy nie zna URL-i,
nagłówków ani tokenów.

---

## Główne Zasady

1. **`<script setup lang="ts">`** — jedyny dopuszczalny styl komponentu
2. **`api.ts` + `useFetchWrapper`** — zero fetch/axios w komponentach i composables feature'owych
3. **Composables-first** — logika w `use*.ts`, komponent tylko orkiestruje
4. **Jeden store Pinia** (`src/store.ts`) + `usePersistedStorage` na preferencje
5. **Tailwind v4 CSS-first** — tokeny z `@theme`, zero arbitralnych hexów
6. **`tailwind-merge`** przy klasach przekazywanych z zewnątrz (`attrs.class`)
7. **TypeScript strict** — typowane props/emits/generyki, zero `any`
8. **AppMessenger** dla komunikatów użytkownika — nie `alert()`, nie `console.log`
9. **Vitest + @vue/test-utils** dla każdego nowego composable/komponentu z logiką
10. **`npm run lint` + `vue-tsc --build`** zielone przed deklaracją "gotowe"

---

## Navigation Guide

| Potrzebujesz... | Przeczytaj |
|-----------------|------------|
| Stworzyć komponent, sloty, expose | [component-patterns.md](resources/component-patterns.md) |
| Napisać composable, cleanup, vueuse | [composables.md](resources/composables.md) |
| Formularz, walidacja, błędy API | [forms-validation.md](resources/forms-validation.md) |
| Testy (Vitest + @vue/test-utils) | [testing.md](resources/testing.md) |
| Stylowanie, tokeny, tailwind-merge | [styling-guide.md](resources/styling-guide.md) |

---

## Powiązane Skills

- **ux-ui-guidelines**: UX, dostępność (WCAG 2.2), responsywność, animacje, interface polish
