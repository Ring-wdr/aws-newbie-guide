# M14 치트시트 — "요구 사항 → 서비스" 통합판 (시험 도메인별)

> M00~M13 치트시트의 비교표를 한 장으로 모았다. 표 끝의 `Mxx`는 자세한 설명이 있는 모듈이다.
> 수치는 2026-11 기준이며 자주 바뀐다. 모듈 사이에 표현이 달랐던 곳은 맨 아래 "정리한 불일치"에 근거와 함께 적었다.

## 문제 푸는 순서 (모든 도메인 공통)

1. **무엇을 최적화하라는가** — "가장 안전한 / 가용성이 가장 높은 / 성능이 가장 좋은 / 가장 비용 효율적인 / **운영 부담이 가장 적은**". 하나만 최적화하고 나머지는 "만족하면 됨".
2. **숫자·제약에 밑줄** — RTO·RPO, 지연(ms/µs), 보존 기간, 검색 시간, "중단돼도 됨", "코드 변경 최소", "기존 X 유지".
3. **제약을 깨는 보기 삭제** — 가장 싼 보기가 제약을 깨는 경우가 많다(M13).
4. 남은 것 중 **관리형·서버리스·자동화** 쪽으로 기운다(운영 부담).

---

## D1. 보안 아키텍처 (30%)

### 누가 접근하나 (M01, M07)

| 요구 | 답 | 아닌 것 |
|---|---|---|
| 직원 여러 명 × 계정 여러 개, 사내 IdP로 SSO | **IAM Identity Center** + 권한 세트 | 계정마다 IAM 사용자 |
| EC2·Lambda·ECS가 AWS 호출 | **역할**(인스턴스 프로파일·실행 역할·태스크 역할) | 액세스 키를 코드·사용자 데이터에 |
| CI/CD(GitHub Actions 등) | **OIDC 공급자 + `AssumeRoleWithWebIdentity`** | 장기 키를 저장소 비밀에 |
| 다른 계정의 리소스 | 상대 계정 **역할 맡기**(양쪽 허용) | |
| 제3자 업체 | 교차 계정 역할 + **외부 ID** | IAM 사용자 키 전달 |
| 앱 고객 가입·로그인(JWT) | **Cognito 사용자 풀** | Identity Center(직원용) |
| 앱 고객이 S3 등을 **직접** 호출 | **Cognito 자격 증명 풀**(임시 자격 증명, 정책 변수 `${cognito-identity.amazonaws.com:sub}`) | 앱에 키 내장 |
| 멤버 계정 전체의 상한(리전·서비스 금지), 루트 포함 | **SCP**(권한을 주지 않음, 관리 계정 제외) | IAM 정책·Config |
| 개발자가 만드는 역할의 상한 | **권한 경계** + `iam:PermissionsBoundary` 조건 | |
| 다계정 랜딩 존·가드레일 자동화 | **Control Tower** | |
| 서브넷·TGW 등을 다른 계정과 공유 | **AWS RAM**(VPC 공유) | 교차 계정 역할로 대신 생성 |
| 사내 AD로 AWS 앱 로그인(데이터는 온프레미스 AD) | **AD Connector** / AWS에 진짜 AD는 **Managed Microsoft AD** / 작고 싼 것 **Simple AD** | |

평가: **명시적 Deny > Allow > 암묵적 Deny**. 최종 = SCP ∩ (자격 증명 정책 ∪ 리소스 정책) ∩ 권한 경계 ∩ 세션 정책. 교차 계정은 양쪽 모두 허용 필요.

### 네트워크 보안 (M02, M08, M09)

