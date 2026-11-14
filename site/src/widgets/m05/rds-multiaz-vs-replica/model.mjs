// RDS Multi-AZ vs 읽기 전용 복제본 — 설명용 모형(실제 RDS·에뮬레이터 실행이 아니다).
// 구성(Multi-AZ, 복제본 수·위치, 자동 백업, 정산 배치 연결)과 사건 하나를 받아 무슨 일이 일어나는지 단계로 돌려준다.
// 화면과 분리한 순수 함수. 단위 시험: model.test.mjs
//
// 판정의 근거는 모두 레슨 02-multi-az-vs-read-replica.md(줄 번호는 facts.mjs가 읽어 화면에 표시):
//  - Multi-AZ: 동기 복제, 대기는 트래픽을 받지 않음, 자동 장애 조치로 같은 DNS 이름이 대기를 가리킴(보통 1~2분), 데이터 손실 없음
//  - 읽기 복제본: 비동기(조금 오래된 값), 자기 엔드포인트, 자동 장애 조치 아님 → 수동 승격하면 새 엔드포인트,
//    원본 자동 백업(보존 기간 ≥ 1)이 있어야 만들 수 있음, 엔진별 최대 개수, 같은 AZ·다른 AZ·다른 리전
//  - 쓰기 병목에는 복제가 답이 아님(수직 확장·Aurora·샤딩·다른 모델)
//
// 모형의 가정(화면에도 적는다):
//  1. 원본은 us-east-1a(레슨 그림의 AZ). 장애는 그 AZ 전체에 난다. "같은 AZ" 복제본은 함께 멈춘다.
//  2. 장애 조치 시간은 레슨의 "보통 1~2분"을 그대로 보여 줄 뿐 계산하지 않는다. 복제 지연의 길이도 다루지 않는다.
//  3. Multi-AZ DB 클러스터·Aurora·RDS Proxy는 다루지 않는다(Multi-AZ는 인스턴스 배포).
//  4. 원본 AZ 장애 뒤 복제본이 계속 무엇을 복제하는지 등 레슨에 없는 동작은 단정하지 않는다.

export const EVENTS = ['az-failure', 'report', 'read-after-write', 'write-bottleneck'];
export const LOCATIONS = ['same-az', 'other-az', 'other-region'];
/** 화면의 보존 기간 입력 상한(모형 화면 범위). */
export const MAX_RETENTION_SHOWN = 35;

/** 입력을 모형이 다룰 수 있는 범위로 맞춘다. engines = facts.replicaMax.engines */
/** 단계의 근거 키 → 원고 줄 번호. */
export function sourceLines(facts) {
  return {
    sync: facts.syncLine,
    promote: facts.seq.promote,
    dns: facts.seq.dns,
    failover: facts.failover.line,
    noLoss: facts.seq.noLoss,
    location: facts.locationLine,
    failoverRow: facts.failover.line,
    endpoint: facts.answers.endpoint,
    readStandby: facts.readStandbyLine,
    report: facts.answers.report,
    lag: facts.answers.lag,
    write: facts.writeRemedy.line,
    backup: facts.backup.line,
    xr: facts.crossRegionFeeLine,
    exam: facts.examLine,
  };
}

export function normalize(raw, engines) {
  const engine = engines.find((e) => e.id === raw.engine) ?? engines[0];
  const int = (v, lo, hi, d) => {
    const s = String(v ?? '').trim();
    const n = s === '' ? NaN : Number(s);
    return Number.isFinite(n) ? Math.min(hi, Math.max(lo, Math.round(n))) : d;
  };
  return {
    multiAz: Boolean(raw.multiAz),
    engine: engine.id,
    replicas: int(raw.replicas, 0, engine.max, 0),
    replicaMax: engine.max,
    location: LOCATIONS.includes(raw.location) ? raw.location : 'other-az',
    retention: int(raw.retention, 0, MAX_RETENTION_SHOWN, 0),
    batchTo: raw.batchTo === 'replica' ? 'replica' : 'primary',
    event: EVENTS.includes(raw.event) ? raw.event : EVENTS[0],
  };
}

/**
 * @param {ReturnType<typeof normalize>} c
 * @param {{ failoverTime: string, minRetention: number, writeRemedy: string }} f
 * @returns {{ verdict: 'ok' | 'partial' | 'bad', headline: string, steps: {text: string, src: string}[], facts: {endpoint: string, dataLoss: string, api: string}, notes: {text: string, src: string}[], replicasBuilt: number }}
 */
