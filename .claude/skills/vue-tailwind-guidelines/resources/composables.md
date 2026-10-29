# Composables

Architektura composables-first: logika wielokrotnego użytku żyje w `src/composables/use*.ts`,
komponenty tylko ją orkiestrują. Wzorce z cn-mediaconnector-ui.

## Konwencje Podstawowe

- Plik: `src/composables/useNazwa.ts`; eksport nazwany `export function useNazwa(...)`.
- Composable używany tylko przez jeden feature → kolokuj w katalogu komponentu
  (np. `src/components/DaletContent/useAssets.ts`); do `src/composables/` awansuje przy drugim użyciu.
- Composable zwraca obiekt z refami/computed/funkcjami — NIE reactive z destrukturyzacją
  (destrukturyzacja `reactive` gubi reaktywność).
- Composable wywołuj synchronicznie w `<script setup>` (albo w innym composable) — nie w callbackach,
  nie po `await` — inaczej hooki lifecycle'owe (`onUnmounted` itd.) nie mają aktywnej instancji.
- Zero `any` w sygnaturach publicznych; generyki dla danych (`useFetch<T>`).

---

## MaybeRefOrGetter + toValue()

Wejścia composables i funkcji `api.ts` przyjmują wartość, `Ref` ALBO getter — rozwiązywane
`toValue()` dopiero w miejscu użycia. Dzięki temu wywołujący decyduje, czy argument ma być reaktywny:

```ts
import { computed, toValue, type MaybeRefOrGetter } from 'vue';

export function useAssetLabel(assetName: MaybeRefOrGetter<string>) {
	const label = computed(() => `Asset: ${toValue(assetName)}`);
	return { label };
}
```

```ts
// wszystkie trzy formy działają:
useAssetLabel('clip-01');               // statyczna wartość
useAssetLabel(assetNameRef);            // ref — label będzie się aktualizował
useAssetLabel(() => props.assetName);   // getter — reaktywność na props
```

Zasady:
- `toValue()` wywołuj wewnątrz `computed`/`watch`/funkcji wykonującej — nie raz na początku composable
  (to zamroziłoby wartość).
- W `api.ts` gettery przekazuj dalej jako gettery: `url: () => \`/categories/${toValue(categoryId)}\``
  — `useFetch` z `refetch: true` może wtedy reagować na zmianę.
- Typ opcji, które mogą być reaktywne: `MaybeRefOrGetter<HeadersInit | undefined>` itd.

---

## Cleanup — obowiązkowy

Każdy composable, który coś subskrybuje/startuje, MUSI po sobie sprzątać. Bez wyjątków.

### Listenery: wzorzec useEventListener

```ts
import { computed, onMounted, onBeforeUnmount, toValue, type MaybeRefOrGetter } from 'vue';

export function useEventListener(
	target: MaybeRefOrGetter<EventTarget | null | undefined>,
	eventName: string | string[],
	callback: (event: Event) => void,
	options?: MaybeRefOrGetter<boolean | AddEventListenerOptions | undefined>,
) {
	const element = computed(() => toValue(target));
	const eventArray = Array.isArray(eventName) ? eventName : [eventName];
	const wrappedCallback: EventListener = (event) => callback(event);

	const addListeners = () => {
		eventArray.forEach((event) => {
			element.value?.addEventListener(event, wrappedCallback, toValue(options));
		});
	};
	const removeListeners = () => {
		eventArray.forEach((event) => {
			element.value?.removeEventListener(event, wrappedCallback, toValue(options));
		});
	};

	onMounted(addListeners);
	onBeforeUnmount(removeListeners);
}
```

Target jako `MaybeRefOrGetter<HTMLElement | null>` współpracuje z `useTemplateRef` — element może
jeszcze nie istnieć w momencie wywołania composable.

### Timery: wzorzec useDebounce

