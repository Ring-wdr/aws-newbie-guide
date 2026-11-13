# M08. DNS와 엣지

> 시나리오: TodayOrder에 해외 사용자가 생겼다. 미국·일본에서 "느리다", 보안팀에서 "로그인 API에 봇이 붙었다"는 연락이 온다. 이름(DNS)으로 트래픽을 나누고, 엣지(CloudFront·Global Accelerator)로 가까이 가져가고, 엣지에서 공격을 거른다.
> 도메인: D2, D3 (+ D1 엣지 보안) · 예상 시간: 약 4시간

## 목표

- Route 53 호스팅 영역·레코드를 만들고, **Alias와 CNAME**의 차이를 설명할 수 있다.
- 라우팅 정책 8종(단순·가중치·지연 시간·장애 조치·지리적 위치·지리 근접·다중값 응답·IP 기반)을 요구 사항에 맞게 고르고, 상태 확인과 엮어 "어느 레코드가 답하나"를 손으로 판정할 수 있다.
- CloudFront 배포를 S3 오리진 + OAC로 구성하고, 캐시·서명된 URL·엣지 함수의 쓰임을 구분할 수 있다.
- CloudFront와 Global Accelerator 중 무엇을 쓸지 결정할 수 있다.
- WAF Web ACL을 구성하고 Shield·Firewall Manager의 역할을 구분할 수 있다.

## 레슨

| # | 레슨 | 시간 | 등급 |
|---|---|---|---|
| 1 | [DNS 기초와 Route 53 (호스팅 영역, 레코드, Alias vs CNAME, TTL)](./01-dns-and-route53.md) | 45분 | 🟢 |
| 2 | [라우팅 정책 8종과 상태 확인](./02-routing-policies-and-health-checks.md) | 60분 | 🟢 / 🟡 / 🔴 |
| 3 | [CloudFront — 오리진, 캐시, OAC, 서명된 URL, 엣지 함수](./03-cloudfront.md) | 55분 | 🟡 |
| 4 | [Global Accelerator vs CloudFront](./04-global-accelerator-vs-cloudfront.md) | 30분 | 🟡 |
| 5 | [엣지 보안 — WAF, Shield, Firewall Manager](./05-edge-security.md) | 45분 | 🟢 / 🔴 |

## 실습

| 실습 | 스크립트 | 레슨 | 등급 |
|---|---|---|---|
| 호스팅 영역·레코드 CRUD, apex CNAME 거부, Alias, 프라이빗 영역 | [labs/lab01-hosted-zone-records.sh](./labs/lab01-hosted-zone-records.sh) | 1 | 🟢 |
| 라우팅 정책 레코드(장애 조치 외 7종)와 `test-dns-answer` | [labs/lab02-routing-policies.sh](./labs/lab02-routing-policies.sh) | 2 | 🟢 레코드·단순·가중치·다중값 / 🟡 지연 시간·지리적 위치·지리 근접·IP 기반의 응답 선택 |
| 상태 확인·장애 조치 레코드 (+ 레슨 2 워크시트) | [labs/lab03-health-check-failover.sh](./labs/lab03-health-check-failover.sh) | 2 | 🔴 동작(상태 확인이 항상 성공) · 구성은 가능 |
| CloudFront 배포 + S3 오리진 + OAC, 캐시, 무효화 | [labs/lab04-cloudfront-oac.sh](./labs/lab04-cloudfront-oac.sh) | 3 | 🟡 (배포 GET은 docker exec 선택 과제) |
| Global Accelerator 가속기·리스너·엔드포인트 그룹 | [labs/lab05-global-accelerator.sh](./labs/lab05-global-accelerator.sh) | 4 | 🟡 |
| WAF Web ACL + ALB 연결, 차단 관찰, Shield·FMS 상태 | [labs/lab06-waf-web-acl.sh](./labs/lab06-waf-web-acl.sh) | 5 | 🟢 구성 · 차단(docker exec 선택 과제) / 🔴 Shield Advanced·FMS |
| boto3: 가중치로 카나리 배포 | [sdk/weighted_canary.py](./sdk/weighted_canary.py) | 2 | 🟢 |
| boto3: 레코드를 읽어 라우팅 정책 판정 | [sdk/routing_policy_inventory.py](./sdk/routing_policy_inventory.py) | 2 | 🟢 |

전부 한 번에 검증:

```bash
export EMULATOR_PORT=9297          # 대화형 터미널이면 생략 가능
curriculum/m08-dns-edge/labs/verify.sh
```

`verify.sh`는 에뮬레이터를 재시작해 깨끗한 상태로 만든 뒤 sdk 예제의 안전 장치를 확인하고, 모든 lab을 **두 번** — 1회차는 번호 순, 2회차는 역순 — 실행하고(멱등성·순서 무관성) sdk 예제를 실행한다. 마지막 줄이 `MODULE m08 OK`면 통과. lab02는 `test-dns-answer`를 여러 번 호출하므로 1~2분 걸린다. lab04·lab06의 "컨테이너 안에서 GET" 부분은 `docker exec`를 쓰며, docker를 쓸 수 없는 환경에서는 그 부분만 건너뛴다.

`labs/_lib.sh`는 lab들이 함께 쓰는 도우미(단언, 폴링, JSON 가공, 영역 정리)다. 단독으로 실행하지 않는다.

정리 자료: [cheatsheet.md](./cheatsheet.md) · [quiz.md](./quiz.md)

## 에뮬레이터 제약

에뮬레이터 1.0.322, 포트 9308에서 직접 실행해 확인했다.

