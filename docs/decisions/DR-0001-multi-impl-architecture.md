# DR-0001: マルチ実装アーキテクチャ — canonical 実装言語は選定制、PoC は MoonBit から

- Status: Active
- Date: 2026-07-15

## Context

kuu spec (kawaz/kuu) のスタンドアロン CLI を立ち上げる (spec 側 docs/VISION.md の kuu-cli 構想)。置き場所の裁定 (spec 側 CLI-Q1 = b、kawaz 2026-07-15) で「kuu.mbt 内の src/cli パッケージ」ではなく独立リポ kawaz/kuu-cli を選んだ。決め手は **canonical リリースバイナリを MoonBit で書くとは決まっていない**こと:

- kawaz/die の前例: 同一仕様を Go / Rust / MoonBit / Zig の 4 言語で並行実装し、binary size / cold start / cross compile / API 安定性の実測で Zig を選定した (die 側 DR-0003 / DR-0007)。特に MoonBit は当時 cross compile 困難・API 不安定で不採用になった実績がある
- kuu 自体が多言語展開を構想している (spec の conformance fixtures が言語非依存の審判になる設計)。「全言語で同じものを作り、同じ fixture で検証する」形は kuu の構想そのもの

## Decision

1. **リポ構成**: `impl/<lang>/` 配下に言語別実装を並置する。各実装は同じ CLI インターフェイス (サブコマンド・入出力 JSON 形) を実装し、spec の conformance fixtures + 本リポの CLI レベル e2e で同一挙動を検証する
2. **canonical 選定は後日**: リリースバイナリに使う実装は、複数実装が出揃った時点で die DR-0007 と同じ計測軸 (binary size / cold start / cross compile / 保守コスト) で選定し、DR で記録する。それまで release は出さない (VERSION bump しない)
3. **PoC は `impl/mbt` (MoonBit) から**: spec の参照実装 kuu.mbt (front_door / wire_decode) をそのまま流用できるため、CLI インターフェイスの輪郭を最速で固められる。PoC の目的は「CLI の入出力契約を確定させること」であって MoonBit を canonical に推すことではない
4. **CLI の入出力契約が確定したら本リポの docs で正本化**する (サブコマンド体系・JSON 出力形・exit code)。他言語実装はその契約 + spec fixtures に対して書く

## Alternatives Considered

### kuu.mbt リポ内の src/cli パッケージ (CLI-Q1 案 a)

conformance と同居して最速だが、「kuu-cli = MoonBit 製」がリポ構造で既成事実化する。canonical 言語を実測で選ぶ余地を残す本方針と整合しない (kawaz 裁定で不採用)。

### 最初から die 方式の 4 言語並行実装

CLI の入出力契約が固まる前に 4 言語で書くと、契約変更のたびに 4 実装を直す羽目になる。PoC 1 言語で契約を固めてから並行実装に進む方が手戻りが小さい。

## Consequences

- kuu.mbt への依存は moon.work (workspace) のローカルパス解決で行う (mooncakes 未公開のため。実機検証済み: versioned import + moon.work member 並置で解決される)。CI では kuu.mbt を SHA-pin checkout して並置する (kuu.mbt が spec fixtures を KUU_FIXTURES で注入するのと同じロックステップパターン)
- brew 配布・Releases は canonical 選定後 (本 DR §2)
