# M04 치트시트

## 블록 vs 파일 vs 객체

| | 블록 (EBS, 인스턴스 스토어) | 파일 (EFS, FSx) | 객체 (S3) |
|---|---|---|---|
| 접근 | 디스크 장치(OS가 파일 시스템을 올림) | NFS/SMB 등 공유 파일 시스템 | HTTP API (PUT/GET) |
| 동시 접근 | 인스턴스 1대(io1/io2 Multi-Attach 예외, 같은 AZ 최대 16대) | **여러 인스턴스 동시 마운트** | 무제한 클라이언트 |
| 범위 | **AZ 하나** | EFS 리전형: 여러 AZ / One Zone: 1 AZ | 리전(데이터는 ≥3 AZ) |
| 용량 | 미리 정함(늘릴 수 있음) | 자동 증감(EFS) / 미리 정함(FSx) | 무제한 |
| 이럴 때 | OS 부팅 디스크, DB 데이터 파일, 낮은 지연 | 여러 서버가 같은 디렉터리를 읽고 씀, 리프트 앤드 시프트 | 이미지·백업·로그·데이터 레이크·정적 웹 |

## S3 스토리지 클래스

| 클래스 | 검색 | 최소 보관 | 최소 과금 크기 | AZ | 한 줄 |
|---|---|---|---|---|---|
| Standard | ms | – | – | ≥3 | 자주 읽음 |
| Intelligent-Tiering | ms | – | (128 KB 미만은 이동 안 함) | ≥3 | **패턴 모름** — 모니터링 요금, 검색 요금 없음 |
| Standard-IA | ms | 30일 | 128 KB | ≥3 | 가끔, 즉시 |
| One Zone-IA | ms | 30일 | 128 KB | **1** | 가끔 + **재생성 가능** |
| Glacier Instant Retrieval | ms | 90일 | 128 KB | ≥3 | 분기 1회, 즉시 |
| Glacier Flexible Retrieval | 1–5분 / 3–5시간 / 5–12시간 | 90일 | +40 KB/객체 | ≥3 | 아카이브, 몇 분~시간 |
| Glacier Deep Archive | ≤12시간 / ≤48시간 (신속 없음) | 180일 | +40 KB/객체 | ≥3 | 최저가 장기 보관 |
| Express One Zone | 한 자릿수 ms | (범위 밖) | (범위 밖) | 1 | 디렉터리 버킷 전용, 초저지연 |

내구성은 모두 11 nines. 수명 주기로 IA·One Zone-IA 전환은 2026-07부터 **0일부터 가능**(예전 자료·시험은 "30일 후부터"). 최소 보관 기간(요금)은 그대로. 2024-09부터 128 KB 미만 객체는 기본적으로 전환 안 됨.

## S3 한계값 (2026-11 기준)

| 항목 | 값 |
|---|---|
| 객체 최대 크기 | 50 TB (2025-12 발표, 이전 5 TB). 단 S3 사용 설명서의 멀티파트 한계 표는 "48.8 TiB"(= 10,000 파트 × 5 GiB)로 적는다 |
| 단일 PUT | 5 GB |
| 멀티파트 파트 | 5 MiB ~ 5 GiB (마지막 파트 예외), 최대 10,000개 |
| 키 길이 | 1,024 바이트 |
| 객체 태그 | 10개 |
| 접두사당 요청 | 쓰기 3,500/s, 읽기 5,500/s |
| presigned URL | SigV4 + IAM 사용자 최대 7일, 임시 자격 증명은 세션 만료와 함께 |
| 일관성 | 강한 read-after-write (덮어쓰기·삭제·LIST 포함) |

## 보안·암호화 고르기

| 요구 | 답 |
|---|---|
| 계정 전체에서 퍼블릭 금지 | 계정 수준 Block Public Access |
| 키 사용 감사·권한 분리 | SSE-KMS (고객 관리형 키) |
| KMS 요청 비용·스로틀링 | S3 버킷 키 |
| 키를 AWS에 맡기지 않음 | SSE-C (2026-04부터 새 범용 버킷은 기본 차단 → `PutBucketEncryption`으로 허용. 바레인·UAE 리전 제외, 기존 버킷은 계정에 SSE-C 객체가 없을 때만 차단) |
| S3에 평문이 닿으면 안 됨 | 클라이언트 측 암호화 |
| HTTPS 강제 | 버킷 정책 Deny `aws:SecureTransport=false` |
| 비공개 객체를 잠깐 공유·직접 업로드 | presigned URL |
| 팀별 정책·VPC 전용 입구 | 액세스 포인트 |
| 다른 계정 접근 | 버킷 정책 + 상대 IAM 정책 (ACL은 끄는 게 기본) |

