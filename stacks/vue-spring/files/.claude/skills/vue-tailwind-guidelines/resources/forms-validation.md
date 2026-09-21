# Formularze i Walidacja

Wzorzec formularzy CN: `BaseForm` + `BaseTextField` + walidatory z `src/utils/validators.ts` +
`useValidation` + `defineExpose({ validate })`. Bez bibliotek formularzowych (bez VeeValidate itp.).

## Architektura

```
BaseForm            # <form @submit.prevent> + layout + slot
  BaseTextField     # pole z v-model, walidatorami i defineExpose({ validate })
    useValidation   # composable: uruchamia walidatory, trzyma błędy
    BaseValidationError  # prezentacja pierwszego błędu pola
src/utils/validators.ts  # czyste funkcje walidujące (reużywalne)
```

Podział odpowiedzialności:
- **Walidator** = czysta funkcja `(value) => string | null` (null = OK). Zero reaktywności, zero DOM.
- **useValidation** = spina wartość pola z listą walidatorów, trzyma `validationErrors`, waliduje
  na `watch` (po pierwszej walidacji ręcznej) i na żądanie.
- **Pole** = wystawia `validate()` przez `defineExpose`, pokazuje pierwszy błąd.
- **Formularz-rodzic** = woła `validate()` wszystkich pól przed submitem; submit tylko gdy komplet OK.

---

## Walidatory: src/utils/validators.ts

```ts
export const validators = {
	required: (value: string | null | undefined) => {
		return value?.trim() === '' || value === null || value === undefined
			? 'This field is required'
			: null;
	},

	minLength: (min: number) => {
		return (value: string) => (value.length < min ? `Minimum length is ${min} characters` : null);
	},

	url: (value: string) => {
		const pattern = /^(http:\/\/|https:\/\/)/;
		return pattern.test(value) ? null : 'URL must start with http:// or https://';
	},
};
```

Zasady:
- Kontrakt: `null` = poprawne; string = komunikat błędu (gotowy do wyświetlenia).
- Walidatory parametryzowane jako fabryki (`minLength(3)` zwraca walidator).
- Nowe reguły dopisuj TUTAJ, nie inline w komponentach — reużycie i testowalność.
- Walidatory są czystymi funkcjami → idealne do testów jednostkowych bez montowania.

## useValidation

```ts
import { computed, ref, toValue, watch, type MaybeRefOrGetter } from 'vue';

type Validator = (value: string) => string | null;

export function useValidation(fieldValue: MaybeRefOrGetter<string>, validators?: Validator[]) {
	const validationErrors = ref<string[]>([]);
	const firstValidationError = computed(() => validationErrors.value[0] || '');

	function validate() {
		if (!validators || validators.length === 0) return true;
		validationErrors.value = [];
		for (const validator of validators) {
			const result = validator(toValue(fieldValue));
			if (result) validationErrors.value.push(result);
		}
		return validationErrors.value.length === 0;
	}

	if (validators && validators.length > 0) {
		watch(fieldValue, validate);
	}

	return { validationErrors, firstValidationError, validate };
}
```

Efekt UX: walidacja inline — po zmianie wartości błędy przeliczają się na bieżąco (watch),
a `validate()` wywołane z zewnątrz (blur, submit) wymusza pełną walidację.

---

## Pole: defineExpose({ validate })

```vue
<!-- BaseTextField.vue (istota wzorca) -->
<script setup lang="ts">
import { useValidation } from '@/composables/useValidation';
import { BaseValidationError } from '@/components/BaseValidationError';

type Props = {
	name: string;
	validators?: ((value: string) => string | null)[];
};

const props = defineProps<Props>();
const fieldValue = defineModel<string>({ default: '' });

const { firstValidationError, validationErrors, validate } = useValidation(
	fieldValue,
	props.validators,
);

defineExpose({ validate });
</script>

<template>
	<div
		:class="[
			'BaseTextField',
			'relative flex items-center w-full h-[2em] rounded-sm px-[0.5em]',
			validationErrors.length > 0 ? 'bg-error-lighten-5' : 'bg-primary',
		]"
	>
		<input :name="props.name" :value="fieldValue" @blur="validate" />
		<BaseValidationError v-if="firstValidationError" :message="firstValidationError" />
	</div>
</template>
```

- Stan błędu widoczny wizualnie (tło `bg-error-lighten-5`) ORAZ tekstowo (`BaseValidationError`).
- `@blur="validate"` — pierwsza walidacja przy opuszczeniu pola, nie przy każdym wciśnięciu klawisza.

## Formularz-rodzic: LoginForm (wzorzec kompletny)

```vue
<script setup lang="ts">
import { ref, useTemplateRef } from 'vue';
import { api } from '@/api';
import { useAuth } from '@/composables/useAuth';
import { validators } from '@/utils/validators';
import { BaseForm } from '@/components/BaseForm';
import { BaseTextField } from '@/components/BaseTextField';
import { BaseButton } from '@/components/BaseButton';

const userNameField = useTemplateRef('user-name');
const userPasswordField = useTemplateRef('user-password');
const userCredentials = ref({ username: '', password: '' });

const { authToken } = useAuth();
const { data, isFetching, execute } = api.login(userCredentials.value);

async function handleLogin() {
	const isLoginValid = userNameField.value?.validate();
	const isPasswordValid = userPasswordField.value?.validate();
	if (!isLoginValid || !isPasswordValid) return;

	await execute();

	if (data.value) {
		authToken.value = data.value;
	}
}
</script>

<template>
	<BaseForm class="w-[20rem]" @submit="handleLogin">
		<BaseTextField
			v-model="userCredentials.username"
			ref="user-name"
			name="user-name"
			placeholder="User Name"
			:validators="[validators.required]"
		/>
		<BaseTextField
			v-model="userCredentials.password"
			ref="user-password"
			name="user-password"
			type="password"
			placeholder="User Password"
			:validators="[validators.required]"
		/>
		<BaseButton type="submit" class="w-full" :loading="isFetching">Login</BaseButton>
	</BaseForm>
</template>
```

