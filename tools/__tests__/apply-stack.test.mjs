// Testy tools/apply-stack.sh — nakładania warstwy stosu na maszynerię z upstreamu.
//
// Uruchomienie:  node --test tools/__tests__/apply-stack.test.mjs
//
// DLACZEGO TEN TEST ISTNIEJE:
// overlay bierze pliki `.claude/` na wlasnosc, wiec cicha pomylka w manifescie albo
// w wykrywaniu driftu konczy sie tym, ze projekty (gio-projects, cn-projects) dostaja
// przez /sync-template maszynerie z nadpisami zbudowanymi na NIEAKTUALNEJ wersji
// upstreamu — i nikt sie o tym nie dowiaduje. Test pilnuje trzech rzeczy: kontraktu
// manifestu, idempotencji nalozenia i tego, ze drift upstreamu zatrzymuje publikacje.

import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'
import assert from 'node:assert/strict'

const SKRYPT = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'apply-stack.sh')

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' })
  assert.equal(r.status, 0, `git ${args.join(' ')} -> ${r.stderr}`)
  return r.stdout.trim()
}

function zapisz(repo, wzgledna, tresc) {
  const pelna = join(repo, wzgledna)
  mkdirSync(dirname(pelna), { recursive: true })
  writeFileSync(pelna, tresc)
  return pelna
}

function uruchom(repo, ...args) {
  const r = spawnSync('bash', [SKRYPT, ...args], { cwd: repo, encoding: 'utf8' })
  return { kod: r.status, out: `${r.stdout}${r.stderr}` }
}

// Repo-atrapa: upstreamowy `.claude/` w gałęzi main + overlay stosu `test` w drzewie roboczym.
function fixture({ manifest } = {}) {
  const repo = mkdtempSync(join(tmpdir(), 'apply-stack-'))
  git(repo, 'init', '-b', 'main')
  git(repo, 'config', 'user.email', 'test@example.com')
  git(repo, 'config', 'user.name', 'Test')

  zapisz(repo, '.claude/agents/feature-builder-ui.md', 'upstream: React 19\n')
  zapisz(repo, '.claude/skills/tailwind-react-guidelines/SKILL.md', 'upstream: React\n')
  zapisz(repo, '.claude/rules/coding-rules.md', '# Reguly\n\n- regula upstreamu\n')
  git(repo, 'add', '-A')
  git(repo, 'commit', '-qm', 'upstream')

  zapisz(repo, 'stacks/test/files/.claude/agents/feature-builder-ui.md', 'stack: Vue 3.5\n')
  zapisz(repo, 'stacks/test/files/.claude/skills/vue-tailwind-guidelines/SKILL.md', 'stack: Vue\n')
  zapisz(repo, 'stacks/test/fragments/coding-rules.md', '- regula stosu (Java 21)\n')
  zapisz(
    repo,
    'stacks/test/overlay.tsv',
    manifest ??
      [
        'replace\t.claude/agents/feature-builder-ui.md\tfiles/.claude/agents/feature-builder-ui.md',
        'new\t.claude/skills/vue-tailwind-guidelines/SKILL.md\tfiles/.claude/skills/vue-tailwind-guidelines/SKILL.md',
        'append\t.claude/rules/coding-rules.md\tfragments/coding-rules.md',
        'delete\t.claude/skills/tailwind-react-guidelines/SKILL.md',
      ].join('\n') + '\n',
  )
  return repo
}

test('check bez baseline zglasza BRAK_BASELINE i konczy sie kodem 3', () => {
  const repo = fixture()
  const { kod, out } = uruchom(repo, '--stack', 'test')
  assert.equal(kod, 3)
  assert.match(out, /STATUS: WYMAGA_PRZEGLADU/)
  assert.match(out, /BRAK_BASELINE/)
  assert.match(out, /feature-builder-ui\.md/)
  rmSync(repo, { recursive: true, force: true })
})

test('accept-drift zapisuje baseline tylko dla celow istniejacych w upstreamie, potem check jest zielony', () => {
  const repo = fixture()
  assert.equal(uruchom(repo, '--stack', 'test', '--accept-drift').kod, 0)

  const baseline = readFileSync(join(repo, 'stacks/test/baseline.sha256'), 'utf8').trim().split('\n')
  assert.equal(baseline.length, 3, 'replace + append + delete maja baseline, `new` nie ma')
  assert.ok(!baseline.some((w) => w.includes('vue-tailwind-guidelines')))
  assert.match(readFileSync(join(repo, 'stacks/test/base.ref'), 'utf8').trim(), /^[0-9a-f]{40}$/)

  const { kod, out } = uruchom(repo, '--stack', 'test')
  assert.equal(kod, 0)
  assert.match(out, /STATUS: OK/)
  rmSync(repo, { recursive: true, force: true })
})

test('apply wykonuje wszystkie cztery operacje i zapisuje znacznik .stack-applied', () => {
  const repo = fixture()
  uruchom(repo, '--stack', 'test', '--accept-drift')
  const { kod } = uruchom(repo, '--stack', 'test', '--apply')
  assert.equal(kod, 0)

  assert.equal(readFileSync(join(repo, '.claude/agents/feature-builder-ui.md'), 'utf8'), 'stack: Vue 3.5\n')
  assert.ok(existsSync(join(repo, '.claude/skills/vue-tailwind-guidelines/SKILL.md')))
  assert.ok(!existsSync(join(repo, '.claude/skills/tailwind-react-guidelines/SKILL.md')))
  assert.ok(!existsSync(join(repo, '.claude/skills/tailwind-react-guidelines')), 'pusty katalog po delete jest przycinany')

  const reguly = readFileSync(join(repo, '.claude/rules/coding-rules.md'), 'utf8')
  assert.match(reguly, /- regula upstreamu/)
  assert.match(reguly, /<!-- stack:test:start -->\n- regula stosu \(Java 21\)\n<!-- stack:test:end -->/)

  assert.match(readFileSync(join(repo, '.claude/.stack-applied'), 'utf8'), /^stack: test$/m)
  rmSync(repo, { recursive: true, force: true })
})

