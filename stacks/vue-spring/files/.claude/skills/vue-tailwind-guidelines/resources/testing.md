# Testowanie: Vitest + @vue/test-utils

STANDARD startera dla nowego kodu frontendowego CN. Projekty CN UI historycznie nie miały testów —
ta wytyczna definiuje obowiązkowy setup i wzorce dla KAŻDEGO nowego composable/komponentu z logiką.
Nie ma zgody na "dopiszemy testy później".

## Stack Testowy

| Warstwa | Narzędzie |
|---------|-----------|
| Runner + asercje + mocki | Vitest (ta sama tranformacja Vite co build) |
| Montowanie komponentów | @vue/test-utils (`mount`, `shallowMount`) |
| Środowisko DOM | happy-dom (szybsze) lub jsdom |
| Store w testach | `@pinia/testing` (`createTestingPinia`) |
| Type-check | `vue-tsc --build` (osobny krok quality gate — Vitest NIE type-checkuje) |

Instalacja (dev): `vitest`, `@vue/test-utils`, `happy-dom`, `@pinia/testing`, `@vitest/coverage-v8`.

## Konfiguracja

```ts
// vitest.config.ts — merge z vite.config.ts, żeby aliasy i pluginy były spójne
import { fileURLToPath } from 'node:url';
import { mergeConfig, defineConfig, configDefaults } from 'vitest/config';
import viteConfig from './vite.config';

export default mergeConfig(
	viteConfig,
	defineConfig({
		test: {
			environment: 'happy-dom',
			exclude: [...configDefaults.exclude, 'e2e/**'],
			root: fileURLToPath(new URL('./', import.meta.url)),
			restoreMocks: true,
		},
	}),
);
```

```jsonc
// package.json — skrypty
{
	"test": "vitest run",
	"test:watch": "vitest",
	"test:coverage": "vitest run --coverage"
}
```

Zasady:
- `mergeConfig` z `vite.config.ts` — NIE duplikuj aliasu `@/` ręcznie; sprite `SvgIcon` i inne pluginy
  działają wtedy także w testach.
- Kolokacja: `Component.spec.ts` obok `Component.vue`, `useX.spec.ts` obok `useX.ts` (nie osobne drzewo).
- `restoreMocks: true` — mocki nie przeciekają między testami.
- Quality gate: `vue-tsc --build` → `vitest run` → eslint/prettier. Czerwony type-check blokuje tak samo
  jak czerwony test.

---

## Konwencje Nazewnictwa i Struktury

- Nazwy testów PO POLSKU, opisują zachowanie: `it('pokazuje komunikat błędu przy 401')`,
  nie `it('works')` ani `it('should call handler')`.
- `describe` = nazwa jednostki (`describe('useValidation', ...)`), `it` = zachowanie.
- Struktura AAA (Arrange-Act-Assert) w każdym teście — rozdzielona pustymi liniami, bez komentarzy-nagłówków.
- Minimum 1 asercja na test; nowa funkcja = min. 1 test happy path + 1 test error case.
- ZAKAZ osłabiania asercji: `toBe(konkret)` nie zamienia się w `toBeDefined()`/`toBeTruthy()`, żeby test
  przeszedł. Failing test = naprawa implementacji, nie testu.
- Testuj zachowanie (co widzi użytkownik/wywołujący), nie implementację (nazwy wewnętrznych refów).

---

## Testy Composables (bez montowania)

Composable bez lifecycle'u i DOM testuj jak zwykłą funkcję:

