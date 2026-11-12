# M08 치트시트 — DNS와 엣지

## Alias vs CNAME

| | CNAME | Alias |
|---|---|---|
| apex(`todayorder.example`) | ❌ | ✅ |
| 대상 | 아무 DNS 이름 | CloudFront, ELB, S3 웹 사이트, API Gateway, Global Accelerator, VPC 인터페이스 엔드포인트, Elastic Beanstalk, 같은 영역의 레코드 (EC2 DNS 이름은 ❌) |
| AWS 리소스로의 쿼리 요금 | 과금 | 무료 |
| TTL | 지정 | 대상의 TTL |
| 건강 연동 | 상태 확인 별도 | `EvaluateTargetHealth` |

**AWS 리소스 이름이면 Alias, apex를 이름에 연결하면 Alias(CNAME 불가), AWS 밖의 이름이면 CNAME.** (apex에 고정 IP A 레코드는 가능)

## 라우팅 정책 8종 — "X가 나오면 Y"

| 요구 사항의 말 | 정책 | 레코드 필드 |
|---|---|---|
| 리소스 하나, 특별한 것 없음 | 단순 | – (상태 확인 불가) |
| N% 카나리, 블루/그린, A/B | 가중치 | `Weight` 0~255 |
| 가장 빠른 리전 | 지연 시간 | `Region` |
| 장애 시 DR/점검 페이지(액티브-패시브) | 장애 조치 | `Failover` + 상태 확인 |
| 이 나라 사용자는 반드시 여기(규정·라이선스·언어) | 지리적 위치 | `GeoLocation` (+ 기본 `*` 필수) |
| 지역 경계를 늘리고 줄이기 | 지리 근접 | `GeoProximityLocation` + `Bias`(−99~99) |
| 건강한 IP 여러 개(최대 8)를 DNS로 | 다중값 응답 | `MultiValueAnswer` + 상태 확인 |
| 이 ISP·회사 IP 대역은 저 엔드포인트로 | IP 기반 | `CidrRoutingConfig` (CIDR 컬렉션) |

- 같은 이름·유형 = 같은 정책. 섞고 싶으면 **Alias 트리**.
- 상태 확인: 엔드포인트(HTTP/HTTPS/TCP) · 계산된(자식 N개) · **CloudWatch 경보 기반(프라이빗 리소스)**.
- 모든 레코드가 비정상이면 Route 53은 모두 정상으로 보고 답한다. 장애 조치에서 PRIMARY·SECONDARY 둘 다 비정상이면 PRIMARY.
- 기본 레코드 없는 지리적 위치 → 일치 없는 사용자는 **빈 응답**.

## CloudFront 한 장

| 필요 | 답 |
|---|---|
| S3를 CloudFront로만 | **OAC** + 버킷 정책(`cloudfront.amazonaws.com`, `AWS:SourceArn`=배포) (OAI는 레거시, SSE-KMS 미지원) |
| 파일 하나 접근 제어 | 서명된 URL |
| 여러 파일, URL 유지 | 서명된 쿠키 |
| 커스텀 도메인 HTTPS | ACM 인증서 **us-east-1** |
| 헤더·리디렉션·캐시 키 정규화 | CloudFront Functions (뷰어 이벤트, <1ms, JS) |
| 외부 호출·본문·오리진 이벤트 | Lambda@Edge (Node.js/Python, 최대 30초, 압축 코드 50 MB, 생성 응답 뷰어 40 KB·오리진 1 MB) |
| 바뀐 파일 즉시 반영 | 무효화 or 버전 붙은 파일 이름 |
| 비용 절감 | 가격 등급 `PriceClass_100/200` |
| 국가 차단 | 지리적 제한(또는 WAF 지역 일치) |
| 오리진 장애 대비 | 오리진 그룹(오리진 장애 조치) |
| 오리진 부하 추가 감소 | Origin Shield |

## CloudFront vs Global Accelerator

| | CloudFront | Global Accelerator |
|---|---|---|
| 프로토콜 | HTTP/HTTPS | TCP/UDP |
| 캐시 | ✅ | ❌ |
| 고정 IP | ❌ | ✅ 애니캐스트 2개 |
| 장애 조치 | 오리진 그룹 | 엔드포인트 그룹 상태 확인·트래픽 다이얼(DNS 캐시 무관) |
| 대표 | 정적 콘텐츠·동영상·웹 가속 | 게임, IoT, VoIP, 허용 목록 IP, 다중 리전 빠른 전환 |

GA API는 **us-west-2**로 호출(`--region us-west-2`). 프리 티어 없음, 가속기 시간당 요금.

## 엣지 보안

| 서비스 | 계층 | 한 줄 |
|---|---|---|
| WAF | L7 | SQLi·XSS·지역·IP·속도 제한. CloudFront·ALB·API GW·AppSync·Cognito 등 (NLB·EC2 ❌). CloudFront용은 `CLOUDFRONT` 범위(us-east-1) |
| Shield Standard | L3/L4 | 자동·무료 |
| Shield Advanced | L3/L4/L7 | 월 정액·1년 약정, SRT 24시간, 비용 보호 |
| Firewall Manager | 관리 | 여러 계정에 WAF·Shield·SG·Network Firewall·DNS Firewall 정책 일괄 적용 (Organizations 필요) |

- WAF 규칙은 **우선순위 숫자 작은 것부터**, 기본 동작은 Allow 또는 Block. 속도 기반 규칙 한도 최솟값 10, 평가 창 60/120/300/600초.
- 관리형 규칙 오탐 → 그 하위 규칙만 Count로 재정의.

## 에뮬레이터에서 기억할 것

- `dig` 불가 → `aws route53 test-dns-answer`. 상태 확인은 항상 Success.
- CloudFront·ALB 주소는 컨테이너 안 → `docker exec aws-emulator-$EMULATOR_PORT curl …`.
- WAF 차단은 컨테이너 안 ALB에서 실제로 관찰된다.
