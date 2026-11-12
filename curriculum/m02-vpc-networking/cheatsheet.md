# M02 치트시트

## CIDR 한눈에

| 접두사 | 주소 수 | AWS에서 쓸 수 있는 수 (−5) | 비고 |
|---|---|---|---|
| /16 | 65,536 | 65,531 | VPC 최대 크기 |
| /20 | 4,096 | 4,091 | 기본 VPC의 서브넷 크기 |
| /22 | 1,024 | 1,019 | |
| /23 | 512 | 507 | "호스트 500개" → /23 |
| /24 | 256 | 251 | 가장 흔한 서브넷 |
| /26 | 64 | 59 | |
| /27 | 32 | 27 | |
| /28 | 16 | 11 | VPC·서브넷 최소 크기 |

- 주소 수 = 2^(32 − 접두사). 접두사가 1 커지면 반으로 준다.
- 예약 5개(서브넷마다): 네트워크 주소(.0), VPC 라우터(.1), DNS(.2), 예비(.3), 마지막(브로드캐스트 자리).
- RFC 1918 사설 대역: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`. (기본 VPC는 `172.31.0.0/16`)
- VPC 주 CIDR은 바꿀 수 없다 → 보조 CIDR 추가(기본 할당량 VPC당 5개, 최대 50까지 조정 가능).
- 피어링·TGW·VPN으로 이을 네트워크끼리는 **CIDR이 겹치면 안 된다** (피어링은 생성 단계에서 `failed`).

## "퍼블릭 서브넷"의 정의

> 서브넷에 **적용되는** 라우팅 테이블에 `0.0.0.0/0 → igw-…` 경로가 있으면 퍼블릭 서브넷이다.
> 이름도, "퍼블릭 IP 자동 할당" 설정도 아니다. 명시적 연결이 없으면 VPC의 **기본(main) 라우팅 테이블**이 적용된다.

인터넷과 직접 통신하려면 ① IGW가 VPC에 연결 ② 라우팅 테이블에 IGW 경로 ③ 인스턴스에 퍼블릭 IP/EIP ④ SG·NACL 허용 — 넷 다 필요.

## 경로 선택

- **최장 접두사 일치**: 목적지에 일치하는 경로 중 접두사가 가장 긴 것. `10.0.0.0/16 → local`이 `0.0.0.0/0`을 이긴다. 게이트웨이 엔드포인트의 prefix list 경로도 `0.0.0.0/0 → NAT`보다 구체적이라 S3 트래픽을 가져간다.
- `local` 경로는 지울 수 없다. VPC 안 서브넷끼리는 항상 라우팅된다(막는 것은 SG·NACL의 몫).

## 게이트웨이·NAT 선택

| 요구 | 답 |
|---|---|
| 인터넷 양방향(ALB, 공개 웹) | IGW + 퍼블릭 서브넷 |
| 프라이빗 서브넷의 IPv4 아웃바운드만 | NAT 게이트웨이(퍼블릭 서브넷에, EIP) |
| 프라이빗 서브넷의 **IPv6** 아웃바운드만 | **Egress-only IGW** |
| NAT 고가용성 | AZ마다 NAT GW + AZ별 라우팅 테이블 (또는 리전 NAT 게이트웨이) |
| 관리 부담 최소, 대역폭 큰 NAT | NAT 게이트웨이 (5 Gbps에서 100 Gbps까지 자동 확장) |
| 아주 작은 비용, 직접 관리 OK, 포트 포워딩·배스천 겸용 | NAT 인스턴스 (소스/대상 확인 끄기) |
| 다른 VPC·온프렘으로 나갈 때 IP 겹침 해결용 NAT | 프라이빗 NAT 게이트웨이(zonal) |

## 보안 그룹 vs 네트워크 ACL

| | 보안 그룹(SG) | 네트워크 ACL |
|---|---|---|
| 적용 단위 | ENI(인스턴스·ALB·RDS 등) | 서브넷 |
| 상태 | **상태 저장** — 응답은 자동 허용 | **상태 비저장** — 응답 방향(임시 포트 1024-65535)도 규칙 필요 |
| 규칙 | Allow만 | Allow와 **Deny** |
| 평가 | 모든 규칙을 합쳐서 판단 | **번호 작은 것부터**, 처음 일치하는 규칙에서 멈춤 |
| 출처 | CIDR, prefix list, **다른 SG ID** | CIDR만 |
| 기본값 | 새 SG: 인바운드 없음·아웃바운드 전체 허용 | 기본 NACL: 전부 허용 / 새 NACL: 전부 거부 |
| 한계(기본) | SG당 인바운드·아웃바운드 각 60, ENI당 SG 5개(최대 16) | NACL당 방향별 20(최대 40), 규칙 번호 1~32766 |
| 시험 신호 | "특정 SG에서 오는 것만", "체이닝" | "특정 IP를 **차단**", "서브넷 전체" |

## VPC 엔드포인트

| | 게이트웨이 엔드포인트 | 인터페이스 엔드포인트(PrivateLink) |
|---|---|---|
| 대상 | **S3, DynamoDB만** | 대부분의 AWS 서비스(S3·DynamoDB 포함), 다른 계정의 엔드포인트 서비스(NLB/GWLB 뒤) |
| 방식 | 라우팅 테이블에 prefix list 경로 | 서브넷에 ENI(사설 IP) + 사설 DNS |
| 보안 | 엔드포인트 정책 | 엔드포인트 정책 + **보안 그룹** |
| 비용 | 무료 | 시간당 + 처리 GB |
| 온프렘·피어 VPC에서 사용 | 불가 | 가능(VPN/DX/TGW로 ENI IP에 도달) |

S3 버킷 정책에서 `aws:SourceVpce`(특정 엔드포인트) / `aws:SourceVpc` 조건으로 "엔드포인트로만 접근"을 강제한다.

## 연결 선택

| 요구 | 답 |
|---|---|
| VPC 2~3개, 단순·저렴, 대역폭 제한 없음 | VPC 피어링 (전이적 라우팅 없음, CIDR 겹침 불가, 리전·계정 간 가능) |
| VPC 수십 개 + 온프렘, 허브·스포크, 전이적 라우팅 | Transit Gateway |
| 온프렘 ↔ VPC를 빨리, 인터넷 위로 암호화 | Site-to-Site VPN (터널 2개, 표준 터널당 최대 1.25 Gbps, 대역폭 큰 터널은 5 Gbps — TGW·Cloud WAN 연결에서만) |
| VPN 대역폭을 늘리고 싶다 | TGW + VPN + ECMP(동적 라우팅·BGP 필요) |
| 직원 노트북 → VPC | Client VPN |
| 일정한 대역폭·낮은 지연, 인터넷 안 거침 | Direct Connect (전용 1/10/100/400 Gbps, 호스티드 50 Mbps~25 Gbps). 개통에 수 주 |
| DX인데 암호화 필요 | DX 위에 VPN(IPsec) 또는 MACsec(전용 연결) |
| DX 장애 대비를 싸게 | DX(주) + Site-to-Site VPN(백업) |
| DX 하나로 여러 리전 VPC | Direct Connect Gateway |
| 내 서비스를 다른 VPC/계정에 노출(CIDR 겹쳐도 됨) | PrivateLink(엔드포인트 서비스) |

## 관측·방어

| 요구 | 답 |
|---|---|
| 누가 어디로 접속했나(ACCEPT/REJECT, 5-튜플) | VPC Flow Logs → CloudWatch Logs / S3 / Data Firehose (패킷 내용은 없음) |
| 도메인·IPS 기반 VPC 경계 필터링 | AWS Network Firewall |
| L7 웹 공격(SQLi, XSS), 속도 제한 | AWS WAF (ALB·CloudFront·API Gateway에) — M08/M09 |
| SSH 포트 없이 인스턴스 셸 접속, 감사 로그 | Systems Manager Session Manager |
| 배스천(점프) 호스트 | 퍼블릭 서브넷의 인스턴스, SG로 22번을 회사 IP만 — 관리할 서버·키가 늘어난다 |

## 에뮬레이터에서 볼 수 없는 것 (lab10)

Egress-only IGW · 리전 NAT 게이트웨이 · 피어링 수락/삭제 · Site-to-Site VPN 연결 · VGW 경로 전파 · Client VPN · TGW 정적 경로/경로 검색/연결 삭제 · `ReplaceRoute` · Session Manager — 모두 501. 그리고 **패킷 자체가 흐르지 않는다.**

## 자주 쓰는 명령

```bash
# 서브넷에 실제로 적용되는 라우팅 테이블 (없으면 main 을 찾는다)
aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=<subnet-id>
aws ec2 describe-route-tables --filters Name=vpc-id,Values=<vpc-id> Name=association.main,Values=true
# 서브넷 사용 가능 IP
aws ec2 describe-subnets --subnet-ids <id> --query 'Subnets[0].AvailableIpAddressCount'
# SG 규칙 (참조 SG 포함)
aws ec2 describe-security-group-rules --filters Name=group-id,Values=<sg-id>
# NACL 규칙을 번호 순으로
aws ec2 describe-network-acls --network-acl-ids <acl> --query 'sort_by(NetworkAcls[0].Entries,&RuleNumber)'
# 기다리기
aws ec2 wait vpc-available --vpc-ids <id>
aws ec2 wait nat-gateway-available --nat-gateway-ids <id>
```