| 요구 | 답 |
|---|---|
| 특정 IP 대역 **차단**, 서브넷 단위 | **NACL**(상태 비저장, 번호 순, Deny 가능) |
| "특정 SG에서 오는 것만", 체이닝 | **보안 그룹**(상태 저장, Allow만, SG 참조) |
| 프라이빗 서브넷 → S3·DynamoDB, 인터넷 없이 | **게이트웨이 엔드포인트**(무료) + 버킷 정책 `aws:SourceVpce` |
| 프라이빗 → 그 밖의 AWS 서비스 / 온프레미스에서 사설로 | **인터페이스 엔드포인트(PrivateLink)** |
| 내 서비스를 다른 VPC·계정에 노출, CIDR 겹쳐도 | **PrivateLink 엔드포인트 서비스(NLB 뒤)** |
| 22번 포트·배스천 없이 셸 + 세션 기록 | **Session Manager** |
| SQLi·XSS·속도 제한·지역 차단(L7) | **WAF**(CloudFront·ALB·API Gateway REST·AppSync·Cognito) — NLB·EC2 ❌ |
| DDoS 자동 방어 / + 비용 보호·대응팀 | **Shield Standard**(무료) / **Shield Advanced** |
| VPC 경계 IPS·도메인 허용 목록 | **Network Firewall** |
| 여러 계정에 WAF·SG·Network Firewall 정책 일괄 | **Firewall Manager**(Organizations 필요) |
| 온프레미스 ↔ VPC 빨리, 암호화 | **Site-to-Site VPN** / 직원 노트북 → **Client VPN** |
| DX 위 암호화 | **DX 위 IPsec VPN** 또는 **MACsec**(전용 연결) |

### 데이터 보호 (M04, M05, M09, M12)

| 요구 | 답 |
|---|---|
| 기본 암호화, 추가 작업 없음 | SSE-S3 |
| 키 사용 감사·비활성화·권한 분리 | **SSE-KMS 고객 관리형 키** (대량이면 **S3 버킷 키**) |
| 키를 AWS에 맡기지 않음 | SSE-C(2026-04부터 새 버킷 기본 차단) / **클라이언트 측 암호화** |
| 단일 테넌트 HSM, 고객 단독 키 통제 | **CloudHSM** (KMS의 HSM도 FIPS 140-3 Level 3 — 차이는 "전용·단독 통제") |
| 4 KB 넘는 데이터를 KMS로 | **봉투 암호화**(`GenerateDataKey`) |
| 다른 리전에서 재암호화 없이 복호화 | **KMS 다중 리전 키** |
| 기존 비암호화 RDS·EBS | 스냅샷 → **암호화 복사** → 복원 / EBS는 **기본 암호화**(앞으로 만들 것) |
| DB 암호 자동 교체 | **Secrets Manager**(교체, RDS 관리형 암호) / 교체 없는 설정·SecureString은 **Parameter Store** |
| 공인 인증서 무료·자동 갱신 | **ACM**(가져온 인증서는 자동 갱신 ❌). **CloudFront용은 us-east-1** |
| HTTPS 강제(S3) | 버킷 정책 Deny `aws:SecureTransport=false` |
| WORM, 루트도 못 지움 | **S3 객체 잠금 규정 준수 모드** / 백업은 **Backup Vault Lock 규정 준수 모드** |
| 권한자만 해제 가능한 WORM / 기한 없는 보존 | 거버넌스 모드 / **법적 보존** |
| 실수 삭제·덮어쓰기 복구 | **버전 관리**(+ MFA Delete) |
| 데이터 레이크 열·행 단위 권한 | **Lake Formation** |
| 비공개 객체를 잠깐 공유·직접 업로드 | **presigned URL** |

### 탐지·감사 (M09)

| 요구 | 답 |
|---|---|
| 위협·침해(채굴, 비정상 API, 악성 IP) | **GuardDuty** |
| 소프트웨어 취약점(CVE)·네트워크 노출 | **Inspector**(EC2·ECR·Lambda) |
| S3의 민감 데이터(PII) | **Macie** |
| 결과 모으기 + 표준 준수 점수 | **Security Hub** |
| 결과의 원인·범위 조사 | **Detective** |
| 누가 어떤 API를(90일 무료 / 장기·조직·무결성) | **CloudTrail** 이벤트 기록 / **추적 → S3**(멀티 리전, 무결성 검증) |
| 구성 이력 + 규칙 준수 + 자동 수정 | **Config**(+ SSM Automation) |
| 내 감사 증거 수집 / AWS의 규정 준수 보고서 | **Audit Manager** / **Artifact** |