export function evaluate(c, f) {
  /** @type {{text: string, src: string}[]} */
  const notes = [];
  // 자동 백업이 꺼져 있으면 복제본을 만들 수 없다(lab02 5단계).
  const blocked = c.replicas > 0 && c.retention < f.minRetention;
  if (blocked) notes.push({ text: `자동 백업 보존 기간이 ${c.retention}일이라 복제본 ${c.replicas}개를 만들 수 없다(InvalidDBInstanceState). 보존 기간을 ${f.minRetention}일 이상으로 켜야 한다. 아래는 복제본 없이 판정했다.`, src: 'backup' });
  const n = blocked ? 0 : c.replicas;
  if (n && c.location === 'other-region') notes.push({ text: '교차 리전 복제본은 데이터 전송 요금이 붙는다(같은 리전 안 복제는 요금 없음).', src: 'xr' });
  const S = (text, src) => ({ text, src });
  const replicaWord = n ? `읽기 복제본 ${n}개` : '';

  switch (c.event) {
    case 'az-failure': {
      const sameAzReplicas = n && c.location === 'same-az';
      const survivors = n && !sameAzReplicas;
      if (c.multiAz) {
        const steps = [
          S('장애 전: 주문 API의 커밋은 대기(us-east-1b)에도 동기로 기록돼 있었다.', 'sync'),
          S('us-east-1a 장애 — RDS가 대기를 기본으로 승격한다(자동 장애 조치).', 'promote'),
          S('같은 DNS 이름이 이제 us-east-1b의 IP를 가리킨다.', 'dns'),
          S(`기존 연결이 끊기고, 앱은 같은 이름으로 다시 붙는다(보통 ${f.failoverTime}, 그동안 읽기·쓰기 모두 끊김).`, 'failover'),
          S('대기였던 쪽에서 계속 처리한다. 동기 복제라 커밋된 데이터는 잃지 않는다.', 'noLoss'),
        ];
        if (sameAzReplicas) steps.push(S(`같은 AZ(us-east-1a)에 둔 ${replicaWord}도 함께 멈춘다 — 정산 배치의 읽기는 끊긴다.`, 'location'));
        else if (survivors) steps.push(S(`${replicaWord}는 장애 조치에 끼지 않는다(대기가 승격된다).`, 'failoverRow'));
        return {
          verdict: 'ok',
          headline: `자동 장애 조치로 ${f.failoverTime} 안팎 끊긴 뒤 같은 엔드포인트로 계속 동작한다.`,
          steps,
          facts: { endpoint: '그대로(같은 DNS 이름) — 재연결만', dataLoss: '없음(동기 복제)', api: `보통 ${f.failoverTime} 끊김 후 복구` },
          notes,
          replicasBuilt: n,
        };
      }
      if (survivors) {
        return {
          verdict: 'partial',
          headline: '자동 복구는 없다. 사람이 복제본을 승격해야 하고, 승격된 DB는 새 엔드포인트라 앱 설정을 바꿔야 한다.',
          steps: [
            S('us-east-1a 장애 — Multi-AZ가 아니라 대기 인스턴스가 없다. 원본이 멈추고 주문 API의 쓰기가 멈춘다.', 'failoverRow'),
            S(`${replicaWord}(${c.location === 'other-region' ? '다른 리전' : 'us-east-1b'})는 살아 있지만 자동으로 원본이 되지 않는다.`, 'failoverRow'),
            S('운영자가 복제본 하나를 수동 승격(promote)한다 → 독립 DB가 되고 그 복제본의 엔드포인트가 새 쓰기 주소다.', 'endpoint'),
            S('앱의 DB 엔드포인트 설정을 바꿔야 주문 API가 다시 쓴다.', 'endpoint'),
            S('복제가 비동기라 장애 직전의 쓰기 중 아직 복제본에 오지 않은 것은 승격된 DB에 없을 수 있다.', 'sync'),
          ],
          facts: { endpoint: '바뀜(승격한 복제본의 엔드포인트)', dataLoss: '있을 수 있음(비동기 복제)', api: '수동 승격·설정 변경까지 멈춤' },
          notes,
          replicasBuilt: n,
        };
      }
      return {
        verdict: 'bad',
        headline: '자동으로 넘겨받을 DB가 없다. 주문 API가 멈춘다.',
        steps: [
          S('us-east-1a 장애 — Multi-AZ가 아니라 대기 인스턴스가 없다. 원본이 멈춘다.', 'failoverRow'),
          sameAzReplicas ? S(`${replicaWord}도 같은 AZ(us-east-1a)라 함께 멈춘다 — 승격할 복제본도 없다.`, 'location') : S('읽기 복제본도 없어 승격할 대상이 없다.', 'failoverRow'),
          S('"AZ 장애에도 자동 복구, 데이터 손실 최소"가 필요하면 Multi-AZ를 켠다.', 'exam'),
        ],
        facts: { endpoint: '—', dataLoss: '이 레슨의 복구 수단 밖', api: '멈춤(AZ가 돌아오거나 다른 방법으로 복구할 때까지)' },
        notes,
        replicasBuilt: n,
      };
    }
    case 'report': {
      if (n && c.batchTo === 'replica') {
        return {
          verdict: 'ok',
          headline: '집계 쿼리가 복제본에서 돌아 주문 API(원본)가 느려지지 않는다.',
          steps: [
            S(`정산 배치가 복제본 자기 엔드포인트로 붙는다(${replicaWord}, 원본 엔드포인트와 다름).`, 'readStandby'),
            S('원본은 주문 API의 읽기·쓰기만 받는다 — 읽기 부하가 나뉜다.', 'readStandby'),
            S('복제가 비동기라 집계는 조금 오래된 값을 볼 수 있다.', 'sync'),
          ],
          facts: { endpoint: '배치만 복제본 엔드포인트', dataLoss: '해당 없음(읽기)', api: '영향 없음' },
          notes,
          replicasBuilt: n,
        };
      }
      const why = n
        ? S(`${replicaWord}가 있지만 정산 배치가 여전히 원본 엔드포인트로 붙는다 — 복제본은 자기 엔드포인트로 보내야 쓰인다.`, 'report')
        : c.multiAz
          ? S('Multi-AZ 대기 인스턴스는 트래픽을 받지 않는다 — 대기가 있어도 집계는 원본에서 돈다.', 'report')
          : S('읽기 복제본이 없어 집계가 원본에서 돈다.', 'report');
      return {
        verdict: 'bad',
        headline: '집계 쿼리가 원본에서 돌아 주문 API가 느려진다.',
        steps: [why, S('해법: 읽기 복제본을 만들고 정산 배치를 복제본 엔드포인트로 보낸다.', 'report')],
        facts: { endpoint: '모두 원본', dataLoss: '해당 없음(읽기)', api: '느려짐' },
        notes,
        replicasBuilt: n,
      };
    }
    case 'read-after-write': {
      if (!n) {
        return {
          verdict: 'ok',
          headline: '복제본이 없어 원본에서 읽는다 — 방금 쓴 주문이 바로 보인다.',
          steps: [
            S('주문 API가 원본에 INSERT 하고 커밋한다.', 'sync'),
            c.multiAz ? S('대기에도 동기로 기록되지만 대기는 읽기를 받지 않는다 — 읽기는 원본에서.', 'readStandby') : S('바로 원본에서 다시 읽는다.', 'sync'),
          ],
          facts: { endpoint: '원본', dataLoss: '해당 없음', api: '정상' },
          notes,
          replicasBuilt: n,
        };
      }
      return {
        verdict: 'partial',
        headline: '복제본에서 바로 읽으면 없을 수 있다 — 버그가 아니라 비동기 복제의 지연(ReplicaLag)이다.',
        steps: [
          S('주문 API가 원본에 커밋한다.', 'sync'),
          S(`원본 → 복제본 복제는 비동기라 ${c.multiAz ? '(Multi-AZ 대기와 달리) ' : ''}조금 늦게 도착한다.`, 'sync'),
          S('그 사이 복제본에서 읽으면 아직 없다.', 'lag'),
          S('쓴 직후 다시 읽어야 하는 화면은 원본에서 읽는다.', 'lag'),
        ],
        facts: { endpoint: '쓰기는 원본, 그 화면의 읽기도 원본으로', dataLoss: '없음(늦게 보일 뿐)', api: '복제본에서 읽으면 잠깐 안 보임' },
        notes,
        replicasBuilt: n,
      };
    }
    case 'write-bottleneck':
    default:
      return {
        verdict: 'bad',
        headline: '복제로는 쓰기가 늘지 않는다.',
        steps: [
          S(`쓰기는 언제나 원본 하나가 받는다${n ? ` — ${replicaWord}는 읽기만 늘린다` : ''}.`, 'write'),
          c.multiAz ? S('Multi-AZ 대기는 트래픽을 받지 않으니 쓰기도 나누지 않는다.', 'readStandby') : S('Multi-AZ를 켜도 대기는 트래픽을 받지 않는다.', 'readStandby'),
          S(`해법: ${f.writeRemedy}.`, 'write'),
        ],
        facts: { endpoint: '원본', dataLoss: '해당 없음', api: '쓰기 한계 그대로' },
        notes,
        replicasBuilt: n,
      };
  }
}
