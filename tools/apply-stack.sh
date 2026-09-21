#!/usr/bin/env bash
#
# apply-stack.sh — nakłada warstwę stosu (overlay) z stacks/<id>/ na maszynerię `.claude/`
# przyjętą z upstreamu. Kontrakt, podział własności, pętla po synchronie i uzasadnienie
# "overlay zamiast serii patchy": stacks/README.md
#
# Kody wyjścia: 0 OK | 2 błąd użycia/manifestu | 3 wymaga przeglądu człowieka (drift)

set -euo pipefail

STACK=""
MODE="check"
BASE_REF="main"
TARGET=""
PUSH=0

usage() {
  cat <<'POMOC'
Użycie:
  tools/apply-stack.sh --stack <id>                    # (domyślnie) --check: czy overlay pasuje do upstreamu
  tools/apply-stack.sh --stack <id> --apply            # nałóż na drzewo robocze (--target <dir> dla innego celu)
  tools/apply-stack.sh --stack <id> --publish [--push] # zbuduj gałąź stack/<id> z BASE + overlay
  tools/apply-stack.sh --stack <id> --accept-drift     # zapisz baseline PO przejrzeniu zmian upstreamu

Opcje: --base <ref> (domyślnie main), --target <dir>, --push
POMOC
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)        STACK="${2:-}"; shift 2 ;;
    --check)        MODE="check"; shift ;;
    --apply)        MODE="apply"; shift ;;
    --publish)      MODE="publish"; shift ;;
    --accept-drift) MODE="accept-drift"; shift ;;
    --base)         BASE_REF="${2:-}"; shift 2 ;;
    --target)       TARGET="${2:-}"; shift 2 ;;
    --push)         PUSH=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Nieznany argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$STACK" ]] || { echo "BŁĄD: wymagane --stack <id> (katalog w stacks/)." >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "BŁĄD: brak 'git' w PATH." >&2; exit 2; }
REPO="$(git rev-parse --show-toplevel)"
STACK_DIR="$REPO/stacks/$STACK"
MANIFEST="$STACK_DIR/overlay.tsv"
BASELINE_FILE="$STACK_DIR/baseline.sha256"
BASE_REF_FILE="$STACK_DIR/base.ref"

[[ -d "$STACK_DIR" ]] || { echo "BŁĄD: brak katalogu stosu $STACK_DIR" >&2; exit 2; }
[[ -f "$MANIFEST" ]]  || { echo "BŁĄD: brak manifestu $MANIFEST" >&2; exit 2; }

# --- Wczytaj i zwaliduj manifest (bash 3.2: tablice indeksowane, bez asocjacyjnych) ---
declare -a OPS=() CELE=() ZRODLA=()
LINIA_NR=0
while IFS= read -r linia || [[ -n "$linia" ]]; do
  LINIA_NR=$((LINIA_NR + 1))
  [[ -z "${linia//[[:space:]]/}" ]] && continue
  case "$linia" in \#*) continue ;; esac

  IFS=$'\t' read -r op cel zrodlo <<<"$linia"
  zrodlo="${zrodlo:-}"

  case "$op" in
    replace|new|append|delete) ;;
    *) echo "BŁĄD [$MANIFEST:$LINIA_NR]: nieznany op '$op' (replace|new|append|delete)." >&2; exit 2 ;;
  esac

  case "$cel" in
    .claude/*) ;;
    *) echo "BŁĄD [$MANIFEST:$LINIA_NR]: cel '$cel' musi być wewnątrz .claude/ (overlay rusza tylko maszynerię)." >&2; exit 2 ;;
  esac
  case "$cel" in
    *..*|*[[:space:]]*) echo "BŁĄD [$MANIFEST:$LINIA_NR]: niedozwolony cel '$cel' (.. lub biała spacja)." >&2; exit 2 ;;
  esac

  for istniejacy in ${CELE[@]+"${CELE[@]}"}; do
    [[ "$istniejacy" == "$cel" ]] && { echo "BŁĄD [$MANIFEST:$LINIA_NR]: cel '$cel' występuje dwa razy." >&2; exit 2; }
  done

  if [[ "$op" == "delete" ]]; then
    [[ -z "$zrodlo" || "$zrodlo" == "-" ]] || { echo "BŁĄD [$MANIFEST:$LINIA_NR]: op 'delete' nie przyjmuje źródła." >&2; exit 2; }
    zrodlo=""
  elif [[ "$cel" == */ ]]; then
    echo "BŁĄD [$MANIFEST:$LINIA_NR]: ukośnik na końcu ('$cel') oznacza CAŁY katalog — dozwolony tylko przy 'delete'." >&2; exit 2
  else
    [[ -n "$zrodlo" ]] || { echo "BŁĄD [$MANIFEST:$LINIA_NR]: op '$op' wymaga ścieżki źródłowej (3. kolumna)." >&2; exit 2; }
    [[ -f "$STACK_DIR/$zrodlo" ]] || { echo "BŁĄD [$MANIFEST:$LINIA_NR]: brak pliku źródłowego stacks/$STACK/$zrodlo" >&2; exit 2; }
  fi

  OPS+=("$op"); CELE+=("$cel"); ZRODLA+=("$zrodlo")
