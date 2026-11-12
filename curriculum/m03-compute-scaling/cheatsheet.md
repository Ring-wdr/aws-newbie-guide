# M03 치트시트

## 인스턴스 패밀리

| 요구 | 패밀리 | 예 |
|---|---|---|
| 평소 한가, 가끔 바쁨 (CPU 크레딧) | **T** | t3, t4g |
| 무난한 웹·API | **M** | m7i, m7g |
| CPU 병목 (배치·인코딩·게임) | **C** | c7i, c7g |
| 메모리 병목 (캐시·큰 DB) | **R / X** | r7i, x2idn |
| 고속 로컬 NVMe I/O | **I / D** | i4i, d3 |
| GPU·ML | **P / G / Inf / Trn** | p5, g6, inf2 |
| 같은 성능 더 싸게 | **Graviton(`g`)** — arm64 AMI 필요 | m7g, c7g |

`m7i.large` = 패밀리 m · 세대 7 · 속성 i(Intel) · 크기 large. 같은 large(2 vCPU)에서 메모리 C:M:R = 4:8:16 GiB.

## 구매 옵션 결정 표

| 조건 | 답 |
|---|---|
| 중단돼도 됨, 가장 저렴 | **스팟** (최대 90%, 2분 전 알림) |
| 짧다·예측 불가·약정 싫음 | **온디맨드** (초 단위 과금, 최소 60초) |
| 1년+ 꾸준, 패밀리·리전·서비스 바뀔 수 있음 (Fargate·Lambda 포함) | **Compute Savings Plans** (최대 66%) |
| 1년+ 꾸준, 한 리전·한 패밀리 | **EC2 Instance Savings Plans / Standard RI** (최대 72%) |
| 기간 중 유형 교환 필요 | **Convertible RI** (최대 66%) |
| 안 쓰게 된 RI 팔기 | **Standard RI → RI 마켓플레이스** |
| 특정 AZ 용량 보장, 약정 없이 | **온디맨드 용량 예약(ODCR)** (안 써도 과금, 할인 없음) |
| 할인 + 특정 AZ 용량 | **영역(AZ) RI** 또는 ODCR + Savings Plans |
| 소켓·코어 BYOL, 물리 서버 가시성 | **전용 호스트** |
| 하드웨어만 다른 고객과 분리 | **전용 인스턴스** |

결제: All Upfront > Partial > No Upfront 순으로 쌈. 3년 > 1년.

## EBS 유형

| 유형 | 크기 | 최대 IOPS / 처리량 | 핵심 | 이럴 때 |
|---|---|---|---|---|
| **gp3** | 1 GiB–64 TiB | 80,000 / 2,000 MiB/s | 기본 3,000 IOPS·125 MiB/s, 성능을 크기와 별도로 | **기본값** |
| gp2 | 1 GiB–16 TiB | 16,000 / 250 MiB/s | 3 IOPS/GiB, 버스트 | 기존 볼륨 → gp3로 |
| **io2 BE** | 4 GiB–64 TiB | 256,000 / 4,000 MiB/s | 99.999%, sub-ms, 1000:1, 다중 연결 | 핵심 DB |
| io1 | 4 GiB–16 TiB | 64,000 / 1,000 MiB/s | 50:1, 다중 연결 | 기존 |
| **st1** | 125 GiB–16 TiB | 500 / 500 MiB/s | 순차 처리량, 부트 불가 | 로그·빅데이터 |
| **sc1** | 125 GiB–16 TiB | 250 / 250 MiB/s | 가장 쌈, 부트 불가 | 콜드 데이터 |
| 인스턴스 스토어 | 유형에 고정 | 매우 빠름 | **중지·종료·고장 시 소멸** | 캐시·스크래치 |

- 볼륨 = **AZ 리소스**. 다른 AZ/리전 → 스냅샷(→ 복사) → 새 볼륨.
- 기존 볼륨 암호화 = 스냅샷 → **암호화 복사** → 새 볼륨. 앞으로 전부 = **EBS 기본 암호화**(리전별).
- 크기·유형·IOPS 변경은 **무중단**(Elastic Volumes). 크기는 **늘리기만**.
- 다중 연결 = io1/io2, 같은 AZ, 클러스터 인식 FS 필요. 파일 공유는 EFS.

## 배치 그룹 · ENI · EIP · 최대 절전