```ts
// src/composables/useValidation.spec.ts
import { describe, it, expect } from 'vitest';
import { ref, nextTick } from 'vue';
import { useValidation } from './useValidation';
import { validators } from '@/utils/validators';

describe('useValidation', () => {
	it('zwraca true i brak błędów dla poprawnej wartości', () => {
		const fieldValue = ref('https://example.com');

		const { validate, validationErrors } = useValidation(fieldValue, [validators.url]);

		expect(validate()).toBe(true);
		expect(validationErrors.value).toEqual([]);
	});

	it('zbiera komunikaty wszystkich niespełnionych walidatorów', () => {
		const fieldValue = ref('');

		const { validate, firstValidationError } = useValidation(fieldValue, [
			validators.required,
			validators.minLength(3),
		]);

		expect(validate()).toBe(false);
		expect(firstValidationError.value).toBe('This field is required');
	});

	it('przelicza błędy po zmianie wartości pola', async () => {
		const fieldValue = ref('');
		const { validate, validationErrors } = useValidation(fieldValue, [validators.required]);
		validate();

		fieldValue.value = 'abc';
		await nextTick();

		expect(validationErrors.value).toEqual([]);
	});
});
```

Composable z lifecycle'em (`onUnmounted` itd.) potrzebuje instancji komponentu — użyj helpera:

```ts
// src/test/withSetup.ts
import { createApp, type App } from 'vue';

export function withSetup<T>(composable: () => T): [T, App] {
	let result!: T;
	const app = createApp({
		setup() {
			result = composable();
			return () => null;
		},
	});
	app.mount(document.createElement('div'));
	return [result, app];
}
```

```ts
import { vi, describe, it, expect } from 'vitest';
import { withSetup } from '@/test/withSetup';
import { useDebounce } from './useDebounce';

describe('useDebounce', () => {
	it('czyści timer przy odmontowaniu komponentu', () => {
		vi.useFakeTimers();
		const callback = vi.fn();
		const [debounced, app] = withSetup(() => useDebounce(callback, 100));

		debounced();
		app.unmount();
		vi.runAllTimers();

		expect(callback).not.toHaveBeenCalled();
		vi.useRealTimers();
	});
});
```

Fake timers (`vi.useFakeTimers`) dla debounce/timeout — nigdy realne `setTimeout` + czekanie.

---

## Testy Komponentów (mount)

```ts
// src/components/BaseTextField/BaseTextField.spec.ts
import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import { BaseTextField } from '.';
import { validators } from '@/utils/validators';

describe('BaseTextField', () => {
	it('aktualizuje v-model po wpisaniu tekstu', async () => {
		const wrapper = mount(BaseTextField, {
			props: {
				name: 'server-url',
				modelValue: '',
				'onUpdate:modelValue': (value: string) => wrapper.setProps({ modelValue: value }),
			},
		});

		await wrapper.find('input').setValue('https://example.com');

		expect(wrapper.props('modelValue')).toBe('https://example.com');
	});

	it('pokazuje komunikat błędu po walidacji pustego pola wymaganego', async () => {
		const wrapper = mount(BaseTextField, {
			props: { name: 'user-name', modelValue: '', validators: [validators.required] },
		});

		await wrapper.find('input').trigger('blur');

		expect(wrapper.text()).toContain('This field is required');
	});

	it('wystawia validate() zwracające false dla niepoprawnej wartości', () => {
		const wrapper = mount(BaseTextField, {
			props: { name: 'user-name', modelValue: '', validators: [validators.required] },
		});

		expect(wrapper.vm.validate()).toBe(false);
	});
});
```

Zasady:
- Interakcje przez `trigger`/`setValue` + `await` — asercje na WYNIKU widocznym w DOM
  (`wrapper.text()`, `find(...)`, emitted events), nie na wewnętrznym stanie.
- Emity: `expect(wrapper.emitted('select')).toEqual([[1]])`.
- `mount` domyślnie; `shallowMount`/`stubs` tylko gdy dziecko jest ciężkie (np. odpala fetch w setup).
- Globalne komponenty z pluginów (np. `SvgIcon`) — jeśli config testu nie ładuje pluginu, stubuj:
  `global: { stubs: { SvgIcon: true } }`.

### Komponenty używające Pinia