Zasady:
- Waliduj WSZYSTKIE pola przed submitem (nie short-circuit `a && b()` — każde pole ma pokazać swój błąd;
  dlatego najpierw trzy osobne wywołania, potem warunek).
- Wyniki `validate()` przez optional chaining — ref pola może być null.
- Przycisk submit z `:loading="isFetching"` — blokada podwójnego submitu.
- `BaseForm` emituje `submit` już po `.prevent` — rodzic nie dotyka `Event`.

---

## Walidacja na Granicy API

Walidacja frontendowa to UX, nie bezpieczeństwo — źródłem prawdy jest backend
(Jakarta Validation na DTO). Frontend obowiązkowo:

1. **Waliduje wejście użytkownika przed wysłaniem** (walidatory jak wyżej) — oszczędza rundę HTTP.
2. **Typuje kontrakt odpowiedzi** — generyk `useFetchWrapper<T>` + typ w `src/types.ts`.
   Zmiana kontraktu API = świadoma zmiana typu, nie cichy `any`.
3. **Obsługuje odrzucenie przez backend** — 4xx z `detail` w body jest komunikatem błędu
   (`useFetch` rzuca `Error(responseError?.detail || 'Request failed with status ...')`).
4. **Normalizuje dane wejściowe** — np. trim trailing slashy w URL serwera przed zapisem do store'a.

Nie duplikuj pełnych reguł biznesowych backendu na froncie — waliduj format i obecność,
reguły domenowe zostaw serwerowi i pokaż jego odpowiedź.

---

## Obsługa Błędów: AppMessenger

Błędy HTTP NIE są obsługiwane per komponent — `useFetchWrapper` kieruje je do globalnego messengera:

```ts
// wewnątrz useFetchWrapper (mechanizm — nie kopiuj do komponentów)
watch(fetchResponse.error, (newValue) => {
	if (!newValue) return;

	if (fetchResponse.response.value?.status === 401) {
		authToken.value = undefined; // wylogowanie — App.vue pokaże LoginForm
	}
	if (['AbortError', 'TimeoutError'].includes(newValue.name)) {
		return; // aborty to nie błędy użytkownika
	}
	useAppMessengerStore().addMessage({
		variant: 'error',
		text: newValue.message,
		persistent: persistentError,
	});
});
```

W komponentach używaj messengera tylko do komunikatów domenowych (sukces, ostrzeżenie):

```ts
import { useAppMessengerStore } from '@/components/AppMessenger';

useAppMessengerStore().addMessage({ variant: 'success', text: 'Export queued' });
```

Zasady:
- `variant: 'error'` jest domyślnie `persistent` (użytkownik musi zamknąć) — błędy nie znikają same.
- Nie pokazuj tego samego błędu dwa razy (wrapper już go pokazał — nie dokładaj catcha z addMessage).
- `console.log` nie jest kanałem błędów. `console.error` tylko dla stanów programistycznych
  (np. brak integracji hosta), nie dla błędów użytkownika.

---

## Stany Loading / Error / Empty

Każdy widok danych obsługuje 4 stany w tej kolejności:

```vue
<script setup lang="ts">
import { api } from '@/api';
import { BasePreloader } from '@/components/BasePreloader';

const { data, isFetching, error, execute } = api.getCategories();
await execute();
</script>

<template>
	<BasePreloader v-if="isFetching" />
	<p v-else-if="error" class="text-error px-4">{{ error.message }}</p>
	<p v-else-if="!data?.length" class="text-primary-darken-2 px-4">No categories yet</p>
	<CategoryTree v-else :categories="data" />
</template>
```

- Kolejność zawsze: loading → error → empty → data (`v-if`/`v-else-if` — dokładnie jeden stan naraz).
- Globalny preloader (`isPreloaderVisible` w store) tylko dla operacji blokujących całą aplikację;
  lokalne ładowanie = lokalny `BasePreloader`/skeleton.
- Empty state z akcją, jeśli użytkownik może ją wykonać ("No results — clear filters").
- Stan błędu w widoku pokazuj przy danych KRYTYCZNYCH dla widoku; błędy akcji pobocznych załatwia messenger.

---

## Anty-Patterny

| Anty-pattern | Poprawnie |
|--------------|-----------|
| Reguły walidacji inline w komponencie | `src/utils/validators.ts` |
| Biblioteka formularzy (VeeValidate itd.) | BaseForm + useValidation (wzorzec projektu) |
| `alert()` / własny toast per widok | `useAppMessengerStore().addMessage` |
| try/catch z addMessage wokół wywołania api | wrapper już raportuje — obsłuż tylko sukces |
| Submit bez walidacji wszystkich pól | trzy wywołania `validate()`, potem warunek |
| Krytyczny błąd tylko w messengerze, widok "pusty" | stan error w widoku + messenger |
| Frontend "ufa" odpowiedzi (`as any`) | typ kontraktu w `src/types.ts` + generyk |
