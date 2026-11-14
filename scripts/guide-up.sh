#!/usr/bin/env bash
# 가이드 사이트를 (필요하면) 빌드하고 127.0.0.1 에서만 연다 — docs/GUIDE-SITE.md 3장.
# 에뮬레이터와 무관하다(에뮬레이터를 띄우거나 부르지 않는다). 페이지는 명령을 복사만 하고 실행하지 않는다.
#
# 사용:
#   scripts/guide-up.sh              # 대화형 터미널: 기본 포트 4321
#   scripts/guide-up.sh 4331         # 포트 지정 (비대화형 실행에서는 반드시 지정)
#   GUIDE_REBUILD=1 scripts/guide-up.sh 4331   # 원고가 바뀌지 않았어도 다시 빌드
#   GUIDE_BASE=/aws-newbie-guide/ scripts/guide-up.sh 4331   # 공개 배포본과 같은 하위 경로로 빌드해 http://127.0.0.1:4331/aws-newbie-guide/ 에서 연다
#
# 처음 한 번은 site/ 의 Node 패키지를 lockfile 그대로 설치한다(npm 레지스트리 접속, 빌드하는 쪽에만 필요).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="$ROOT/site"

port="${1:-${GUIDE_PORT:-}}"
if [ -z "$port" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    port=4321
  else
    echo "비대화형 실행에서는 포트를 지정해야 한다: scripts/guide-up.sh <포트>  (에이전트마다 전용 포트 — docs/AGENTS.md)" >&2
    exit 2
  fi
fi
if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
  echo "포트는 1024~65535 의 숫자여야 한다: $port" >&2
  exit 2
fi

for tool in node pnpm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool 이 없다. 사이트를 빌드하려면 Node 24 이상과 pnpm 이 필요하다(site/README.md)." >&2
    exit 1
  fi
done

export ASTRO_TELEMETRY_DISABLED=1
export ASTRO_DISABLE_UPDATE_CHECK=true

cd "$SITE"
if [ ! -d node_modules ] || [ pnpm-lock.yaml -nt node_modules/.modules.yaml ]; then
  echo "== site/ 패키지 설치 (lockfile 고정)"
  pnpm install --frozen-lockfile
fi

# 포트가 이미 쓰이면 빌드 전에 알린다(127.0.0.1·0.0.0.0·[::] 어느 쪽에서 듣든). 서버도 같은 검사를 하고 다른 포트로 옮기지 않는다.
# (이 검사는 site/ 의 패키지를 불러오므로 설치 뒤에 한다 — 갓 받은 저장소에서 먼저 하면 모듈을 찾지 못해 죽는다.)
if ! node scripts/serve.mjs --port "$port" --check; then
  exit 1
fi

# 산출물이 빌드된 base 경로(site/src/lib/base.mjs 의 GUIDE_BASE)와 이번에 원하는 base 가 다르면 다시 빌드한다.
# (하위 경로로 빌드한 산출물을 그대로 두고 루트로 열면 모든 링크가 /aws-newbie-guide/ 아래를 가리킨다.)
want_base="${GUIDE_BASE:-}"
want_base="${want_base#"${want_base%%[!/]*}"}"; want_base="${want_base%"${want_base##*[!/]}"}"
[ -n "$want_base" ] && want_base="/$want_base"
built_base=""
if [ -f dist/index.html ]; then
  built_base="$(grep -oE '(href|src)="(/[A-Za-z0-9._-]+)*/_astro/' dist/index.html | head -n 1 | sed -E 's/^(href|src)="//; s#/_astro/$##' || true)"
fi

needs_build=0
if [ "${GUIDE_REBUILD:-0}" = "1" ] || [ ! -f dist/index.html ]; then
  needs_build=1
elif [ "$built_base" != "$want_base" ]; then
  echo "== 산출물의 base(${built_base:-/})가 원하는 base(${want_base:-/})와 다르다 — 다시 빌드한다"
  needs_build=1
elif [ -n "$(find "$ROOT/curriculum" "$ROOT/docs" "$ROOT/README.md" "$SITE/src" "$SITE/astro.config.mjs" \
          "$SITE/package.json" "$SITE/pnpm-lock.yaml" -newer dist/index.html -print -quit 2>/dev/null)" ]; then
  needs_build=1
fi
if [ "$needs_build" = "1" ]; then
  echo "== 사이트 빌드 (원고 → site/dist)"
  pnpm run build
else
  echo "== 빌드가 최신이다 (다시 빌드하려면 GUIDE_REBUILD=1)"
fi

exec node scripts/serve.mjs --port "$port"
