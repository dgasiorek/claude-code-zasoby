# Wzorce Komponentów Vue 3.5

Wzorce SFC dla projektów CN. Wszystkie przykłady odzwierciedlają realne konwencje z cn-mediaconnector-ui.

## Anatomia SFC

Kolejność bloków: `<script setup>` → `<template>` → (opcjonalnie) `<style>`. Zawsze `lang="ts"`.

```vue
<script setup lang="ts">
import { computed } from 'vue';
import { twMerge } from 'tailwind-merge';

type Props = {
	label: string;
	disabled?: boolean;
};

const props = withDefaults(defineProps<Props>(), {
	disabled: false,
});

const emit = defineEmits<{
	select: [id: number];
}>();
</script>

<template>
	<button
		:class="['CategoryChip', 'rounded-sm px-2 py-1 bg-brand-lighten-1 text-primary']"
		:disabled="props.disabled"
		type="button"
		@click="emit('select', 1)"
	>
		{{ props.label }}
	</button>
</template>
```

Konwencje:
- W template odwołuj się do propsów przez `props.x` (jednoznaczność wobec lokalnych refów).
- Pierwsza klasa CSS = nazwa komponentu (`'CategoryChip'`) — ułatwia debug w DevTools i selektory w testach.
- Zdarzenia natywne przez `@click`, modyfikatory zamiast ręcznego `preventDefault` (`@submit.prevent`).

**Zakazane style**: Options API (`export default { data() ... }`), `defineComponent` z obiektem opcji,
mixiny, `this`. Jeśli widzisz je w diffie — to regresja.

---

## Struktura Katalogowa i Barrel

Każdy komponent mieszka we własnym katalogu z barrel `index.ts`:

```
src/components/
  BaseTextField/
    BaseTextField.vue
    index.ts            # export { default as BaseTextField } from './BaseTextField.vue';
  AppMessenger/
    AppMessenger.vue    # kontener
    AppMessengerItem.vue # pod-komponent prywatny (bez eksportu w barrelu, jeśli nieużywany na zewnątrz)
    store.ts            # lekki store lokalny feature'u
    types.ts
    index.ts
```

```ts
// src/components/AppMessenger/index.ts — barrel eksportuje też typy i store feature'u
export { default as AppMessenger } from './AppMessenger.vue';
export type { AppMessengerItemData } from './types';
export { useAppMessengerStore } from './store';
```

Import zawsze przez barrel i alias:

```ts
import { BaseTextField } from '@/components/BaseTextField';
import { useAppMessengerStore } from '@/components/AppMessenger';
```

Zasady:
- Prefiks `Base*` dla prymitywów UI wielokrotnego użytku (BaseButton, BaseModal, BaseTable,
  BaseSelect, BaseSwitch, BasePreloader, BaseValidationError...). Komponenty feature'owe bez prefiksu
  (LoginForm, HeaderPanel).
- Pliki pomocnicze feature'u (typy, store, composable użyty tylko tu) kolokowane w katalogu komponentu —
  np. `DaletContent/useAssets.ts`. Do `src/composables/` trafia dopiero to, co współdzielone.
- Nazwy komponentów i katalogów: PascalCase (konwencja frameworka — wyjątek od kebab-case).

---

## Typowane Props i Emits

```vue
<script setup lang="ts">
type Props = {
	name: string;
	type?: 'text' | 'number' | 'email' | 'password' | 'search' | 'tel' | 'url';
	validators?: ((value: string) => string | null)[];
	variant?: 'primary' | 'secondary' | 'success' | 'danger' | 'warning' | 'info';
	size?: 'small' | 'medium' | 'large';
	disabled?: boolean;
};

const props = withDefaults(defineProps<Props>(), {
	type: 'text',
	validators: undefined,
	variant: 'primary',
	size: 'medium',
	disabled: false,
});

const emit = defineEmits<{
	'click:icon': [];
	change: [value: string];
}>();
</script>
```

Zasady:
- Typ `Props` jako lokalny alias typu (nie interface eksportowany "na zapas").
- Warianty jako unie literałów, nie `string` — typo w miejscu użycia = błąd kompilacji.
- `withDefaults` zamiast defaultów w runtime; propsy opcjonalne bez sensownego defaultu → `undefined`.
- Emity nazywaj w kebab-case lub `czasownik:cel` (`click:icon`); payload zawsze typowany krotką.

## defineModel dla v-model

Vue 3.5: `defineModel` zamiast ręcznego `modelValue` + `update:modelValue`:

```vue
<script setup lang="ts">
const fieldValue = defineModel<string>({ default: '' });

function clear() {
	fieldValue.value = '';
}
</script>

<template>
	<input :value="fieldValue" @input="fieldValue = ($event.target as HTMLInputElement).value" />
</template>
```