## 데이터 보호

| 요구 | 답 |
|---|---|
| 실수로 지우거나 덮어써도 복구 | 버전 관리 (삭제 = 삭제 마커) |
| 버전 영구 삭제·버전 관리 변경에 MFA | MFA Delete (루트만, CLI/API로만) |
| WORM, 루트도 못 지움 | 객체 잠금 **규정 준수(Compliance)** 모드 |
| WORM, 특정 권한자는 해제 가능 | 객체 잠금 **거버넌스(Governance)** 모드 + `s3:BypassGovernanceRetention` |
| 기한 없이 소송 대비 보존 | 법적 보존(Legal Hold) |
| 다른 리전에 사본(DR·지연·규정) | CRR |
| 같은 리전 다른 계정/버킷(로그 집계·테스트) | SRR |
| 기존 객체까지 복제 | S3 Batch Replication |
| 15분 내 복제 SLA | Replication Time Control (RTC) — 99.9%를 15분 안에 |

복제 조건: 원본·대상 **버전 관리 필수**, IAM 역할, 기존 객체·이미 복제된 객체는 안 넘어감(체인 비전이), 삭제 마커는 기본 미복제, 버전 지정 삭제는 복제 안 됨.

## 성능·기능

| 요구 | 답 |
|---|---|
| 큰 파일 업로드 실패·느림 | 멀티파트 (100 MB↑ 권장, 5 GB↑ 필수) |
| 먼 곳에서 업로드 | Transfer Acceleration (버킷 이름에 점 금지) |
| 먼 곳에서 다운로드 | CloudFront |
| 업로드 후 자동 처리 | 이벤트 알림 → SQS/SNS/Lambda/EventBridge (FIFO SQS는 EventBridge 경유) |
| 정적 웹 + HTTPS | S3 + CloudFront(OAC) |
| 받는 쪽이 비용 부담 | 요청자 지불 |
| S3 데이터에 SQL | Athena (S3 Select는 신규 불가) |

## 파일 스토리지

| 요구 | 답 |
|---|---|
| Linux 여러 대가 NFS 공유, 자동 확장 | **EFS** (NFSv4.0/4.1, 리전형 또는 One Zone) |
| Windows·SMB·Active Directory | **FSx for Windows File Server** |
| HPC·ML, S3 데이터를 고속 파일 시스템으로 | **FSx for Lustre** |
| NetApp 기능, NFS+SMB+iSCSI 멀티 프로토콜 | **FSx for NetApp ONTAP** |
| ZFS, 온프레미스 ZFS/NFS 이전 | **FSx for OpenZFS** |

EFS: 저장 클래스 Standard / IA / Archive, 처리량 모드 Elastic(권장)·Provisioned·Bursting, 성능 모드 General Purpose(권장)·Max I/O(이전 세대).

## 하이브리드·이전

| 요구 | 답 |
|---|---|
| 사내 서버가 NFS/SMB로 쓰면 S3에 저장 | Storage Gateway **S3 File Gateway** |
| 사내 iSCSI 블록 볼륨, 백업은 AWS (자주 쓰는 데이터만 로컬: cached / 전부 로컬: stored) | **Volume Gateway** |
| 기존 테이프 백업 소프트웨어 유지, 테이프를 클라우드로 | **Tape Gateway** (가상 테이프 → S3 Glacier 계열 보관) |
| 온라인으로 대량 일회성/주기적 이전, 검증·스케줄 | **DataSync** |
| 전용 네트워크 회선(일관된 대역폭, 장기) | **Direct Connect** |
| 회선이 없거나 너무 느림, 오프라인 이전 | Snow 계열 — **2025-11-07부터 신규 고객 불가**, 대안: DataSync·Data Transfer Terminal |
| 협력사가 SFTP/FTPS/FTP/AS2로 파일 전송, 저장은 S3/EFS | **Transfer Family** |