| | 핵심 |
|---|---|
| 클러스터 | 한 AZ, 최저 지연·최고 대역폭, HPC. T 유형 불가 |
| 파티션 | 랙 묶음 분리, **AZ당 7 파티션**, HDFS·Cassandra·Kafka |
| 분산 | 인스턴스마다 다른 랙, **AZ당 7대**, 소수 핵심 서버 |
| ENI | 서브넷(AZ) 리소스. 보조 ENI를 옮기면 **IP·MAC 유지** |
| EIP | 고정 공인 IPv4, 재연결로 장애 조치. 모든 공인 IPv4 **시간당 과금**(2024-02~) |
| 최대 절전 | **시작 시에만** 활성화, **암호화된 EBS 루트**, RAM < 150 GiB(Linux), RAM → EBS |

## 로드 밸런서

| | ALB | NLB | GWLB |
|---|---|---|---|
| 계층 | L7 HTTP/HTTPS/gRPC | L4 TCP/UDP/TLS | L3 (GENEVE 6081) |
| 특징 | 경로·호스트·헤더 라우팅, Lambda 대상, WAF | **고정 IP/EIP**, 초저지연, 클라이언트 IP 보존, ALB 대상 | 방화벽 어플라이언스 삽입 |
| 교차 영역 기본 | 켜짐 | 꺼짐 | 꺼짐 |

- 규칙: 작은 우선순위 먼저, 없으면 default. 동작 = forward / redirect / fixed-response / authenticate.
- 등록 취소 지연(연결 드레이닝) 기본 300초. 스티키 세션 = `lb_cookie`/`app_cookie`(근본 해결은 세션 외부화).
- 클라이언트 IP(ALB 뒤) = `X-Forwarded-For`. HTTPS = ACM 인증서, 여러 도메인 = SNI.

## Auto Scaling

| 정책 | 언제 |
|---|---|
| **대상 추적** | 기본 선택. CPU·대상당 요청 수 유지 |
| 단계 | 초과 폭에 따라 다르게 (임계값 기준 상대 구간) |
| 단순 | 레거시, 쿨다운(기본 300초) |
| **예약** | 예측 가능한 시각 (cron + 시간대) |
| **예측** | 반복 패턴 + 느린 부팅 → 미리 확장 |

- 여러 정책 → **가장 큰 용량**. 근사식(대상 추적): ⌈현재 × 지표 ÷ 목표⌉, min/max로 자름.
- `PercentChangeInCapacity` 반올림: >1 내림, 0~1 → 1, `MinAdjustmentMagnitude` 우선.
- 헬스 체크 **EC2**(인스턴스 상태) vs **ELB**(앱까지). 유예 기간.
- 수명 주기 후크 = Pending:Wait / Terminating:Wait. 인스턴스 새로 고침 = 롤링 교체. 웜 풀 = 빠른 확장.
- 기본 종료 정책: AZ 균형 → 오래된 설정(시작 구성 → 다른 템플릿 → 오래된 버전) → 과금 시간.
- EC2 Auto Scaling(ASG) · **Application Auto Scaling**(ECS·DynamoDB·Aurora·Lambda 동시성) · AWS Auto Scaling(조정 계획).

## 그 밖의 컴퓨트

| 요구 | 답 |
|---|---|
| 코드만 올리면 EC2·ASG·ELB 구성, 제어권 유지 | Elastic Beanstalk (Immutable·블루/그린이 안전) |
| 월 정액 단순 VPS | Lightsail |
| 대량·장시간 배치, 스팟 | AWS Batch |
| 온프레미스에 AWS 인프라 | Outposts |
| vSphere 그대로 | VMware Cloud on AWS |
| 서버리스 앱 공유·배포 | Serverless Application Repository |

## 에뮬레이터에서 자주 쓴 명령

```bash
aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text
aws ec2 run-instances --image-id <ami> --instance-type t3.micro --subnet-id <subnet> --metadata-options HttpTokens=required
aws ec2 describe-instances --instance-ids <id> --query 'Reservations[0].Instances[0].State.Name'
aws ec2 wait instance-running --instance-ids <id>
aws ec2 create-volume --availability-zone us-east-1a --volume-type gp3 --size 20
aws ec2 modify-volume --volume-id <vol> --volume-type gp3 --size 40
aws elbv2 describe-target-health --target-group-arn <tg>
aws autoscaling set-desired-capacity --auto-scaling-group-name <asg> --desired-capacity 4
aws autoscaling start-instance-refresh --auto-scaling-group-name <asg>
aws autoscaling put-scaling-policy --cli-input-json file://policy.json   # 에뮬레이터: 501 = 모양 통과
docker exec aws-emulator-$EMULATOR_PORT curl -s http://<ALB DNSName>/ping   # ALB는 컨테이너 안에서만
```