---

## D2. 복원력 있는 아키텍처 (26%)

### 결합 끊기 (M06, M07)

| 요구 | 답 | 아닌 것 |
|---|---|---|
| 생산자·소비자 분리, 트래픽 버퍼, 유실 금지 | **SQS** | SNS(보관 안 함) |
| 순서 + 중복 제거(그룹 단위 병렬) | **SQS FIFO** + 메시지 그룹 ID | 표준 큐 |
| 한 이벤트 → 여러 시스템이 각자 | **SNS → 소비자별 SQS**(팬아웃, 필터 정책) | 큐 하나 공유(=분배) |
| 내용 기반 라우팅, SaaS·AWS 이벤트, 아카이브·재생 | **EventBridge** | |
| cron·일회성 일정 | **EventBridge Scheduler** | EC2 cron |
| 소스 하나 → 대상 하나 코드 없이 | **EventBridge Pipes** | |
| 여러 단계·재시도·분기·사람 승인(최대 1년) | **Step Functions 표준**(`.waitForTaskToken`) | Lambda 안 sleep |
| 짧고 대량(최대 5분) | **Step Functions 익스프레스** | |
| 기존 JMS/AMQP/MQTT 브로커 이전 | **Amazon MQ** | SQS(코드 수정) |
| 기존 Kafka | **MSK** | |
| SaaS ↔ AWS 데이터 이동 | **AppFlow** | |
| 계속 실패하는 메시지 격리·재처리 | **DLQ**(같은 종류의 큐) + `StartMessageMoveTask` | |
| SQS → Lambda 중복 처리 | 가시성 타임아웃 ≥ 함수 타임아웃 × **6**, 소비자 **멱등**, 부분 배치 실패 보고 | |

### 고가용성 (M02, M03, M05, M08, M12)

| 단일 장애점 | 처방 |
|---|---|
| EC2 한 대 | **ASG(여러 AZ, 최소 2) + ALB**, 헬스 체크 **ELB** |
| NAT 하나 | **AZ마다 NAT + AZ별 라우팅 테이블** |
| RDS 단일 AZ | **Multi-AZ**(동기, 자동 장애 조치, 엔드포인트 유지) / 더 빠르게 **Aurora** |
| 세션·파일이 서버 안 | **ElastiCache·DynamoDB** / **EFS·S3** |
| 여러 AZ 웹 서버가 같은 파일 | **EFS**(리전 스토리지 클래스) |
| 장애 시 점검 페이지(액티브-패시브) | **Route 53 장애 조치 라우팅** + 상태 확인 |
| 고정 IP + 몇 초 리전 전환(TCP/UDP) | **Global Accelerator** |
| 오리진 장애 대비(HTTP) | **CloudFront 오리진 그룹** |

| | RDS Multi-AZ 인스턴스 | Multi-AZ DB 클러스터 | 읽기 복제본 | Aurora 복제본 |
|---|---|---|---|---|
| 목적 | 가용성 | 가용성 + 읽기 | 읽기 확장·교차 리전 DR | 둘 다 |
| 복제 | 동기 | 반동기 | 비동기 | 공유 스토리지 |
| 대기 읽기 | ❌ | ✅(2개) | ✅ | ✅ |
| 자동 장애 조치 | ✅ 보통 1~2분 | ✅ 더 빠름 | ❌ 수동 승격(새 엔드포인트) | ✅ |

### DR (M12)