Użycie: `<BaseTextField v-model="userCredentials.username" />`.

---

## defineExpose — wzorzec validate() w polach formularzy

Pola formularzy wystawiają metodę `validate()` — rodzic waliduje wszystkie pola przed submitem
(pełny opis: [forms-validation.md](forms-validation.md)).

```vue
<!-- BaseTextField.vue (fragment) -->
<script setup lang="ts">
import { useValidation } from '@/composables/useValidation';

const fieldValue = defineModel<string>({ default: '' });
const props = defineProps<{ validators?: ((value: string) => string | null)[] }>();

const { firstValidationError, validationErrors, validate } = useValidation(
	fieldValue,
	props.validators,
);

defineExpose({ validate });
</script>
```

```vue
<!-- Rodzic: dostęp przez useTemplateRef -->
<script setup lang="ts">
import { useTemplateRef } from 'vue';

const serverUrlField = useTemplateRef('server-url');

function handleSubmit() {
	const isValid = serverUrlField.value?.validate();
	if (!isValid) return;
	// ...
}
</script>

<template>
	<BaseTextField ref="server-url" v-model="serverUrl" name="server-url" />
</template>
```

Zasady:
- `defineExpose` wystawia MINIMALNY kontrakt (zwykle tylko `validate`); nie eksponuj wewnętrznych refów.
- `useTemplateRef('name')` (Vue 3.5) zamiast `ref<InstanceType<...>>()` — czytelniejsze i typowane.
- Wywołania metod expose zawsze z optional chaining (`field.value?.validate()`) — ref może być null
  przed montowaniem lub pod `v-if`.

---

## Przekazywanie Klas z Zewnątrz: attrs + twMerge

Prymitywy `Base*` przyjmują klasy z zewnątrz i merge'ują je z własnymi przez `tailwind-merge`
(ostatnia klasa wygrywa konflikt, np. `w-full` vs `w-[20rem]`):

```vue
<script setup lang="ts">
import { useAttrs } from 'vue';
import { twMerge } from 'tailwind-merge';

defineOptions({
	inheritAttrs: false,
});

const attrs = useAttrs();

const emit = defineEmits<{
	submit: [];
}>();
</script>

<template>
	<form
		:class="[
			'BaseForm',
			twMerge(
				'relative flex flex-col justify-center items-center gap-6 w-full',
				attrs?.class as string,
			),
		]"
		@submit.prevent="emit('submit')"
	>
		<slot />
	</form>
</template>
```

Zasady:
- `defineOptions({ inheritAttrs: false })` gdy ręcznie rozmieszczasz `attrs` — inaczej klasa
  zaaplikuje się podwójnie.
- Warianty/rozmiary jako słowniki klas w skrypcie (patrz BaseTextField): `variants[props.variant]`,
  `sizes[props.size]` — nie sklejanie stringów w template.

---

## Sloty

```vue
<!-- BaseModal.vue (szkic) -->
<template>
	<dialog class="BaseModal bg-brand rounded-md shadow-lg">
		<header v-if="$slots.header" class="px-4 py-2 border-b border-brand-lighten-1">
			<slot name="header" />
		</header>
		<div class="p-4">
			<slot />
		</div>
		<footer v-if="$slots.footer" class="px-4 py-2 flex justify-end gap-2">
			<slot name="footer" />
		</footer>
	</dialog>
</template>
```

Zasady:
- Slot domyślny dla głównej treści; sloty nazwane dla sekcji opcjonalnych, chowanych przez `v-if="$slots.x"`.
- Scoped sloty gdy rodzic potrzebuje danych dziecka (np. wiersz `BaseTable`):
  `<slot name="row" :item="item" />` → `<template #row="{ item }">`.
- Slot > prop typu "render function" — nie przekazuj VNode'ów propsami.

---

## provide/inject vs Pinia vs Lokalny Reactive Store

| Zasięg stanu | Narzędzie |
|--------------|-----------|
| Jeden komponent | `ref`/`computed` w `<script setup>` |
| Poddrzewo komponentów (np. BaseForm → pola) | `provide`/`inject` z typowanym `InjectionKey` |
| Feature z własnym stanem współdzielonym poza drzewem (np. messenger) | lekki moduł `reactive()` + funkcja `useXStore()` |
| Stan globalny aplikacji | JEDEN store Pinia `src/store.ts` |

```ts
// provide/inject — typowany klucz
import type { InjectionKey, Ref } from 'vue';

export const formDisabledKey: InjectionKey<Ref<boolean>> = Symbol('formDisabled');
// rodzic: provide(formDisabledKey, isDisabled);
// dziecko: const isDisabled = inject(formDisabledKey, ref(false));
```