```ts
import { onUnmounted } from 'vue';

export function useDebounce<A extends unknown[], R>(callback: (...args: A) => R, delay = 100) {
	let timeout: ReturnType<typeof setTimeout> | null = null;

	function clear() {
		if (timeout) clearTimeout(timeout);
	}

	function debouncedFunction(...args: A) {
		return new Promise<R>((resolve, reject) => {
			clear();
			timeout = setTimeout(() => {
				try {
					resolve(callback(...args));
				} catch (error) {
					reject(error);
				}
			}, delay);
		});
	}

	debouncedFunction.cancel = () => {
		clear();
		timeout = null;
	};

	onUnmounted(clear);

	return debouncedFunction;
}
```

Kluczowe: `onUnmounted(clear)` — timer nie może odpalić się po odmontowaniu komponentu.

### AbortController: wzorzec useFetch/useFetchWrapper

Niskopoziomowy `useFetch` trzyma `AbortController` per żądanie i abortuje POPRZEDNIE żądanie,
gdy startuje nowe do tego samego endpointu (ochrona przed race condition — stara odpowiedź nie
nadpisze nowszej):

```ts
let abortController: AbortController | null = null;

function abort(reason: string) {
	if (abortController && !abortController.signal.aborted) {
		abortController.abort();
		abortController = null;
	}
}

async function fetchData() {
	abort('Request aborted as another request to the same endpoint was initiated');
	abortController = new AbortController();
	const signal = timeout
		? AbortSignal.any([abortController.signal, AbortSignal.timeout(timeout)])
		: abortController.signal;
	// fetch(fetchUrl.value, { ..., signal });
}
```

Zasady wynikowe dla konsumentów:
- `AbortError`/`TimeoutError` NIE są pokazywane użytkownikowi (`useFetchWrapper` je filtruje) —
  to normalny przebieg, nie błąd.
- Operacje wzajemnie wykluczające się (np. ładowanie podglądu) — zablokuj następną do czasu
  zakończenia/abortu poprzedniej.
- Timeout przez `AbortSignal.any([controller.signal, AbortSignal.timeout(ms)])`, nie ręczny `setTimeout`.

---

## Persystencja: usePersistedStorage

Jedyny dopuszczalny sposób zapisu preferencji do localStorage:

```ts
import { watch, ref } from 'vue';

export function usePersistedStorage<T>(key: string, value: T, storage: Storage = localStorage) {
	const storedValue = storage.getItem(key);
	const data = ref(storedValue !== null ? (JSON.parse(storedValue) as T) : value);

	watch(
		data,
		(newValue) => {
			if (newValue === null || newValue === undefined) {
				storage.removeItem(key);
			} else {
				storage.setItem(key, JSON.stringify(newValue));
			}
		},
		{ immediate: true },
	);

	return data;
}
```

- Zwraca `Ref<T>` — trzymany bezpośrednio w stanie store'a Pinia (`serverUrl: usePersistedStorage('server-url', '')`).
- Klucze kebab-case, stabilne (zmiana klucza = utrata preferencji użytkownika).
- Większe dane (cache list/asetów) → NIE localStorage, tylko `localforage`/IndexedDB
  (wzorzec `useLocalForage`, instancje per domena: `categories`, `assets`).

---

## @vueuse/core

`@vueuse/core` jest w zależnościach — używaj go zamiast pisać własne utility, CHYBA że projekt ma już
własny odpowiednik (wtedy trzymaj się lokalnego — spójność > nowość). W cn-mediaconnector-ui lokalne są
m.in.: `useEventListener`, `useDebounce`, `useClickOutside`, `useFocusTrap`, `useScroll`.

Typowe sięgnięcia do vueuse: `useMediaQuery`, `useResizeObserver`, `useIntersectionObserver`,
`useDocumentVisibility`, `watchDebounced`.

```ts
import { useMediaQuery } from '@vueuse/core';

const isCompact = useMediaQuery('(max-width: 640px)');
```