| 전략 | 평소 DR 리전 | RPO / RTO | 비용 |
|---|---|---|---|
| 백업·복원 | 백업만 | 시간 / 시간 | 최저 |
| 파일럿 라이트 | **데이터 복제** + 꺼진 컴퓨트 | 초~분 / 수십 분 | 낮음 |
| 웜 스탠바이 | 축소된 전체 스택 **실행 중** | 초~분 / 분 | 중간 |
| 다중 사이트 액티브-액티브 | 전체가 트래픽 처리 | ≈0 / ≈0 | 최고 |

| 필요 | 답 |
|---|---|
| 여러 서비스 백업 중앙 정책·교차 리전/계정 복사 | **AWS Backup** |
| 관계형 리전 장애, 초 RPO·분 RTO | **Aurora Global Database**(보조 리전 최대 10) |
| NoSQL 다중 리전 다중 쓰기 | **DynamoDB 전역 테이블** |
| S3 다른 리전 사본 + 15분 SLA | **CRR + S3 RTC** (99.9%를 15분 안에) |
| 서버 그대로 DR, 초 RPO·분 RTO | **Elastic Disaster Recovery** |
| 서버 이전(lift-and-shift) | **Application Migration Service(MGN)** |
| DB 이전 최소 다운타임 / 이종 엔진 | **DMS full load + CDC** / **SCT·DMS Schema Conversion** + DMS |

---

## D3. 고성능 아키텍처 (24%)

### 스토리지 (M03, M04)

| 요구 | 답 |
|---|---|
| OS 디스크·DB 데이터 파일, 기본값 | **EBS gp3**(기본 3,000 IOPS·125 MiB/s, 최대 80,000 IOPS) |
| 최고 IOPS·sub-ms·99.999% 내구성 | **io2 Block Express**(최대 256,000 IOPS) |
| 순차 처리량·싼 HDD / 콜드 | **st1** / **sc1**(부트 불가) |
| 초고속 임시 데이터 | **인스턴스 스토어**(중지·종료 시 소멸) |
| Linux 여러 대 NFS 공유 | **EFS** |
| Windows SMB·AD·NTFS | **FSx for Windows File Server** |
| HPC·ML + S3 연동 | **FSx for Lustre** |
| NetApp·멀티 프로토콜 / ZFS | **FSx for NetApp ONTAP** / **FSx for OpenZFS** |
| 큰 파일 업로드 | **멀티파트**(100 MB↑ 권장) / 먼 곳 업로드 **Transfer Acceleration** |
| 온프레미스가 NFS/SMB로 S3에 / iSCSI / 테이프 | **S3 File Gateway** / **Volume Gateway** / **Tape Gateway** |
| 온라인 대량 이전·주기 동기화 | **DataSync** |
| 협력사 SFTP/FTPS/AS2 | **Transfer Family** |

### 컴퓨트 (M03, M07)

| 요구 | 답 |
|---|---|
| 노드 간 최저 지연(HPC, 한 AZ) | **클러스터 배치 그룹** + EFA |
| 소수 핵심 서버 랙 분리 / 대형 분산 시스템 | **분산**(AZ당 7대) / **파티션** |
| CPU·메모리·GPU 병목 | C / R·X / P·G·Inf·Trn 패밀리 |
| 짧은 이벤트 처리(≤15분), 유휴 0 | **Lambda** (콜드 스타트 → **프로비저닝된 동시성**) |
| 서버 관리 없는 컨테이너 / 쿠버네티스 | **Fargate** / **EKS** |
| 온프레미스에서 관리형 컨테이너 | **ECS Anywhere / EKS Anywhere** (배포판만: EKS Distro) |
| 대량 배치(큐·스케줄링·스팟) | **AWS Batch** |
| 코드만 올리면 EC2·ASG·ELB 구성 | **Elastic Beanstalk** |
| L7 경로·호스트 라우팅 / 고정 IP·초저지연 L4 / 어플라이언스 | **ALB** / **NLB** / **GWLB** |
| Lambda가 RDS 연결 폭증 | **RDS Proxy** |

### 데이터베이스 (M05)

