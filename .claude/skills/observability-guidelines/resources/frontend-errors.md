# Obsługa błędów frontendowych — useFetchWrapper + AppMessenger (wzorce CN)

## Zasada centralizacji

Cała komunikacja REST idzie przez `src/api.ts` → `useFetchWrapper`. To JEDYNE miejsce,
w którym obsługuje się błędy transportu i statusy HTTP. Komponent nie robi `try/catch`
wokół fetcha i nie interpretuje kodów odpowiedzi — dostaje dane albo stan błędu.

```
komponent → api.ts → useFetchWrapper → fetch
                          │
                          ├─ 401 → wyczyść token, przełącz na LoginForm
                          ├─ 4xx → komunikat walidacyjny/biznesowy przez AppMessenger
                          └─ 5xx/sieć → komunikat ogólny przez AppMessenger + szczegóły w stanie błędu
```

## Klasyfikacja błędów

| Klasa | Źródło | Reakcja |
|-------|--------|---------|
| Walidacja (400/422) | odpowiedź API z opisem pól | pokaż przy polu formularza (`BaseTextField` + validators), nie globalnie |
| Autoryzacja (401) | wygasły/nieprawidłowy token | wyczyść token (js-cookie), wróć do logowania — obsługuje useFetchWrapper |
| Brak uprawnień (403) | rola bez dostępu | komunikat AppMessenger „Brak uprawnień..." — bez wylogowania |
| Nie znaleziono (404) | zasób usunięty/zły identyfikator | stan `empty`/komunikat kontekstowy w widoku |
| Serwer/sieć (5xx, timeout, offline) | backend/sieć | AppMessenger z komunikatem ogólnym + możliwość ponowienia |

Stan ładowania w komponencie modeluj discriminated union
(`'idle' | 'loading' | 'error' | 'ready'`), nie kolekcją booleanów.

## Komunikaty

- Komunikaty dla użytkownika PO POLSKU, opisujące skutek i następny krok
  („Nie udało się zapisać kategorii. Spróbuj ponownie."), nie szczegóły techniczne.
- Szczegóły techniczne (status, body błędu) zostają w stanie błędu composable'a —
  dostępne do diagnostyki, niepokazywane wprost.

## console.* w kodzie produkcyjnym

Zakaz `console.log` / `console.warn` / `console.error` w kodzie produkcyjnym (pilnuje hook
`error-handling-reminder.sh` i ESLint). Diagnostyka developerska wyłącznie za flagą dev:

```ts
if (import.meta.env.DEV) {
	console.error('[useAssets] nieoczekiwany ksztalt odpowiedzi', payload);
}
```

Błędy istotne dla użytkownika → AppMessenger. Błędy istotne dla developera → stan błędu
composable'a + (w dev) console za flagą.

## Cleanup i wyścigi

- Fetch w composable: przekazuj `AbortController.signal`; anuluj w `onUnmounted`
  i przy ponownym wywołaniu tej samej operacji (ostatnie żądanie wygrywa).
- Operacje wzajemnie wykluczające się (np. ładowanie podglądu) — blokuj kolejną,
  dopóki poprzednia się nie zakończy albo nie zostanie anulowana.
- `Promise.finally()` do zdjęcia stanu `loading` — nie duplikuj w `then` i `catch`.

## Checklist nowego kodu

- [ ] Wywołanie REST przez `api.ts`, nie surowy fetch w komponencie
- [ ] Stany `loading` / `error` / `empty` obsłużone w widoku
- [ ] Komunikaty użytkownika po polsku, przez AppMessenger lub przy polu formularza
- [ ] Zero `console.*` poza `import.meta.env.DEV`
- [ ] AbortController + cleanup w `onUnmounted` dla operacji async
