# M03-01. EC2 기본: AMI, 인스턴스 유형, 키 페어, 사용자 데이터, IMDSv2
> 도메인: D2, D3 · 예상 시간: 50분 · 실습 등급: 🟢 (상태 전이) / 부팅·사용자 데이터 실행은 없음

## 왜 필요한가

M02에서 TodayOrder의 VPC를 만들었다. 이제 그 안에 주문 API 서버를 띄울 차례다. 회사 IDC였다면 서버를 주문하고, OS를 깔고, 랙에 꽂는 데 몇 주가 걸렸을 것이다. AWS에서는 "어떤 디스크 이미지로(AMI), 어떤 크기의 서버를(인스턴스 유형), 어느 서브넷에" 띄울지 API 한 번으로 정한다. 대신 고르는 눈이 필요하다. 메모리가 모자란 서버, 키를 잃어버린 서버, 메타데이터가 털리는 서버를 만들지 않으려면 각 선택지의 의미를 알아야 한다.

## 핵심 개념

**EC2(Elastic Compute Cloud)** 는 가상 서버를 빌려 주는 서비스다. 가상 서버 한 대를 **인스턴스(instance)** 라고 부른다.

```mermaid
flowchart LR
  AMI["AMI<br/>(OS + 기본 소프트웨어가 든<br/>루트 디스크 스냅샷)"] --> RI{{"RunInstances"}}
  TYPE["인스턴스 유형<br/>t3.micro, m7i.large …<br/>(vCPU·메모리·네트워크)"] --> RI
  NET["서브넷 + 보안 그룹<br/>(M02)"] --> RI
  KEY["키 페어<br/>(SSH 공개 키)"] --> RI
  UD["사용자 데이터<br/>(첫 부팅 때 실행할 스크립트)"] --> RI
  RI --> I["인스턴스<br/>i-0123…"]
  I --> VOL["루트 EBS 볼륨<br/>(AMI 스냅샷에서 복제)"]
  I -. "169.254.169.254" .-> IMDS["인스턴스 메타데이터 서비스<br/>(IMDS)"]
```

### AMI (Amazon Machine Image)

인스턴스의 **루트 디스크 템플릿**이다. "OS가 설치된 디스크 스냅샷 + 어떤 디바이스로 붙일지(블록 디바이스 매핑) + 아키텍처(x86_64/arm64)" 를 묶은 것. AWS가 제공하는 것(Amazon Linux, Ubuntu, Windows), 마켓플레이스 것, **내가 만든 것**이 있다. AMI는 **리전에 속한다** — 다른 리전에서 쓰려면 복사(CopyImage)해야 한다.

자기 AMI를 만들어 두면(앱까지 설치된 "골든 AMI") 새 서버가 몇 분이 아니라 몇 십 초 만에 일할 준비가 된다. 오토 스케일링(레슨 6)에서 빨리 늘어나는 비결이다. AMI의 실체는 EBS 스냅샷이라 레슨 3에서 다시 다룬다([lab04](./labs/lab04-ami-read.sh)).

### 인스턴스 유형 읽는 법

`m7i.large` = **m**(패밀리: 범용) + **7**(세대) + **i**(추가 속성: Intel) + **large**(크기). 크기가 한 단계 커질 때마다(large → xlarge → 2xlarge) vCPU·메모리가 대략 두 배가 된다.

| 패밀리 | 용도 | 예 | 이럴 때 |
|---|---|---|---|
| **T** | 버스트 가능 범용 | t3, t4g | 평소 한가하고 가끔 바쁜 개발 서버·소규모 API (CPU 크레딧으로 버스트) |
| **M** | 범용 | m7i, m7g | 웹·API 서버, 무난한 기본값 |
| **C** | 컴퓨팅 최적화 | c7i, c7g | CPU가 병목: 인코딩, 배치 계산, 게임 서버 |
| **R / X** | 메모리 최적화 | r7i, x2idn | 메모리가 병목: 인메모리 캐시, 큰 DB |
| **I / D** | 스토리지 최적화 | i4i, d3 | 로컬 NVMe 고속 I/O: NoSQL, 데이터 웨어하우스 |
| **P / G / Inf / Trn** | 가속 컴퓨팅 | p5, g6, inf2 | GPU·ML 학습/추론 |

추가 속성: `g` = AWS **Graviton**(arm64, 같은 성능에 더 저렴한 경우가 많다), `a` = AMD, `i` = Intel, `d` = 로컬 NVMe 인스턴스 스토어, `n` = 네트워크 강화.

### 키 페어

