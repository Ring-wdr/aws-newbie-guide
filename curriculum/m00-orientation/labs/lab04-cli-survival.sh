#!/usr/bin/env bash
# M00 lab04 — AWS CLI 생존 기술 (🟢)
# --query(JMESPath), --output, 페이지네이션(--max-items / --starting-token), wait 를 써 본다.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/scripts/env.sh"

BUCKET="todayorder-m00-cli"
aws s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
aws s3api create-bucket --bucket "$BUCKET" --output text --query Location
aws s3api wait bucket-exists --bucket "$BUCKET"

# 주문 7건을 올린다 (본문은 주문 번호)
for i in 1 2 3 4 5 6 7; do
  printf 'order %s\n' "$i" | aws s3 cp - "s3://$BUCKET/orders/A-100$i.txt" --quiet
done

echo "== 1. --query 로 필요한 필드만 (JSON)"
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].{Key: Key, Size: Size}' --max-items 2

echo "== 2. --output table"
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[0:3].[Key, Size]' --output table

echo "== 3. --output text (셸 변수에 담기 좋다)"
aws s3api list-objects-v2 --bucket "$BUCKET" --query 'length(Contents)' --output text

echo "== 4. 페이지네이션: 3개씩 끊어 읽기"
page1="$(aws s3api list-objects-v2 --bucket "$BUCKET" --max-items 3 --query '{Keys: Contents[].Key, NextToken: NextToken}')"
echo "$page1"
# 주의: 페이지네이션 결과에 --output text 를 쓰면 페이지마다 한 줄씩 찍혀 토큰 앞에 None 이 끼어든다.
#       토큰은 JSON으로 받아 따옴표만 벗긴다.
token="$(aws s3api list-objects-v2 --bucket "$BUCKET" --max-items 3 --query NextToken --output json | tr -d '"')"
aws s3api list-objects-v2 --bucket "$BUCKET" --max-items 3 --starting-token "$token" --query 'Contents[].Key'

count="$(aws s3api list-objects-v2 --bucket "$BUCKET" --query 'length(Contents)' --output text)"
first_page="$(grep -c '"orders/' <<<"$page1")"

echo "== 5. 정리"
aws s3 rb "s3://$BUCKET" --force >/dev/null && echo "버킷 삭제 완료"

# ---- 단언
[ "$count" = "7" ] || { echo "FAIL: 객체 수가 7이 아님 ($count)"; exit 1; }
[ "$first_page" = "3" ] || { echo "FAIL: 첫 페이지가 3건이 아님 ($first_page)"; exit 1; }
[ -n "$token" ] && [ "$token" != "None" ] || { echo "FAIL: NextToken 이 없음"; exit 1; }
echo "LAB04 OK"