| 요구 | 답 |
|---|---|
| 관계형, 기존 앱, 관리 부담↓ | **RDS** / 성능·복제본 15·빠른 장애 조치 **Aurora** / 예측 불가 **Aurora Serverless v2**(0 ACU 자동 일시 중지) |
| 키-값, ms, 무제한 확장 | **DynamoDB** (마이크로초 읽기 → **DAX**) |
| 범용 캐시·세션 | **ElastiCache**(Valkey/Redis OSS: 복제·장애 조치 / Memcached: 단순·멀티스레드) |
| 읽기 부하 분산 | **읽기 전용 복제본** / 캐시 |
| 데이터 웨어하우스·BI | **Redshift**(+ Spectrum) |
| 그래프 / MongoDB 호환 / Cassandra 호환 | **Neptune** / **DocumentDB** / **Keyspaces** |
| 시계열 | **Timestream for InfluxDB** (LiveAnalytics는 신규 고객 불가) |
| 검색·로그 분석 | **OpenSearch Service** |
| DynamoDB 접근 패턴 추가 / 같은 파티션 키 다른 정렬 | **GSI**(언제든, 최종 일관) / **LSI**(생성 시에만) |

### 네트워크·엣지 (M02, M08)

| 요구 | 답 |
|---|---|
| 정적 콘텐츠 전 세계 저지연 + 비공개 S3 | **CloudFront + OAC** |
| 헤더 조작·리디렉션(가벼움) / 외부 호출·본문(무거움) | **CloudFront Functions** / **Lambda@Edge** |
| 가장 빠른 리전 / 나라별 고정 / N% 카나리 | Route 53 **지연 시간** / **지리적 위치** / **가중치** |
| apex 도메인 → AWS 리소스 | **Alias**(CNAME ❌) |
| 일관된 대역폭·낮은 지연 사설 회선 | **Direct Connect**(1/10/100/400 Gbps) + VPN 백업 |
| VPC 2~3개 / 수십 개 + 온프레미스 허브 | **피어링** / **Transit Gateway** |
| 대도시 한 자릿수 ms / 5G 단말 / 내 데이터 센터 | **Local Zones** / **Wavelength** / **Outposts** |

### 수집·분석·AI (M06, M11)

| 요구 | 답 |
|---|---|
| 실시간 스트림, 여러 소비자, 재처리(최대 365일) | **Kinesis Data Streams** |
| 스트림을 S3·Redshift·OpenSearch로 적재만 | **Amazon Data Firehose** |
| 영상 스트림 | **Kinesis Video Streams** |
| S3에 서버리스 SQL | **Athena**(파티션 + Parquet로 스캔↓) |
| 대규모 Spark·Hadoop | **EMR** / 서버리스 ETL·카탈로그 **Glue** |
| BI 대시보드 | **Amazon Quick**(구 QuickSight) |
| 제3자 데이터 구독 | **Data Exchange** |
| 음성→텍스트 / 텍스트 감정·개체 / 번역 / 텍스트→음성 | **Transcribe** / **Comprehend** / **Translate** / **Polly** |
| 이미지·영상 분석 / 문서 양식·표 추출 / 챗봇 / 맞춤 모델 | **Rekognition** / **Textract** / **Lex** / **SageMaker AI** |

---

## D4. 비용 최적화 (20%)