test('drugie apply nie duplikuje bloku append (idempotencja)', () => {
  const repo = fixture()
  uruchom(repo, '--stack', 'test', '--accept-drift')
  uruchom(repo, '--stack', 'test', '--apply')
  const poPierwszym = readFileSync(join(repo, '.claude/rules/coding-rules.md'), 'utf8')
  uruchom(repo, '--stack', 'test', '--apply')
  const poDrugim = readFileSync(join(repo, '.claude/rules/coding-rules.md'), 'utf8')

  assert.equal(poDrugim, poPierwszym)
  assert.equal(poDrugim.match(/regula stosu/g).length, 1)
  rmSync(repo, { recursive: true, force: true })
})

test('zmiana nadpisywanego pliku w upstreamie zatrzymuje publikacje jako DRIFT', () => {
  const repo = fixture()
  uruchom(repo, '--stack', 'test', '--accept-drift')

  zapisz(repo, '.claude/agents/feature-builder-ui.md', 'upstream: React 19 + nowa sekcja\n')
  git(repo, 'add', '-A')
  git(repo, 'commit', '-qm', 'upstream rusza agenta')

  const { kod, out } = uruchom(repo, '--stack', 'test')
  assert.equal(kod, 3)
  assert.match(out, /DRIFT/)
  assert.match(out, /feature-builder-ui\.md/)
  assert.match(out, /JAK PRZEJRZEĆ: git diff/)

  const publikacja = uruchom(repo, '--stack', 'test', '--publish')
  assert.equal(publikacja.kod, 3, 'publish nie buduje galezi na nieprzejrzanym drifcie')
  assert.equal(git(repo, 'branch', '--list', 'stack/test'), '', 'galaz nie powstala')
  rmSync(repo, { recursive: true, force: true })
})

test('publish po przegladzie buduje galaz stack/<id> bez ruszania drzewa roboczego', () => {
  const repo = fixture()
  uruchom(repo, '--stack', 'test', '--accept-drift')
  const { kod, out } = uruchom(repo, '--stack', 'test', '--publish')

  assert.equal(kod, 0)
  assert.match(out, /BRANCH: stack\/test/)
  assert.match(out, /PUSH: pominięty/)
  assert.equal(
    readFileSync(join(repo, '.claude/agents/feature-builder-ui.md'), 'utf8'),
    'upstream: React 19\n',
    'drzewo robocze zostaje czystym lustrem upstreamu',
  )
  assert.equal(git(repo, 'show', 'stack/test:.claude/agents/feature-builder-ui.md'), 'stack: Vue 3.5')
  rmSync(repo, { recursive: true, force: true })
})

test('op new na pliku istniejacym w upstreamie to KOLIZJA, nie ciche nadpisanie', () => {
  const repo = fixture({
    manifest: 'new\t.claude/agents/feature-builder-ui.md\tfiles/.claude/agents/feature-builder-ui.md\n',
  })
  const { kod, out } = uruchom(repo, '--stack', 'test')
  assert.equal(kod, 3)
  assert.match(out, /KOLIZJA/)
  rmSync(repo, { recursive: true, force: true })
})

test('manifest z brakujacym zrodlem albo celem spoza .claude/ konczy sie kodem 2', () => {
  const brakZrodla = fixture({ manifest: 'replace\t.claude/agents/feature-builder-ui.md\tfiles/nie-ma.md\n' })
  const a = uruchom(brakZrodla, '--stack', 'test')
  assert.equal(a.kod, 2)
  assert.match(a.out, /brak pliku źródłowego/)
  rmSync(brakZrodla, { recursive: true, force: true })

  const zlyCel = fixture({ manifest: 'replace\ttools/apply-stack.sh\tfiles/.claude/agents/feature-builder-ui.md\n' })
  const b = uruchom(zlyCel, '--stack', 'test')
  assert.equal(b.kod, 2)
  assert.match(b.out, /musi być wewnątrz \.claude\//)
  rmSync(zlyCel, { recursive: true, force: true })
})

test('delete calego katalogu kasuje skill upstreamu, a dopisany tam plik wychodzi jako DRIFT', () => {
  const repo = fixture({ manifest: 'delete\t.claude/skills/tailwind-react-guidelines/\n' })
  assert.equal(uruchom(repo, '--stack', 'test', '--accept-drift').kod, 0)
  assert.equal(uruchom(repo, '--stack', 'test', '--apply').kod, 0)
  assert.ok(!existsSync(join(repo, '.claude/skills/tailwind-react-guidelines')))

  git(repo, 'checkout', '-q', '--', '.')
  zapisz(repo, '.claude/skills/tailwind-react-guidelines/resources/nowy-wzorzec.md', 'upstream: nowy plik\n')
  git(repo, 'add', '-A')
  git(repo, 'commit', '-qm', 'upstream dokłada plik do kasowanego skilla')

  const { kod, out } = uruchom(repo, '--stack', 'test')
  assert.equal(kod, 3)
  assert.match(out, /DRIFT/)
  assert.match(out, /tailwind-react-guidelines\//)
  rmSync(repo, { recursive: true, force: true })
})
