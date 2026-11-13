# M00 퀴즈

> 모든 문항은 이 커리큘럼을 위해 새로 만든 문제다. 80% 이상(12문항 중 10문항) 맞히면 다음 모듈로.

---

**1.** TodayOrder는 국내 고객의 주문 데이터를 다루며, 법무팀이 "개인정보는 국내에 보관"을 요구했다. 해외 사용자도 조금 있다. 어떤 결정을 가장 먼저 내려야 하는가?

- A. 지연 시간이 가장 짧은 리전을 고른다
- B. 가장 저렴한 리전을 고른다
- C. 서울 리전(`ap-northeast-2`)에 데이터 저장소를 둔다
- D. CloudFront로 전 세계에 데이터를 캐시한다

<details><summary>정답과 해설</summary>

**C.** 리전 선택 기준 중 규정 준수·데이터 주권이 가장 먼저다. A·B는 그다음 기준이고, D는 정적 콘텐츠 가속용이며 "데이터를 국내에 보관"하는 요구를 오히려 위반할 수 있다.
</details>

---

**2.** 주문 API 서버를 한 AZ의 EC2 두 대에 올렸다. 그 AZ 전체에 전원 장애가 났다. 무엇이 문제였나?

- A. 인스턴스 유형이 작았다
- B. 엣지 로케이션을 쓰지 않았다
- C. 다른 리전에 백업이 없었다
- D. 서버를 서로 다른 AZ에 나누지 않았다

<details><summary>정답과 해설</summary>

**D.** AZ는 전원·네트워크가 분리된 장애 격리 단위다. 같은 AZ에 두 대를 두면 AZ 장애에 함께 죽는다. C(다른 리전)는 리전 전체 장애 대비로, 이 상황에는 과하다. A·B는 가용성과 무관하다.
</details>

---

**3.** 부산·대구 같은 특정 대도시의 게임 사용자에게 한 자릿수 밀리초 지연으로 게임 서버를 제공하고 싶다. 어떤 인프라가 맞는가?

- A. 엣지 로케이션
- B. Local Zones
- C. Outposts
- D. 다른 리전

<details><summary>정답과 해설</summary>

**B.** Local Zones는 대도시 가까이에 놓인 리전의 확장으로, EC2 같은 컴퓨트를 사용자 근처에서 돌린다. A는 CloudFront·Route 53 등 엣지 서비스용이라 게임 서버(EC2)를 둘 수 없다. C는 내 데이터 센터에 두는 것, D는 지연을 줄이는 수단이 아니다. (질문에 나온 도시에 실제로 Local Zone이 있는지는 AWS 문서로 확인해야 한다 — 이 문제는 개념을 묻는다.)
</details>

---

**4.** 5G 휴대폰으로 동작하는 AR 앱이 통신사 네트워크 밖으로 나가지 않고 AWS 컴퓨트에 닿아야 한다. 무엇을 쓰는가?

- A. Wavelength Zones
- B. Global Accelerator
- C. Local Zones
- D. Direct Connect

<details><summary>정답과 해설</summary>

**A.** Wavelength는 통신사 5G 네트워크 안에 AWS 인프라를 둔다. C는 대도시 근처지만 통신사 망 안은 아니다. B는 AWS 글로벌 네트워크로 진입시키는 서비스, D는 온프레미스 전용선이다.
</details>

---

**5.** 다음 중 공동 책임 모델에서 **고객** 책임인 것은?

- A. RDS for MySQL의 DB 엔진 보안 패치 제공
- B. Lambda 런타임을 실행하는 서버의 OS 패치
- C. 데이터 센터 출입 통제
- D. EC2 인스턴스에서 돌아가는 Amazon Linux의 보안 패치 적용

<details><summary>정답과 해설</summary>

**D.** EC2의 게스트 OS는 고객이 관리한다. A(RDS 엔진 패치), B(Lambda 기반 인프라), C(물리 보안)는 AWS 책임이다.
</details>

---

**6.** 새로 연 터미널에서 실습 스크립트를 실행했더니 첫 줄에 `[env.sh] 안전 장치: 요청이 에뮬레이터로 간다는 것을 확인하지 못했습니다 (Account='응답 없음')`가 나오고 멈췄다. `~/.aws/emulator/9297/` 파일은 있다. 가장 가능성 높은 원인과 조치는?

- A. AWS CLI가 없다 → 설치
- B. 실제 AWS 자격 증명이 없다 → `aws configure`
- C. 에뮬레이터가 죽었는데 파일이 남았다 → `scripts/emulator-reset.sh`
- D. 리전이 틀렸다 → `AWS_REGION` 변경

<details><summary>정답과 해설</summary>

**C.** 파일은 있는데 `sts get-caller-identity`가 응답을 못 받았다면 에뮬레이터 컨테이너가 없는 것이다(`docker rm -f`로 지웠거나 Colima VM이 비정상 종료된 경우 등. 정상 종료라면 에뮬레이터가 파일을 지우므로 "파일이 없습니다"가 나온다). A면 "aws CLI를 찾을 수 없습니다"가 나온다. B는 정반대 — 실습에 실제 자격 증명은 필요 없고 쓰면 안 된다. D는 리전과 무관하다.
</details>

---

**7.** 에뮬레이터에서 정책을 하나도 붙이지 않은 IAM 사용자로 `aws s3 mb`를 했더니 버킷이 만들어졌다. 옳은 해석은?