EC2에 SSH로 접속할 때 쓰는 공개 키/개인 키 쌍. AWS는 **공개 키만 보관**하고, 개인 키는 만들 때 **딱 한 번** 돌려준다. 잃어버리면 다시 받을 수 없다. 요즘 실무는 SSH 포트를 열지 않고 **Systems Manager Session Manager**로 접속하는 쪽을 권장한다(M02 레슨 7).

### 사용자 데이터 (User data)

인스턴스가 **처음 부팅할 때** 한 번 실행할 스크립트(보통 `#!/bin/bash`, 또는 cloud-init). "nginx 설치하고 앱 내려받아 실행" 같은 부트스트랩에 쓴다. 크기 제한은 16KB(base64 인코딩 전)다. 매번 오래 걸리는 설치를 한다면 그 작업을 AMI에 미리 구워 두는 것이 정석이다.

### 인스턴스 메타데이터 서비스 (IMDS)와 IMDSv2

인스턴스 안에서 `http://169.254.169.254/latest/meta-data/` 로 "내 인스턴스 ID, AZ, **IAM 역할의 임시 자격 증명**"을 읽을 수 있다. 자격 증명이 들어 있으니 위험하다. 웹 앱의 SSRF 취약점으로 이 주소를 대신 호출하게 만들면 키가 새어 나간다.

**IMDSv2**는 먼저 `PUT`으로 세션 토큰을 받아야 메타데이터를 읽을 수 있게 해 SSRF를 막는다. `HttpTokens=required`가 "v2만 허용"이다. `HttpPutResponseHopLimit=1`은 토큰 응답이 한 홉(인스턴스 자신)을 넘지 못하게 한다. 컨테이너 안에서 IMDS를 써야 하면 2로 둔다.

```bash
# 인스턴스 안에서 (실제 AWS)
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
```

### 인스턴스 수명 주기

```mermaid
stateDiagram-v2
  [*] --> pending: RunInstances
  pending --> running
  running --> stopping: StopInstances
  stopping --> stopped
  stopped --> pending: StartInstances
  running --> running: RebootInstances (같은 호스트, IP 유지)
  running --> shutting_down: TerminateInstances
  stopped --> shutting_down: TerminateInstances
  shutting_down --> terminated
  terminated --> [*]
```

- **stopped**: 컴퓨트 요금은 멈추지만 **EBS 볼륨 요금은 계속** 나간다. 다시 시작하면 다른 물리 호스트로 옮겨질 수 있고, 자동 할당 공인 IP는 바뀐다(EIP는 유지, 레슨 4).
- **terminated**: 되돌릴 수 없다. 루트 볼륨은 기본값(`DeleteOnTermination=true`)이면 함께 지워진다.
- 인스턴스 유형 변경(스케일 업)은 **중지 상태에서만** 할 수 있다.

## 직접 해 보기

전체 과정: [labs/lab01-instance-lifecycle.sh](./labs/lab01-instance-lifecycle.sh). 이 모듈의 lab들은 공용 함수 [labs/_lib.sh](./labs/_lib.sh)로 **M03 전용 최소 VPC**(10.30.0.0/16, 서브넷 `us-east-1a`·`us-east-1b`, IGW)를 찾거나 만든다.

**1) AMI 찾기.** AMI ID는 리전마다, 그리고 새 버전이 나올 때마다 바뀐다. 그래서 하드코딩하지 않고 AWS가 공개하는 **SSM 파라미터**에서 "최신 Amazon Linux 2023"을 읽는다.

```bash
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
aws ec2 describe-images --image-ids "$AMI" \
  --query 'Images[0].{ImageId:ImageId,Name:Name,Arch:Architecture,RootDevice:RootDeviceType,RootSnapshot:BlockDeviceMappings[0].Ebs.SnapshotId,RootSizeGiB:BlockDeviceMappings[0].Ebs.VolumeSize}'
```

```
{
    "ImageId": "ami-0000000000000004c",
    "Name": "al2023-ami-2023.8.20251104.0-kernel-6.18-x86_64",
    "Arch": "x86_64",
    "RootDevice": "ebs",
    "RootSnapshot": "snap-0000000000000004d",
    "RootSizeGiB": 8
}
```

방금 본 것: AMI는 결국 "루트 디스크 스냅샷(`snap-…`) 8GiB + 메타데이터"다.

**2) 인스턴스 유형 비교.**

```bash
aws ec2 describe-instance-types --instance-types t3.micro m7i.large m7g.large c7i.large r7i.large \
  --query 'sort_by(InstanceTypes,&InstanceType)[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB,ProcessorInfo.SupportedArchitectures[0],BurstablePerformanceSupported,FreeTierEligible]' \
  --output table
```

