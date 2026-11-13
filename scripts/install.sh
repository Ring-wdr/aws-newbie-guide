#!/usr/bin/env bash
# 사용법: scripts/install.sh [--rebuild]
#
# 실습에 필요한 프로그램을 확인하고(없으면 macOS에서는 Homebrew로 설치), 컨테이너 런타임을 켜고,
# aws-emulator 이미지를 빌드하고, Python 의존성(boto3)을 설치한다. 여러 번 실행해도 안전하다.
#
#   --rebuild   에뮬레이터 이미지를 새로 빌드한다 (최신 에뮬레이터로 업데이트할 때)
#
# 환경 변수
#   COLIMA_CPU / COLIMA_MEMORY / COLIMA_DISK   Colima를 처음 켤 때의 자원 (기본 2 / 4 / 30, 단위 GiB)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/_common.sh
. "$here/_common.sh"

REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1

OS="$(uname -s)"
DOCKER_DESKTOP_APP="${DOCKER_DESKTOP_APP:-/Applications/Docker.app}"
missing=()
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 1. 프로그램
step "1/5 필수 프로그램 확인"
for c in git curl; do
  have "$c" || die "$c 가 필요합니다. 먼저 설치하세요."
done

if [ "$OS" = "Darwin" ]; then
  if ! have brew; then
    # Homebrew 를 막 설치하면 brew 는 있지만 PATH 에 없다(설치 프로그램이 마지막에 안내하는 shellenv 단계를 건너뛴 경우).
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$b" ]; then
        die "Homebrew($b)는 설치돼 있지만 PATH 에 없습니다. 다음을 실행한 뒤(또는 새 터미널에서) 다시 실행하세요: eval \"\$($b shellenv)\""
      fi
    done
    die "Homebrew가 필요합니다. https://brew.sh 의 안내대로 설치한 뒤 다시 실행하세요."  # external-host-ok: 설치 안내 문구(호출하지 않음)
  fi
  want=()
  have aws || want+=(awscli)
  have uv || want+=(uv)
  have docker || want+=(docker)
  # 실습 스크립트가 쓰는 jq (macOS 15 부터는 /usr/bin/jq 가 기본으로 있다)
  have jq || want+=(jq)
  # Docker Desktop 등 다른 런타임이 이미 동작 중이거나, Docker Desktop 이 설치돼 있으면(꺼져 있어도)
  # Colima를 설치하지 않는다 — 런타임을 두 개 두면 docker 컨텍스트가 엇갈린다.
  if ! have colima && ! { have docker && docker info >/dev/null 2>&1; } && [ ! -d "$DOCKER_DESKTOP_APP" ]; then
    want+=(colima)
  fi
  if [ ${#want[@]} -gt 0 ]; then
    echo "Homebrew로 설치합니다: ${want[*]}"
    brew install "${want[@]}"
  fi
else
  # Linux / WSL: 배포판마다 설치 방법이 달라 안내만 한다.
  have docker || missing+=("docker  → https://docs.docker.com/engine/install/ (설치 후 'sudo usermod -aG docker \$USER' 하고 다시 로그인)")  # external-host-ok: 설치 안내 문구(호출하지 않음)
  have aws || missing+=("aws CLI v2 → https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html")  # external-host-ok: 설치 안내 문구(호출하지 않음)
  have uv || missing+=("uv → curl -LsSf https://astral.sh/uv/install.sh | sh")  # external-host-ok: 설치 안내 문구(호출하지 않음)
  # 실습 스크립트가 직접 부르는 도구 (Ubuntu 최소 이미지·WSL 기본 배포판에는 없을 수 있다)
  have jq || missing+=("jq → Debian/Ubuntu: sudo apt install jq")
  have python3 || missing+=("python3 → Debian/Ubuntu: sudo apt install python3")
  if [ ${#missing[@]} -gt 0 ]; then
    c_red "다음 프로그램을 설치한 뒤 다시 실행하세요:"
    for m in "${missing[@]}"; do echo "  - $m"; done
    exit 1
  fi
fi

# AWS CLI 버전: AWS_ENDPOINT_URL 환경 변수는 v2.13.0 부터 지원
cli_ver="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9.]*\).*|\1|p')"
case "$cli_ver" in
  1.*) die "AWS CLI v1($cli_ver)입니다. v2가 필요합니다." ;;
  2.*)
    minor="$(echo "$cli_ver" | cut -d. -f2)"
    [ "$minor" -ge 13 ] || die "AWS CLI $cli_ver 는 너무 오래됐습니다(AWS_ENDPOINT_URL 미지원). 2.13 이상으로 업데이트하세요."
    ;;
  *) die "aws --version 을 해석하지 못했습니다: $(aws --version 2>&1)" ;;
esac
c_grn "aws-cli $cli_ver · $(uv --version) · $(docker --version)"

# ---------------------------------------------------------------- 2. 컨테이너 런타임
step "2/5 컨테이너 런타임"
if docker info >/dev/null 2>&1; then
  c_grn "Docker 데몬 연결됨 ($(docker context show 2>/dev/null || echo default))"
elif [ "$OS" = "Darwin" ] && have colima; then
  cpu="${COLIMA_CPU:-2}" mem="${COLIMA_MEMORY:-4}" disk="${COLIMA_DISK:-30}"
  if colima status >/dev/null 2>&1; then
    die "Colima는 실행 중인데 docker가 접속하지 못합니다. 'docker context use colima' 를 실행해 보세요."
  fi
  echo "Colima를 시작합니다 (CPU $cpu, 메모리 ${mem}GiB, 디스크 ${disk}GiB). 처음에는 1~3분 걸립니다."
  if ! colima list 2>/dev/null | grep -q '^default'; then
    colima start --cpu "$cpu" --memory "$mem" --disk "$disk" --vm-type vz --mount-type virtiofs
  else
    # 이미 만들어진 VM은 기존 설정 그대로 켠다.
    colima start
  fi
  docker info >/dev/null 2>&1 || die "Colima를 켰지만 docker가 접속하지 못합니다. 'docker context use colima' 를 실행해 보세요."
  c_grn "Colima 실행 중"
elif [ "$OS" = "Darwin" ] && [ -d "$DOCKER_DESKTOP_APP" ]; then
  die "Docker Desktop 이 설치돼 있지만 실행 중이 아닙니다. Docker Desktop 을 실행한 뒤 다시 실행하세요. (Colima를 쓰려면: brew install colima 후 다시 실행)"
elif case "$(docker info 2>&1 || true)" in *"permission denied"* | *"Permission denied"*) true ;; *) false ;; esac; then
  die "Docker 데몬에 접속할 권한이 없습니다. 'sudo usermod -aG docker \$USER' 후 로그아웃했다가 다시 로그인하세요."