- A. 에뮬레이터의 S3는 버킷 생성 같은 계정 수준 요청에 IAM 정책을 평가하지 않는다. 실제 AWS에서는 암묵적 거부로 실패한다
- B. 실제 AWS에서도 새 사용자는 S3 버킷을 만들 수 있다
- C. S3는 글로벌 서비스라 IAM이 적용되지 않는다
- D. 버킷 정책이 없어서 허용됐다

<details><summary>정답과 해설</summary>

**A.** 실제 AWS의 기본값은 암묵적 거부(Deny)다. 허용하는 정책이 없으면 S3 요청도 거부된다. 탐침 결과 에뮬레이터의 S3·SQS·DynamoDB는 버킷·큐·테이블 생성·삭제·나열 같은 계정 수준 요청에 IAM 정책을 평가하지 않는다(객체·메시지·항목 요청은 평가한다). B는 반대다 — 실제 AWS에서 정책이 없는 새 사용자는 `s3:CreateBucket` 허용이 없어 `AccessDenied`를 받는다. C는 틀린 말(S3 버킷 이름 공간은 전역이지만 IAM은 그대로 적용된다), D는 버킷 정책은 추가 허용·거부 수단일 뿐 정책 부재가 허용을 뜻하지 않는다.
</details>

---

**8.** 셸 스크립트에서 `aws dynamodb create-table`이 실패했을 때 "서비스가 요청을 거부한 경우"만 골라 처리하고 싶다. 어떤 종료 코드를 확인하는가?

- A. 1
- B. 252
- C. 254
- D. 255

<details><summary>정답과 해설</summary>

**C.** 254는 요청이 서비스에 도달했고 서비스가 오류(예: `ValidationException`)를 돌려준 경우다. 252는 명령 문법 오류, 255는 연결 실패 등 그 밖의 오류다. 1은 S3 전송 명령에서 일부 전송이 실패한 경우에 쓰인다.
</details>

---

**9.** CI 서버에서 `aws s3 ls`가 예상과 다른 계정의 버킷을 보여 준다. 다음 중 원인을 찾는 첫 단계로 가장 적절한 것은?

- A. `aws s3api list-buckets --debug`로 응답 XML 확인
- B. 리전을 바꿔 다시 실행
- C. 버킷 정책 확인
- D. `aws sts get-caller-identity`와 `aws configure list`로 자격 증명의 주체와 출처 확인

<details><summary>정답과 해설</summary>

**D.** "누구로 요청하는가"부터 확인한다. `get-caller-identity`는 계정·주체를, `configure list`는 키가 환경 변수·파일·역할 중 어디서 왔는지 보여 준다. 환경 변수가 파일보다 우선하므로 CI 변수에 다른 계정 키가 들어 있는 경우가 흔하다. A도 단서를 주지만 첫 단계로는 장황하고, B·C는 계정이 바뀌는 원인과 무관하다.
</details>

---

**10.** 동료가 다음 boto3 코드를 리뷰 요청했다. 실제 AWS에서 가장 먼저 문제가 될 부분은?

```python
ddb = boto3.client("dynamodb")
ddb.create_table(TableName="todayorder-orders", ...)
ddb.put_item(TableName="todayorder-orders", Item={...})
```

- A. 엔드포인트를 코드에 지정하지 않았다
- B. 테이블이 `ACTIVE`가 되기 전에 쓰기를 시도한다
- C. 리전을 코드에 지정하지 않았다
- D. client 대신 resource를 써야 한다

<details><summary>정답과 해설</summary>

**B.** 테이블은 생성 직후 `CREATING`일 수 있으므로 `get_waiter("table_exists").wait(...)`로 기다려야 한다. 에뮬레이터에서는 즉시 `ACTIVE`라 통과했을 수 있다. A·C는 오히려 권장 사항이다(환경 변수·설정으로 주입해야 같은 코드가 어디서든 동작). D는 반대로, resource는 신규 기능 추가가 중단되어 client가 권장된다.
</details>

---

**11.** SigV4 서명에 대해 옳은 것은?

- A. 서명 범위(credential scope)에 날짜·리전·서비스가 들어가므로, 한 서비스용 서명을 다른 서비스 요청에 재사용할 수 없다
- B. 비밀 액세스 키를 Base64로 인코딩해 헤더에 담는다
- C. 요청 시각과 무관하게 서명은 영구히 유효하다
- D. HTTPS를 쓰면 서명이 필요 없다

<details><summary>정답과 해설</summary>

**A.** 서명 키는 날짜→리전→서비스 순으로 파생되어 범위가 좁혀진다. B: 비밀 키는 절대 전송되지 않는다. C: 서명 시각이 서버 시계와 15분 넘게 차이 나면 거부된다. D: TLS(전송 암호화)와 SigV4(요청자 인증·무결성)는 별개다.
</details>

---

**12.** `aws ec2 describe-instances`가 인스턴스 2만 개를 돌려주다 타임아웃이 난다. 총 결과는 그대로 받되 API 호출 하나당 처리량을 줄이고 싶다. 어떤 옵션인가?

- A. `--max-items 100`
- B. `--page-size 100`
- C. `--no-paginate`
- D. `--query 'Reservations[0:100]'`

<details><summary>정답과 해설</summary>

**B.** `--page-size`는 호출당 개수만 줄이고 CLI가 끝까지 페이지를 따라가므로 총 결과는 같다. A는 결과를 100개로 잘라 버린다. C는 첫 페이지만. D는 받은 뒤 로컬에서 자르는 것이라 서버 호출은 줄지 않는다.
</details>