```ts
// Lekki store feature'u (wzorzec AppMessenger) — reactive + closure, bez Pinia
import { reactive } from 'vue';
import type { AppMessengerItemData } from './types';

const state = reactive({
	messages: new Map<number, Required<AppMessengerItemData>>(),
	lastKey: 0,
});

const actions = {
	addMessage(message: AppMessengerItemData) {
		state.lastKey += 1;
		state.messages.set(state.lastKey, /* ... */ message as Required<AppMessengerItemData>);
	},
	removeMessage(key: number) {
		state.messages.delete(key);
	},
};

export function useAppMessengerStore() {
	return { ...state, ...actions };
}
```

Globalny store Pinia — preferencje persystowane jako `Ref` z `usePersistedStorage`:

```ts
// src/store.ts
import { type Ref } from 'vue';
import { defineStore, acceptHMRUpdate } from 'pinia';
import { usePersistedStorage } from '@/composables/usePersistedStorage';

type State = {
	serverUrl: Ref<string>;
	assetsViewMode: 'table' | 'grid';
	isPreloaderVisible: boolean;
};

export const useStore = defineStore('store', {
	state: (): State => ({
		serverUrl: usePersistedStorage('server-url', ''),
		assetsViewMode: 'table',
		isPreloaderVisible: false,
	}),

	getters: {
		hasServerUrl: (state) => state.serverUrl.length > 0,
	},
});

if (import.meta.hot) {
	import.meta.hot.accept(acceptHMRUpdate(useStore, import.meta.hot));
}
```

W komponentach destrukturyzuj przez `storeToRefs` (zachowuje reaktywność):

```ts
import { storeToRefs } from 'pinia';
import { useStore } from '@/store';

const { serverUrl, assetsViewMode } = storeToRefs(useStore());
```

---

## Renderowanie Warunkowe zamiast Routera

Aplikacje CN (panele/pluginy) nie używają vue-router. Widoki przełącza stan:

```vue
<!-- App.vue (wzorzec auth-gate) -->
<script setup lang="ts">
import { useAuth } from '@/composables/useAuth';
import { LoginForm } from '@/components/LoginForm';
import { HeaderPanel } from '@/components/HeaderPanel';

const { isAuthenticated } = useAuth();
</script>

<template>
	<LoginForm v-if="!isAuthenticated" />
	<template v-else>
		<HeaderPanel />
		<main class="flex-1 overflow-auto"><!-- treść --></main>
	</template>
</template>
```

- `v-if` dla gałęzi rzadko przełączanych (mount/unmount), `v-show` dla często przełączanych (display).
- Ciężkie, rzadko używane widoki: `defineAsyncComponent(() => import('@/components/ExportModal'))`.

---

## Ikony: SvgIcon (sprite)

Ikony SVG kompilowane do sprite'a przez `unplugin-svg-component` z `src/assets/images/icons/`.
Globalny komponent `<SvgIcon>`; w projektach CN opakowany w `BaseIcon` z typem nazwy:

```vue
<script setup lang="ts">
import { BaseIcon, type SvgName } from '@/components/BaseIcon';

const props = defineProps<{ icon?: SvgName }>();
</script>

<template>
	<BaseIcon v-if="props.icon" :name="props.icon" />
</template>
```

- Nowa ikona = plik SVG w `src/assets/images/icons/` — typ `SvgName` aktualizuje się z dts pluginu,
  więc literówka w nazwie nie przejdzie type-checku.
- Nie wklejaj inline `<svg>` do komponentów i nie dodawaj bibliotek ikon.

---

## Anty-Patterny

| Anty-pattern | Poprawnie |
|--------------|-----------|
| `fetch()` w komponencie | metoda w `src/api.ts` + `useFetchWrapper` |
| `localStorage.setItem` w komponencie | `usePersistedStorage` w store/composable |
| Options API / mixiny | `<script setup>` + composables |
| `ref<InstanceType<typeof X>>()` dla template ref | `useTemplateRef('name')` |
| Emit `update:modelValue` ręcznie | `defineModel` |
| Klasy sklejane stringami w template | słowniki wariantów + `twMerge` |
| Nowy store Pinia per feature | jeden `src/store.ts`; feature → composable/lokalny reactive store |
| Logika biznesowa w `<template>`/komponencie | composable `use*.ts` |
| Prop-drilling przez 3+ poziomy | `provide/inject` z `InjectionKey` |
| Inline `<svg>` / biblioteka ikon | sprite `SvgIcon`/`BaseIcon` |
