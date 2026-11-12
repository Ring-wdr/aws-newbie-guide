# shellcheck shell=bash
# M04 lab 공용 함수 (lab 스크립트가 env.sh 다음에 source 한다. 단독 실행용 아님)

# purge_bucket <버킷> — 버전·삭제 마커·미완료 멀티파트까지 모두 지우고 버킷을 삭제한다.
# 버전 관리 버킷은 'aws s3 rb --force' 로 지워지지 않는다(현재 버전만 지우고, 이전 버전·삭제 마커가 남는다).
# 객체 잠금(거버넌스)이 걸린 버전은 --bypass-governance-retention 으로 지운다.
purge_bucket() {
  local b="$1" json
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || return 0
  aws s3api delete-bucket-replication --bucket "$b" >/dev/null 2>&1 || true
  json="$(aws s3api list-multipart-uploads --bucket "$b" --output json 2>/dev/null || echo '{}')"
  jq -r '.Uploads[]? | [.Key, .UploadId] | @tsv' <<<"$json" | while IFS=$'\t' read -r k u; do
    aws s3api abort-multipart-upload --bucket "$b" --key "$k" --upload-id "$u" >/dev/null 2>&1 || true
  done
  json="$(aws s3api list-object-versions --bucket "$b" --output json 2>/dev/null || echo '{}')"
  jq -r '(.Versions // []) + (.DeleteMarkers // []) | .[] | [.Key, .VersionId] | @tsv' <<<"$json" |
    while IFS=$'\t' read -r k v; do
      aws s3api put-object-legal-hold --bucket "$b" --key "$k" --version-id "$v" \
        --legal-hold Status=OFF >/dev/null 2>&1 || true
      aws s3api delete-object --bucket "$b" --key "$k" --version-id "$v" \
        --bypass-governance-retention >/dev/null 2>&1 || true
    done
  aws s3api delete-bucket --bucket "$b" >/dev/null 2>&1 || true
}

# expect_error <코드> <설명> -- <aws 인자...> : 명령이 실패하고 출력에 오류 코드가 있으면 출력을 보여 주고 0
expect_error() {
  local code="$1" out
  shift
  set +e
  out="$("$@" 2>&1 >/dev/null)"
  local rc=$?
  set -e
  printf '%s\n' "$out" | sed '/^$/d'
  if [ "$rc" -eq 0 ] || ! grep -q "$code" <<<"$out"; then
    echo "FAIL: '$code' 오류를 기대했지만 rc=$rc"
    return 1
  fi
}