done < "$MANIFEST"

[[ "${#CELE[@]}" -gt 0 ]] || { echo "BŁĄD: manifest $MANIFEST nie ma ani jednego wpisu." >&2; exit 2; }

# --- Stan celu w wersji upstreamowej (BASE_REF), nie w drzewie roboczym ---
BASELINE_TXT=""
[[ -f "$BASELINE_FILE" ]] && BASELINE_TXT="$(cat "$BASELINE_FILE")"

baseline_hash() { printf '%s\n' "$BASELINE_TXT" | awk -v c="$1" '$2 == c { print $1; exit }'; }
istnieje_w_base()  { git -C "$REPO" cat-file -e "$BASE_REF:${1%/}" 2>/dev/null; }
# Cel katalogowy hashujemy po LISTINGU drzewa: nowy plik w kasowanym skillu ma wyjść jako drift.
hash_w_base() {
  if [[ "$1" == */ ]]; then
    git -C "$REPO" ls-tree -r "$BASE_REF" -- "${1%/}" | sha256sum | awk '{ print $1 }'
  else
    git -C "$REPO" show "$BASE_REF:$1" | sha256sum | awk '{ print $1 }'
  fi
}

git -C "$REPO" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null \
  || { echo "BŁĄD: nieznana referencja bazowa '$BASE_REF' (--base)." >&2; exit 2; }