```
---------------------------------------------------------
|                 DescribeInstanceTypes                 |
+-----------+----+--------+---------+---------+---------+
|  c7i.large|  2 |  4096  |  x86_64 |  False  |  False  |
|  m7g.large|  2 |  8192  |  arm64  |  False  |  False  |
|  m7i.large|  2 |  8192  |  x86_64 |  False  |  False  |
|  r7i.large|  2 |  16384 |  x86_64 |  False  |  False  |
|  t3.micro |  2 |  1024  |  x86_64 |  True   |  True   |
+-----------+----+--------+---------+---------+---------+
```

방금 본 것: 같은 `large`(2 vCPU)라도 메모리가 **C 4GiB : M 8GiB : R 16GiB = 1 : 2 : 4**다. 메모리:vCPU 비율이 패밀리를 가른다. `m7g`는 arm64(Graviton)라 x86 전용 AMI로는 띄울 수 없다. `t3.micro`만 버스트 가능(`True`)이다.

**3) 키 페어.** 개인 키는 이 응답에서만 받을 수 있다.

```bash
aws ec2 create-key-pair --key-name todayorder-m03-key --query KeyMaterial --output text > key.pem
chmod 600 key.pem
head -1 key.pem
aws ec2 describe-key-pairs --key-names todayorder-m03-key --query 'KeyPairs[0].[KeyName,KeyFingerprint]' --output text
```

```
-----BEGIN RSA PRIVATE KEY-----
todayorder-m03-key	97:1c:0a:c1:aa:0f:99:49:c8:52:a1:48:36:40:f9:93:a2:a2:80:0e
```

같은 이름으로 다시 만들면 거부된다. 에뮬레이터는 `DeleteKeyPair`가 501이라 키 페어를 지울 수 없어서, lab은 두 번째 실행부터 이 오류를 보여 주고 기존 키 페어를 그대로 쓴다.

```
aws: [ERROR]: An error occurred (InvalidKeyPair.Duplicate) when calling the CreateKeyPair operation: The keypair already exists
```

**4) 사용자 데이터 + IMDSv2 필수로 시작.**

```bash
cat > user-data.sh <<'EOF'
#!/bin/bash
dnf install -y nginx
echo "TodayOrder API" > /usr/share/nginx/html/index.html
systemctl enable --now nginx
EOF
aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
  --subnet-id "$M03_SUBNET_A" --key-name todayorder-m03-key \
  --user-data file://user-data.sh \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=todayorder-api-1},{Key=Project,Value=todayorder}]' \
  --query 'Instances[0].InstanceId' --output text
```

lab은 상태가 바뀔 때마다 기록하며 `running`까지 기다린다.

```
시작한 인스턴스: i-00000000000000001
상태 전이: pending → running
{
    "Type": "t3.micro",
    "AZ": "us-east-1a",
    "PrivateIp": "10.30.1.4",
    "Key": "todayorder-m03-key",
    "IMDS": "required",
    "HopLimit": 1,
    "RootVolume": "vol-0000000000000008e"
}
```

방금 본 것: 프라이빗 IP `10.30.1.4`는 서브넷 `10.30.1.0/24`의 첫 사용 가능 주소다(.0~.3은 AWS 예약, M02 레슨 1). AMI 스냅샷에서 루트 볼륨(`vol-…`)이 따로 만들어졌다.

**5) 사용자 데이터는 저장된다. 하지만 실행되지는 않는다.**

```bash
aws ec2 describe-instance-attribute --instance-id i-00000000000000001 --attribute userData \
  --query UserData.Value --output text | base64 -d
```

```
#!/bin/bash
dnf install -y nginx
echo "TodayOrder API" > /usr/share/nginx/html/index.html
systemctl enable --now nginx
```

방금 본 것: API는 사용자 데이터를 **base64로 저장**한다. 에뮬레이터의 인스턴스는 상태만 바뀔 뿐 **실제로 부팅하지 않으므로** 이 스크립트는 실행되지 않고, nginx도 뜨지 않으며, SSH 접속도 불가능하다.

**6) 인스턴스 상태 확인(DescribeInstanceStatus)** — 실제 AWS에서는 하드웨어(시스템) 상태 확인과 OS(인스턴스) 상태 확인 결과를 보여 준다. 에뮬레이터는 미구현이다.

```
aws: [ERROR]: An error occurred (NotImplemented) when calling the DescribeInstanceStatus operation: operation DescribeInstanceStatus is scaffolded but not implemented in this emulator
```

**7) 중지 → 유형 변경 시도 → 시작 → 종료.**