else
  die "Docker 데몬에 접속할 수 없습니다. Docker를 실행한 뒤 다시 시도하세요 (Linux: 'sudo systemctl start docker')."
fi

# ---------------------------------------------------------------- 3. 에뮬레이터 이미지
step "3/5 에뮬레이터 이미지 ($EMULATOR_IMAGE)"
# AWS는 에뮬레이터 이미지를 배포하지 않는다. 공식 RPM으로 로컬에서 빌드한다.
case "$(docker info --format '{{.Architecture}}' 2>/dev/null)" in
  aarch64 | arm64) arch=aarch64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) die "지원하지 않는 아키텍처입니다: $(docker info --format '{{.Architecture}}')" ;;
esac
if [ "$REBUILD" = 1 ] || ! docker image inspect "$EMULATOR_IMAGE" >/dev/null 2>&1; then
  echo "이미지를 빌드합니다 (아키텍처 $arch). 1~2분 걸립니다."
  build_args=(build -t "$EMULATOR_IMAGE" --build-arg "EMULATOR_ARCH=$arch")
  [ "$REBUILD" = 1 ] && build_args+=(--pull --no-cache)
  docker "${build_args[@]}" "$here/docker"
else
  echo "이미 있습니다. 최신 에뮬레이터로 다시 빌드하려면: scripts/install.sh --rebuild"
fi
c_grn "$(docker run --rm --network none --entrypoint aws-emulator "$EMULATOR_IMAGE" --version | head -1)"

# ---------------------------------------------------------------- 4. Python 의존성
step "4/5 Python 의존성 (uv sync)"
root="$(repo_root)"
(cd "$root" && uv sync --quiet)
c_grn "$(cd "$root" && uv run --quiet python -c 'import boto3, sys; print(f"Python {sys.version.split()[0]} · boto3 {boto3.__version__}")')"

# ---------------------------------------------------------------- 5. 안내
step "5/5 완료"
mkdir -p "$EMULATOR_HOME_DIR"
cat <<EOF
다음 단계:
  scripts/emulator-up.sh            # 에뮬레이터 시작 (포트 9297)
  source scripts/env.sh             # 현재 셸을 에뮬레이터에 연결
  aws sts get-caller-identity       # Account 가 000000000000 이면 성공
EOF