| 오퍼레이션 / 동작 | 증상 | 실습에서의 처리 |
|---|---|---|
| Route 53 상태 확인 | 대상을 검사하지 않고 8개 지역 모두 항상 `Success: HTTP Status Code 200, OK`. 존재할 수 없는 `.invalid` 도메인도, `Inverted=true`도 마찬가지 | 장애 조치 동작 🔴. PRIMARY 레코드를 지워 "장애 조치 후 답"을 흉내 내고, 판정은 워크시트로 |
| `TestDNSAnswer` — 지연 시간·지리적 위치·지리 근접·IP 기반 | 질의자 IP(`--resolver-ip`, `--edns0-client-subnet-*`)와 무관한 답: 지리적 위치는 항상 기본(`*`), 지리 근접은 항상 첫 레코드, IP 기반은 항상 기본 위치, 지연 시간은 리졸버 IP를 주면 첫 레코드(이름순)·안 주면 us-east-1 레코드 | 레코드 구성 🟢, 응답 선택 🟡. 판정은 워크시트로 |
| `TestDNSAnswer` — Alias(CloudFront 대상) | IP가 아니라 대상 DNS 이름(`d111111abcdef8.cloudfront.net.`)을 돌려줌 | 레슨 1에 명시 |
| `TestDNSAnswer` — 프라이빗 호스팅 영역 | `InvalidInput`(퍼블릭 영역 전용) — 실제 AWS와 같은 제약 | 레코드 목록으로 확인 |
| 같은 이름·유형에 서로 다른 라우팅 정책 | 받아 준다(실제 AWS는 거부) | lab02 9단계에서 관찰 후 삭제 |
| `ChangeCidrCollection`, `ListCidrCollections`, `ListCidrBlocks`, `ListCidrLocations` | `501 NotImplemented` (`CreateCidrCollection`과 `CidrRoutingConfig` 레코드 생성은 동작) | IP 기반 레코드는 기본 위치(`*`)만 |
| 실제 DNS 질의 | 컨테이너가 53번 포트를 열지 않아 `dig` 불가 | `test-dns-answer` 사용 |
| CloudFront `DomainName` | `*.cloudfront.net`이 아니라 컨테이너 안 주소 `127.0.0.1:<임의 포트>`. 호스트에서 접속 불가 | 배포 GET은 `docker exec` 선택 과제 |
| CloudFront `DefaultRootObject` | `/` 요청에 `index.html` 대신 버킷 목록 XML을 돌려줌(`s3:GetObject`만 허용한 정책에서도) | 레슨 3 "실제 AWS에서는"에 기록, 실습은 `/index.html`로 |
| CloudFront `TestFunction` | `501 NotImplemented` | 함수 생성까지만 |
| Global Accelerator `ListEndpointGroups` | `501 NotImplemented` | 생성 시 받은 ARN으로 정리 |
| Global Accelerator 트래픽·상태 확인 | 정적 IP는 198.18.0.x(벤치마크 예약 대역), 엔드포인트 `HealthState`는 `INITIAL`에 머묾 | 구성 🟡 |
| WAF IP 세트 규칙 | `IPSetForwardedIPConfig`가 없어도 `X-Forwarded-For`를 클라이언트 IP로 취급 | 실습 규칙에 `IPSetForwardedIPConfig`를 넣어 실제 AWS와 같은 의미로 작성 |
| WAF 속도 기반 규칙 | 한도를 정확히 지킴(실제 WAF는 근사치·지연 있음) | 단언은 "일부 차단됨"으로 느슨하게 |
| Firewall Manager | 관리자 계정이 없어 `AccessDeniedException` | 🔴 개념 |

## 설계 대비 대체 사유

CURRICULUM.md의 M08 실습을 모두 구현했고, 확인 결과에 따라 등급을 다음과 같이 확정했다.

- **WAF Web ACL: 🟡 → 🟢(구성)**. CURRICULUM은 "저장만, 차단은 시험 안 함"이었으나, 이 버전은 ALB에 연결한 Web ACL이 IP 세트·SQLi·XSS·User-Agent 없음·속도 기반 규칙으로 **실제로 403 차단**하고 `get-sampled-requests`에 막은 규칙이 나온다. 다만 ALB 주소가 컨테이너 안에만 있으므로 차단 관찰은 AUTHORING 3장 9항에 따라 `docker exec` 선택 과제로 두었다. (재생성된 FIDELITY.md의 `edge-better` 탐침도 ALB 앞 WAF의 실제 403 차단을 확인한다.)
- **가중치·지연 시간 레코드와 `test-dns-answer` (🟢)**: 가중치·단순·다중값의 응답은 🟢로 확정. 지연 시간(및 지리적 위치·지리 근접·IP 기반)은 레코드는 🟢지만 응답이 위치를 따르지 않으므로 응답 선택을 🟡로 내리고 워크시트로 보충했다.
- **상태 확인·장애 조치 🔴**: 그대로. 워크시트(레슨 2, 정답 포함)와 "PRIMARY 삭제로 흉내 내기"로 대체.
- **CloudFront 🟡**: 그대로. 컨테이너 안에서는 OAC(정책 없음 403 → 정책 후 200)와 캐시 Miss→Hit까지 실제로 관찰된다.
- **Global Accelerator 🟡**: 그대로. 실제 AWS와 같은 명령이 되도록 GA 호출에만 `--region us-west-2`를 붙였다.
- 추가: Shield Advanced 구독 상태·Firewall Manager 읽기(레슨 5), sdk 예제 2개.