```bash
aws ec2 stop-instances --instance-ids i-00000000000000001 \
  --query 'StoppingInstances[0].[PreviousState.Name,CurrentState.Name]' --output text
aws ec2 modify-instance-attribute --instance-id i-00000000000000001 --instance-type Value=t3.small
aws ec2 start-instances --instance-ids i-00000000000000001 \
  --query 'StartingInstances[0].[PreviousState.Name,CurrentState.Name]' --output text
aws ec2 wait instance-running --instance-ids i-00000000000000001 && echo "waiter: running"
aws ec2 terminate-instances --instance-ids i-00000000000000001 \
  --query 'TerminatingInstances[0].[PreviousState.Name,CurrentState.Name]' --output text
```

```
running	stopping
상태 전이: stopping → stopped
aws: [ERROR]: An error occurred (NotImplemented) when calling the ModifyInstanceAttribute operation: operation ModifyInstanceAttribute is scaffolded but not implemented in this emulator
stopped	pending
waiter: running
running	shutting-down
상태 전이: shutting-down → terminated
```

방금 본 것: 수명 주기 다이어그램의 전이가 그대로 관찰된다(🟢). 인스턴스 유형 변경(`ModifyInstanceAttribute`)은 에뮬레이터 미구현이다. 이 모듈은 대신 **시작 템플릿 새 버전**으로 "유형 변경"을 표현한다(레슨 6, [lab08](./labs/lab08-launch-template-asg.sh)).

## 실제 AWS에서는

- 인스턴스가 **실제로 부팅**하고 사용자 데이터가 root 권한으로 실행된다. 결과 로그는 인스턴스 안의 `/var/log/cloud-init-output.log`에 남는다.
- `describe-instance-status`로 상태 확인 2종(시스템 상태 = AWS 하드웨어·네트워크, 인스턴스 상태 = OS)을 볼 수 있고, CloudWatch 경보로 "시스템 상태 확인 실패 시 **자동 복구(recover)**" 액션을 걸 수 있다(M10).
- 에뮬레이터는 **종료된 인스턴스의 루트 볼륨을 지우지 않고 `in-use`로 남긴다**(실제 AWS는 `DeleteOnTermination=true`면 삭제). 또 `DeleteKeyPair`가 501이다.
- IMDS(169.254.169.254)는 실제 인스턴스 안에서만 의미가 있다. 에뮬레이터에서는 설정값(`MetadataOptions`)만 확인할 수 있다.

## 시험 포인트

- "SSRF로 인스턴스 자격 증명 탈취를 막아라" → **IMDSv2 필수(`HttpTokens=required`)**. 계정 기본값이나 AMI 설정으로도 강제할 수 있다.
- "부팅 시간을 줄여라 / 오토 스케일링이 느리다" → 사용자 데이터에서 설치하지 말고 **골든 AMI**에 미리 굽는다.
- "다른 리전에서 같은 서버를 띄워라" → AMI는 리전 리소스. **AMI 복사**(암호화 키도 대상 리전의 것으로).
- 워크로드→패밀리: CPU 많이 쓰는 배치 → **C**, 인메모리 캐시·큰 DB → **R/X**, 고속 로컬 I/O → **I**, 가끔 바쁜 소규모 → **T**, 비용 대비 성능 → **Graviton(g)**.
- 인스턴스 유형 변경 = 중지 → 유형 변경 → 시작 (EBS 기반만 중지할 수 있다).

## 스스로 확인

1. 사용자 데이터에 `apt-get upgrade`와 앱 빌드를 넣었더니 오토 스케일링으로 늘어난 서버가 10분 뒤에야 트래픽을 받는다. 어떻게 고치나?
2. `HttpPutResponseHopLimit`을 1로 두면 그 인스턴스의 Docker 컨테이너 안에서 IMDSv2를 쓰는 SDK는 어떻게 되나?
3. 인스턴스를 중지했다 시작했더니 공인 IP가 바뀌었다. 왜? 바뀌지 않게 하려면?

<details><summary>답</summary>

1. 설치·빌드를 미리 해 둔 **골든 AMI**를 만들고 시작 템플릿이 그 AMI를 쓰게 한다. 사용자 데이터에는 환경별 설정 주입 같은 짧은 일만 남긴다.
2. 컨테이너 네트워크를 거치면 홉이 하나 늘어서 토큰 응답이 컨테이너까지 오지 못한다. 메타데이터를 읽지 못해 IAM 역할 자격 증명도 못 받는다. 컨테이너에서 써야 하면 홉 제한을 2로 둔다.
3. 자동 할당 공인 IPv4는 중지하면 반납되고, 시작할 때 새로 받는다. 고정하려면 **탄력적 IP(EIP)** 를 연결하거나, 더 좋게는 앞에 로드 밸런서를 두고 DNS 이름을 쓴다(레슨 4·5).

</details>