Nie dodawaj nowych bibliotek utility (lodash itd.) — vueuse + `src/utils/*` wystarczą.

---

## Composable vs Store Pinia vs Moduł

Decyzja wg zasięgu i cyklu życia stanu:

| Pytanie | Odpowiedź | Narzędzie |
|---------|-----------|-----------|
| Stan per instancja komponentu? | tak | composable (stan tworzony w wywołaniu) |
| Stan współdzielony w całej aplikacji, przeżywa unmount? | tak | store Pinia (`src/store.ts`) |
| Stan globalny jednego feature'u (np. kolejka toastów)? | tak | lokalny moduł `reactive()` + `useXStore()` |
| Czysta funkcja bez reaktywności? | tak | `src/utils/*.ts` (nie composable!) |

Zasady CN:
- **Jeden globalny store Pinia** (`useStore` w `src/store.ts`). Nie twórz store'ów per widok —
  jeśli stan jest feature'owy, kolokuj lekki reactive store w katalogu feature'u (wzorzec AppMessenger).
- Stan modułowy (ref na poziomie modułu, poza funkcją) jest OK dla singletonów typu `useAuth`:

```ts
// useAuth — stan modułowy: jeden token dla całej aplikacji
import { ref, computed } from 'vue';

const authToken = ref<string | undefined>(undefined);
const isAuthenticated = computed(() => Boolean(authToken.value));

export function useAuth() {
	return { authToken, isAuthenticated };
}
```

  Uwaga: stan modułowy NIE nadaje się do SSR i utrudnia izolację w testach — dopuszczalny tylko dla
  autentycznych singletonów (auth, konfiguracja runtime). Domyślnie stan twórz wewnątrz funkcji composable.
- Funkcja bez `ref`/`computed`/`watch`/lifecycle NIE jest composable — to util, przenieś do `src/utils/`
  i nie nazywaj jej `useX`.

---

## Wzorzec Złożony: composable feature'owy na api.ts

Composable feature'owy skleja `api.ts`, store i cache — komponent dostaje gotowy interfejs:

```ts
// src/components/DaletContent/useAssets.ts (szkic wzorca)
import { computed, watch } from 'vue';
import { storeToRefs } from 'pinia';
import { useStore } from '@/store';
import { api } from '@/api';

export function useAssets() {
	const store = useStore();
	const { assetsSorting, currentCategoryId } = storeToRefs(store);

	const query = computed(() => ({
		categoryId: currentCategoryId.value,
		page: 0,
		size: 50,
		order: Object.values(assetsSorting.value)[0] ?? 'ASC',
	}));

	const { data, isFetching, error, execute } = api.getAssets(query);

	watch(query, () => execute());

	const assets = computed(() => data.value?.items ?? []);

	return { assets, isFetching, error, reload: execute };
}
```

Zasady:
- Composable NIE woła `fetch` — zawsze przez `api.ts`.
- Zwracaj nazwy domenowe (`assets`, `reload`), nie surowe (`data`, `execute`) — komponent czyta intencję.
- Refetch przez `watch` na `computed` query — jedno źródło prawdy dla parametrów żądania.

---

## Anty-Patterny

| Anty-pattern | Poprawnie |
|--------------|-----------|
| `toValue()` raz na początku composable | `toValue()` w każdym miejscu odczytu (computed/watch) |
| Listener/timer bez cleanupu | `onUnmounted`/`onBeforeUnmount` zawsze |
| `const { x } = reactive({...})` w zwrocie | zwracaj obiekt refów / `toRefs` |
| Composable wywołany w callbacku/po await | wywołanie synchronicznie w setup |
| `useX` bez reaktywności w środku | przenieś do `src/utils/` |
| Drugi store Pinia "bo wygodnie" | jeden `src/store.ts` + lokalne reactive story feature'ów |
| Własna kopia utility z vueuse | użyj `@vueuse/core` albo istniejącego lokalnego composable |
| Surowy `localStorage` | `usePersistedStorage` |