```ts
import { describe, it, expect } from 'vitest';
import { mount } from '@vue/test-utils';
import { createTestingPinia } from '@pinia/testing';
import HeaderPanel from './HeaderPanel.vue';

describe('HeaderPanel', () => {
	it('pokazuje adres serwera ze store', () => {
		const wrapper = mount(HeaderPanel, {
			global: {
				plugins: [
					createTestingPinia({
						initialState: { store: { serverUrl: 'https://dalet.example.com' } },
						stubActions: false,
					}),
				],
			},
		});

		expect(wrapper.text()).toContain('dalet.example.com');
	});
});
```

---

## Mockowanie api.ts (vi.mock)

Mockuj granicę `@/api` — NIGDY globalnego `fetch` w testach komponentów (fetch to detal
implementacyjny `useFetch`, testowany osobno):

```ts
import { vi, describe, it, expect, beforeEach } from 'vitest';
import { ref } from 'vue';
import { mount, flushPromises } from '@vue/test-utils';
import { createTestingPinia } from '@pinia/testing';
import { api } from '@/api';
import LoginForm from './LoginForm.vue';

vi.mock('@/api', () => ({
	api: {
		login: vi.fn(),
	},
}));

function mockLoginResponse(data: string | null) {
	vi.mocked(api.login).mockReturnValue({
		data: ref(data),
		error: ref(null),
		isFetching: ref(false),
		execute: vi.fn().mockResolvedValue(undefined),
	} as unknown as ReturnType<typeof api.login>);
}

describe('LoginForm', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('nie wysyła żądania, gdy pola nie przechodzą walidacji', async () => {
		mockLoginResponse(null);
		const wrapper = mount(LoginForm, {
			global: { plugins: [createTestingPinia({ stubActions: false })] },
		});

		await wrapper.find('form').trigger('submit');
		await flushPromises();

		const { execute } = vi.mocked(api.login).mock.results[0].value;
		expect(execute).not.toHaveBeenCalled();
	});
});
```

Zasady:
- `vi.mock('@/api', ...)` na poziomie modułu; kształt mocka odwzorowuje kontrakt `UseFetchWrapperResponse`
  (refy `data/error/isFetching` + `execute`).
- `flushPromises()` po akcjach asynchronicznych, zanim asertujesz DOM.
- Mockuj TYLKO granice zewnętrzne (`@/api`, `window.mcapi`, localforage). Nie mockuj testowanej jednostki
  ani composables czysto obliczeniowych.
- Sam `useFetch` testuj osobno z podmienionym `fetch` (`vi.stubGlobal('fetch', vi.fn())`) — to jedyne
  miejsce, gdzie mock fetcha jest legalny.

---

## Co Testować (priorytety)

1. **Utils i walidatory** (`src/utils/*`) — czyste funkcje, pełne pokrycie przypadków brzegowych.
2. **Composables z logiką** (`useValidation`, `usePersistedStorage`, `useDebounce`...) — happy path,
   error case, cleanup.
3. **Komponenty z zachowaniem** (formularze, pola, tabele z sortowaniem) — interakcja → widoczny efekt.
4. **Orkiestracja feature'u** (composable feature'owy z zamockowanym `@/api`).

Nie testuj: statycznych template'ów bez logiki, stylów Tailwind, typów (od tego jest `vue-tsc`).

## Quality Gate

Przed deklaracją "gotowe" (kolejność):

```bash
npm run type-check   # vue-tsc --build — zero błędów
npm run test         # vitest run — zero faili
npm run lint         # html-validate + eslint + prettier
```

- Nowy plik z logiką bez pliku `.spec.ts` = niekompletny PR.
- Zakazy z reguł repo obowiązują w pełni: nie modyfikuj istniejących testów, żeby przeszły; nie osłabiaj
  asercji; nie mockuj testowanej jednostki; testy pisz wertykalnie (test → implementacja → następny test).