# --- CHECK: czy override jest nadal aktualny wobec upstreamu ---
sprawdz() {
  local -a DRIFT=() BRAK_BASELINE=() KOLIZJE=() ZNIKNELE=()
  local i op cel b h

  for ((i = 0; i < ${#CELE[@]}; i++)); do
    op="${OPS[$i]}"; cel="${CELE[$i]}"

    if [[ "$op" == "new" ]]; then
      istnieje_w_base "$cel" && KOLIZJE+=("$cel")
      continue
    fi

    if ! istnieje_w_base "$cel"; then
      ZNIKNELE+=("$cel")
      continue
    fi

    b="$(baseline_hash "$cel")"
    if [[ -z "$b" ]]; then
      BRAK_BASELINE+=("$cel")
    else
      h="$(hash_w_base "$cel")"
      [[ "$b" == "$h" ]] || DRIFT+=("$cel")
    fi
  done

  local -a OSIEROCONE=()  # wpisy baseline bez celu w manifeście = śmieci po usuniętym override
  if [[ -n "$BASELINE_TXT" ]]; then
    while IFS= read -r wiersz; do
      [[ -z "${wiersz//[[:space:]]/}" ]] && continue
      local sciezka znaleziony
      sciezka="$(printf '%s\n' "$wiersz" | awk '{ print $2 }')"
      znaleziony=0
      for cel in "${CELE[@]}"; do [[ "$cel" == "$sciezka" ]] && znaleziony=1 && break; done
      [[ "$znaleziony" -eq 0 ]] && OSIEROCONE+=("$sciezka")
    done <<<"$BASELINE_TXT"
  fi

  echo "STACK: $STACK"
  echo "BASE: $BASE_REF ($(git -C "$REPO" rev-parse --short "$BASE_REF"))"
  echo "WPISY: ${#CELE[@]}"

  local problemy=$(( ${#DRIFT[@]} + ${#BRAK_BASELINE[@]} + ${#KOLIZJE[@]} + ${#ZNIKNELE[@]} + ${#OSIEROCONE[@]} ))
  if [[ "$problemy" -eq 0 ]]; then
    echo "STATUS: OK"
    return 0
  fi

  echo "STATUS: WYMAGA_PRZEGLADU"
  [[ "${#DRIFT[@]}" -gt 0 ]]         && { echo "DRIFT (upstream zmienił plik, którego kopię trzymasz):"; printf '  - %s\n' "${DRIFT[@]}"; }
  [[ "${#BRAK_BASELINE[@]}" -gt 0 ]] && { echo "BRAK_BASELINE (override nigdy nie przeglądany wobec upstreamu):"; printf '  - %s\n' "${BRAK_BASELINE[@]}"; }
  [[ "${#KOLIZJE[@]}" -gt 0 ]]       && { echo "KOLIZJA (op 'new', ale upstream ma już ten plik — zmień na 'replace'):"; printf '  - %s\n' "${KOLIZJE[@]}"; }
  [[ "${#ZNIKNELE[@]}" -gt 0 ]]      && { echo "ZNIKNELE (upstream usunął cel — usuń wpis z manifestu):"; printf '  - %s\n' "${ZNIKNELE[@]}"; }
  [[ "${#OSIEROCONE[@]}" -gt 0 ]]    && { echo "OSIEROCONE_BASELINE (wpis bez celu w manifeście):"; printf '  - %s\n' "${OSIEROCONE[@]}"; }

  if [[ "${#DRIFT[@]}" -gt 0 && -f "$BASE_REF_FILE" ]]; then
    echo "JAK PRZEJRZEĆ: git diff $(cat "$BASE_REF_FILE") $BASE_REF -- ${DRIFT[*]}"
  fi
  echo "PO PRZEGLĄDZIE: przenieś zmiany do stacks/$STACK/files/… i uruchom --accept-drift"
  return 3
}

# --- APPLY: nałóż overlay na katalog docelowy ---
przytnij_puste_katalogi() {
  local cel_dir="$1" root="$2"
  while [[ "$cel_dir" != "$root" && "$cel_dir" != "/" ]]; do
    rmdir "$cel_dir" 2>/dev/null || break
    cel_dir="$(dirname "$cel_dir")"
  done
}

dopisz_fragment() {
  local plik="$1" fragment="$2" start="$3" koniec="$4" tmp
  tmp="$(mktemp)"
  if grep -qF -- "$start" "$plik"; then
    awk -v s="$start" -v e="$koniec" '
      $0 == s { skip = 1 }
      skip == 0 { print }
      $0 == e { skip = 0 }
    ' "$plik" >"$tmp"
    mv "$tmp" "$plik"
  else
    rm -f "$tmp"
  fi
  # Zetnij koncowe puste linie: bez tego kazde kolejne apply dokladalo separator
  # i plik puchl o jedna pusta linie na przebieg (test: idempotencja append).
  tmp="$(mktemp)"
  awk '{ bufor[NR] = $0 } END { ostatnia = NR; while (ostatnia > 0 && bufor[ostatnia] ~ /^[[:space:]]*$/) ostatnia--; for (i = 1; i <= ostatnia; i++) print bufor[i] }' "$plik" >"$tmp"
  mv "$tmp" "$plik"
  { printf '\n%s\n' "$start"; cat "$fragment"; printf '%s\n' "$koniec"; } >>"$plik"
}

nalozOverlay() {
  local dest="$1"
  local i op cel zrodlo sciezka start koniec
  start="<!-- stack:$STACK:start -->"
  koniec="<!-- stack:$STACK:end -->"

  for ((i = 0; i < ${#CELE[@]}; i++)); do
    op="${OPS[$i]}"; cel="${CELE[$i]}"; zrodlo="${ZRODLA[$i]}"
    sciezka="$dest/$cel"

    case "$op" in
      replace|new)
        mkdir -p "$(dirname "$sciezka")"
        cp "$STACK_DIR/$zrodlo" "$sciezka"
        ;;
      append)
        [[ -f "$sciezka" ]] || { echo "BŁĄD: op 'append' na nieistniejącym $cel" >&2; exit 3; }
        dopisz_fragment "$sciezka" "$STACK_DIR/$zrodlo" "$start" "$koniec"
        ;;
      delete)
        if [[ "$cel" == */ ]]; then
          rm -rf "${sciezka%/}"
        else
          rm -f "$sciezka"
        fi
        przytnij_puste_katalogi "$(dirname "${sciezka%/}")" "$dest/.claude"
        ;;
    esac
  done

  {
    echo "stack: $STACK"
    echo "base: $BASE_REF $(git -C "$REPO" rev-parse "$BASE_REF")"
    echo "data: $(date -u +%Y-%m-%d)"
    echo "cele:"
    for ((i = 0; i < ${#CELE[@]}; i++)); do echo "  ${OPS[$i]} ${CELE[$i]}"; done
  } >"$dest/.claude/.stack-applied"

  echo "APPLIED: $STACK -> $dest (${#CELE[@]} wpisów)"
}

# --- ACCEPT-DRIFT: zapisz aktualne hashe upstreamu jako przejrzane ---
zaakceptuj_drift() {
  local i op cel tmp
  tmp="$(mktemp)"
  for ((i = 0; i < ${#CELE[@]}; i++)); do
    op="${OPS[$i]}"; cel="${CELE[$i]}"
    [[ "$op" == "new" ]] && continue
    istnieje_w_base "$cel" || { echo "BŁĄD: cel '$cel' nie istnieje w $BASE_REF — popraw manifest." >&2; rm -f "$tmp"; exit 3; }
    printf '%s  %s\n' "$(hash_w_base "$cel")" "$cel" >>"$tmp"
  done
  LC_ALL=C sort -k2,2 "$tmp" >"$BASELINE_FILE"
  rm -f "$tmp"
  git -C "$REPO" rev-parse "$BASE_REF" >"$BASE_REF_FILE"
  echo "BASELINE: zapisany ($(wc -l <"$BASELINE_FILE" | tr -d ' ') wpisów) na $(git -C "$REPO" rev-parse --short "$BASE_REF")"
}

# --- PUBLISH: zbuduj gałąź stack/<id> = BASE + overlay, w osobnym worktree ---
WORKTREE_TMP=""
sprzatnij_worktree() {
  [[ -n "$WORKTREE_TMP" ]] || return 0
  git -C "$REPO" worktree remove --force "$WORKTREE_TMP" >/dev/null 2>&1 || true
  WORKTREE_TMP=""
}
trap sprzatnij_worktree EXIT

opublikuj() {
  local wt sha
  wt="$(mktemp -d)"; rm -rf "$wt"
  WORKTREE_TMP="$wt"   # trap EXIT czyta zmienna GLOBALNA: lokalna jest poza zasiegiem, gdy trap biegnie
  git -C "$REPO" worktree add --detach "$wt" "$BASE_REF" >/dev/null
  nalozOverlay "$wt"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "stack($STACK): overlay na $(git -C "$REPO" rev-parse --short "$BASE_REF")"
  sha="$(git -C "$wt" rev-parse HEAD)"
  git -C "$REPO" branch -f "stack/$STACK" "$sha"
  echo "BRANCH: stack/$STACK -> $(git -C "$REPO" rev-parse --short "stack/$STACK")"
  if [[ "$PUSH" -eq 1 ]]; then
    git -C "$REPO" push --force-with-lease origin "stack/$STACK"
    echo "PUSHED: origin stack/$STACK"
  else
    echo "PUSH: pominięty (dodaj --push)"
  fi
  sprzatnij_worktree
}

case "$MODE" in
  check)         sprawdz ;;
  accept-drift)  zaakceptuj_drift ;;
  apply)         sprawdz || true; nalozOverlay "${TARGET:-$REPO}" ;;
  publish)       sprawdz; opublikuj ;;
esac