| 요구 | 답 |
|---|---|
| 꾸준, 패밀리·리전 바뀜, Fargate·Lambda 포함 | **Compute Savings Plans**(최대 66%) |
| 꾸준, 한 리전·한 패밀리, 최대 할인 | **EC2 Instance SP / Standard RI**(최대 72%) / 교환 필요 **Convertible RI** |
| 중단 가능(배치·CI) | **스팟**(최대 90%, 2분 알림) + 유형·AZ 다양화, 용량 최적화 할당 |
| 특정 AZ 용량 보장(할인 없음) | **온디맨드 용량 예약** |
| BYOL 소켓·코어 | **전용 호스트** |
| 꾸준한 RDS / 간헐적 DB | **예약 DB 인스턴스** / **Aurora Serverless v2**·DynamoDB 온디맨드 |
| DynamoDB 예측 가능 | **프로비저닝 + Auto Scaling + 예약 용량** |
| 유휴 시간 많은 작은 서비스 | **Lambda**(유휴 0) |
| gp2 | **gp3**(약 20%↓, 무중단 변경) |
| 접근 패턴 모름 | **S3 Intelligent-Tiering**(검색 요금 없음, 128 KB 미만은 이동 안 함) |
| 드물게·즉시 / 분기 1회·즉시 / 재생성 가능 | **Standard-IA**(30일) / **Glacier IR**(90일) / **One Zone-IA** |
| 몇 시간 대기 OK / 최저가(12h·48h) | **Glacier Flexible**(90일) / **Deep Archive**(180일) |
| 프라이빗 → S3·DynamoDB가 NAT 비용 | **게이트웨이 엔드포인트**(무료) |
| 전 세계 다운로드 전송비 | **CloudFront**(AWS 오리진 → CloudFront 무료) |
| 적정 크기 권고 | **Compute Optimizer** / 점검 **Trusted Advisor** |
| 한도 전 알림 / 지난 비용 분석 / 가장 상세 데이터 / 급증 감지 | **Budgets** / **Cost Explorer** / **CUR(Data Exports)** / **Cost Anomaly Detection** |
| 부서별 배분 | **비용 할당 태그**(활성화 필요, 소급 ❌) |
| 여러 계정 볼륨 할인·약정 공유 | **Organizations 통합 결제** |

데이터 전송: 인터넷 → AWS 무료 · AWS → 인터넷 가장 비쌈 · 같은 AZ 프라이빗 IP 무료 · AZ 간 양방향 과금 · 리전 간 과금 · AWS 오리진 → CloudFront 무료.

---

## 숫자 모음 (자주 묻는 것)

| 항목 | 값 | 모듈 |
|---|---|---|
| Lambda 타임아웃 / 메모리 / 동기 페이로드 | 15분 / 128 MB~10,240 MB / 6 MB | M07 |
| SQS 메시지 / 보존 / 가시성 / 롱 폴링 / FIFO 중복 제거 | 1 MiB / 60초~14일(기본 4일) / 0~12시간 / ≤20초 / 5분 | M06 |
| S3 객체 / 단일 PUT / 파트 | 50 TB / 5 GB / 5 MiB~5 GiB × 10,000 | M04 |
| DynamoDB 항목 / 트랜잭션 / LSI / GSI | 400 KB / 100개·4 MB, 비용 2배 / 5 / 20(기본) | M05 |
| RDS 자동 백업 / 읽기 복제본 | 0~35일 / 15개 | M05 |
| Aurora 사본 / 복제본 | 3 AZ × 2 = 6 / 15 | M05 |
| Kinesis 샤드 쓰기 / 보존 | 1 MB/s·1,000 rec/s / 24시간~365일 | M06 |
| KMS Encrypt 최대 / 삭제 대기 | 4 KB / 7~30일 | M09 |
| API Gateway 계정 스로틀 / 통합 타임아웃 | 10,000 rps·버스트 5,000 / REST 29초(증설 가능), HTTP 30초 | M07 |
| 서브넷 예약 IP | 5개 | M02 |
| 가용성 99.9% / 99.99% | 월 약 43.8분 / 4.4분 | M12 |

## 최근 바뀐 사실 (옛 자료와 다를 수 있다)

