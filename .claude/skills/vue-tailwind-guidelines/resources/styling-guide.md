# Stylowanie — Tailwind CSS v4 (CSS-first) we Vue

## Setup CSS-first (bez tailwind.config.js)

Tailwind v4 konfiguruje się w CSS, nie w JS. Wejście stylów (`src/assets/styles.css`):

```css
@import 'tailwindcss';
@import './variables.css';

@theme {
	--color-primary: var(--cn-color-primary);
	--color-surface: var(--cn-color-surface);
	--radius-panel: 0.5rem;
}
```

Tokeny projektowe żyją w `src/assets/variables.css` — Tailwind mapuje je w bloku `@theme`
na klasy (`bg-primary`, `rounded-panel`). Plugin `@tailwindcss/vite` w `vite.config.ts` —
bez PostCSS-owej konfiguracji.

## Reguły twarde

1. **Tokeny zamiast wartości arbitralnych.** `bg-primary`, nie `bg-[#3B82F6]`;
   `gap-2`, nie `gap-[7px]`. Wartość arbitralna wymaga uzasadnienia (np. wymiar z mockupu,
   którego nie ma w skali) — a jeśli powtarza się 2+ razy, zamień w token w `@theme`.
2. **Klasy w template, nie w `<style>`.** Sekcji `<style scoped>` używaj wyjątkowo:
   animacje keyframes, selektory stanów niedostępne utility-first, style dla treści
   renderowanej dynamicznie.
3. **Klasy warunkowe przez `tailwind-merge`.** Przy łączeniu klas z propsów z klasami
   bazowymi konflikt rozstrzyga `twMerge` — nie klej stringów ręcznie:

```vue
<script setup lang="ts">
import { twMerge } from 'tailwind-merge';

const props = defineProps<{ class?: string }>();
const klasy = computed(() =>
	twMerge('rounded-panel bg-surface px-4 py-2 text-sm', props.class),
);
</script>

<template>
	<div :class="klasy"><slot /></div>
</template>
```

4. **Kolejność klas porządkuje `prettier-plugin-classnames`** — nie sortuj ręcznie,
   odpal `npm run lint` (prettier w łańcuchu).
5. **Prettier house-style:** taby, szerokość 100, pojedyncze cudzysłowy, średniki,
   trailing commas, LF. Nie zmieniaj `.prettierrc.json` pod swój kod.

## Responsywność

- Mobile-first: klasa bez prefiksu = najmniejszy ekran, potem `sm:` / `md:` / `lg:`.
- Panel Avid bywa wąski niezależnie od monitora — projektuj wg szerokości KONTENERA,
  nie urządzenia; przy komponentach wielokrotnego użytku preferuj container queries
  (`@container` + `@sm:`) zamiast media queries.
- Nie ukrywaj funkcji na wąskich szerokościach — zmieniaj układ (kolumna zamiast wiersza,
  menu zamiast paska).

## Stany i interakcje

- Każdy element interaktywny ma stany: `hover:`, `focus-visible:` (nigdy sam `focus:` bez
  widocznego wskaźnika), `disabled:` oraz — dla pól — stan błędu spójny z `BaseTextField`.
- Animacje: `transition` + `duration-150/200` dla mikrointerakcji; szanuj
  `motion-reduce:` (wyłącz dekoracyjne animacje).
- Z-index tylko z ustalonej skali projektu (token), nie `z-[9999]`.

## Ikony

Sprite SVG generuje `unplugin-svg-component` z `src/assets/images/icons/` — używaj
`<SvgIcon name="..." />`, nie inline `<svg>` kopiowanego z mockupu. Rozmiar/kolor ikon
klasami (`size-4 text-primary`), źródłowe SVG bez zaszytych fill.

## Checklist stylowania

- [ ] Zero hexów/px arbitralnych tam, gdzie istnieje token lub skala
- [ ] Klasy warunkowe przez `twMerge`
- [ ] `focus-visible:` na każdym elemencie interaktywnym
- [ ] Mobile-first, funkcje dostępne na każdej szerokości panelu
- [ ] `npm run lint` przechodzi (html-validate → vue-tsc → eslint → prettier)