| 사실 | 시점 | 시험 대응 | 모듈 |
|---|---|---|---|
| S3 수명 주기의 Standard-IA·One Zone-IA 전환 30일 제한 폐지(최소 보관 기간 30일 요금은 유지) | 2026-07 | 옛 문제는 "30일 후부터"를 정답으로 기대할 수 있다 — 두 사실을 모두 알기 | M04 |
| SQS 최대 메시지 256 KB → **1 MiB** | 2025-08 | | M06 |
| S3 최대 객체 5 TB → **50 TB** | 2025-12 | | M04 |
| 새 범용 버킷에서 **SSE-C 기본 차단** | 2026-04 | | M04 |
| KMS HSM **FIPS 140-3 Level 3** | | CloudHSM을 고르는 이유는 "단일 테넌트·고객 단독 통제" | M09 |
| App Runner 신규 고객 불가(대안 ECS Express Mode) | 2026-04-30 | 범위 목록에는 없음, 옛 문제의 답일 수 있음 | M07 |
| Proton 지원 종료 | 2026-10-07 | 범위 목록에는 남아 있음 | M10 |
| Timestream for LiveAnalytics 신규 고객 불가 → for InfluxDB | 2025-06-20 | | M05 |
| QLDB 지원 종료 | 2025 | 범위 밖 | M05 |
| Snowball Edge 기존 고객 전용, Migration Hub·Application Discovery Service 신규 불가(후속 AWS Transform) | 2025-11-07 | 옛 문제의 "오프라인 수십 TB" 답은 Snow | M04·M12 |
| QuickSight → **Amazon Quick** 표기 | | | M11 |
| S3 Select·Data Pipeline 신규 고객 불가 → Athena / Glue·Step Functions·MWAA | | | M04·M11 |

## 정리한 불일치 (모듈 사이에서 표현이 달랐던 곳)

이 치트시트는 아래와 같이 정리했다. 원래 모듈의 수정은 해당 모듈 담당에게 요청했다(PR 본문).

| # | 내용 | 어디 | 이 치트시트의 판단 (근거) |
|---|---|---|---|
| 1 | M13 README "에뮬레이터 제약"은 "잘못된 규칙(30일 미만 IA 등)도 거부하지 않는다"고 쓴다. M04는 2026-07 AWS 변경으로 **30일 미만 IA 전환은 더 이상 잘못된 규칙이 아니고**, 에뮬레이터는 최소 보관 기간을 어기는 연쇄 전환은 거부한다고 확인했다 | [M13 README](../m13-cost-optimization/README.md) ↔ [M04 README](../m04-storage/README.md) | M04가 맞다. M13의 문장은 "전환이 일어나지 않는다"만 남기는 것이 정확 |
| 2 | S3 RTC 수치: M04 레슨 3은 "새 객체의 99.99%를 15분 안에", M12 치트시트는 "99.9% 15분 이내" | [M04-03](../m04-storage/03-versioning-lock-replication.md) ↔ [M12 치트시트](../m12-resilience-dr-migration/cheatsheet.md) | 현재 S3 사용 설명서는 "**99.9%**를 15분 안에"(2026-11 확인). M12가 맞다 |
| 3 | M02 README는 "M10은 이 VPC(10.0.0.0/24·10.0.10.0/24·10.0.20.0/24…, AZ별 NAT 2개)를 CloudFormation으로 재현한다"고 쓰지만, M10 템플릿은 다른 CIDR(10.0.1·2 / 11·12 / 21·22)과 **NAT 1개**·앱 라우팅 테이블 1개를 쓴다(M10 README가 독립 설계라고 밝힘) | [M02 README](../m02-vpc-networking/README.md) ↔ [M10 vpc-3tier.yaml](../m10-monitoring-iac/labs/templates/vpc-3tier.yaml) | 캡스톤은 M02 계획(NAT 2개)을 따른다. NAT 1개는 비용 절충임을 레슨 01 R1로 다뤘다. M02 README의 "재현" 문장 또는 M10 템플릿 중 하나를 맞추는 것이 좋다 |
| 4 | 보안 그룹 이름: M02 `todayorder-alb-sg`/`app-sg`/`db-sg`, M10 템플릿 `WebSg`/`AppSg`/`DbSg`(설명 "web tier") | 위와 같음 | 같은 개념. 캡스톤은 M02 이름(`-alb-sg` 등) |
