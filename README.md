# SmartThings Edge Driver for Commax Wallpad (via Elfin EW11)

코맥스(Commax) 아파트 월패드와 Elfin EW11(RS485 ↔ TCP 변환기)을 연동하여 SmartThings 허브에서 조명, 난방, 환기팬, 가스밸브를 로컬 제어하고 실시간 상태를 모니터링하는 SmartThings Edge Driver입니다.

이 드라이버의 패킷 정의는 **직접 추측한 값이 아니라**, 공개 저장소 [wooooooooooook/homenet2mqtt](https://github.com/wooooooooooook/homenet2mqtt) (`gallery/commax/*.yaml`)의 실제 소스코드를 분석해 확보한 값만 사용합니다. 근거가 확인되지 않은 패킷은 구현하지 않고 "정보 불충분"으로 남겨 두었습니다 (8절 참고).

---

## 1. 전체 시스템 구조

```text
SmartThings App / Hub
        │
        ▼  LAN / TCP Socket (cosock)
Edge Driver (Lua, TCP Client)
        │
        ▼  TCP  (EW11 IP:PORT)
   Elfin EW11 (RS485 ↔ TCP 브리지)
        │
        ▼  RS485 (9600bps, 8N1)
   Commax 월패드 및 서브 컨트롤러
        │
        ├─ 조명 (Light 1..N)
        ├─ 난방 온도조절기 (Thermostat 1..N)
        ├─ 환기팬 (Ventilation Fan)
        └─ 가스밸브 (상태조회 + 닫기만)
```

## 2. EW11 통신 구조 설계

- EW11은 보통 **TCP Server**로 동작하므로, Edge Driver는 **TCP Client**로 EW11의 IP:PORT에 접속하는 구조를 사용한다 ([src/ew11.lua](src/ew11.lua)).
- SmartThings Edge Driver(Lua)는 `cosock` 코루틴 기반 소켓(`cosock.socket`)으로 LAN 접속이 가능하며, `config.yml`의 `permissions.lan`으로 LAN 접근 권한을 선언해야 한다.
- 연결은 끊어질 수 있으므로 5초 간격 재연결 루프, 논블로킹 조회(`settimeout`)로 지속적인 스트림 파싱을 구현했다. (`"*a"`로 전체 스트림을 한 번에 읽으면 연결이 끊기기 전까지 블로킹되므로 사용하지 않음 — 초안 코드의 버그를 수정함.)
- 수신 스트림은 프레이밍 바이트가 없는 고정 8바이트 패킷이므로, 버퍼에 8바이트가 쌓일 때마다 체크섬을 검증해 유효하면 소비하고, 무효하면 1바이트씩 밀어서 동기화를 재획득한다 (`_process_buffer`).

### 2.1 RS485 버스 특유의 방어 처리 (명령 큐 / ACK / 재시도)

RS485는 반이중(half-duplex) 공유 버스라서, 다른 기기가 동시에 송신 중이면 명령이 충돌로 씹힐 수 있다. 참고 저장소의 실제 명령 전송 코드(`command.manager.ts`)를 분석해 다음 방어 로직을 그대로 반영했다 (`src/ew11.lua`):

- **명령 큐 직렬화**: 여러 명령(예: 조명 여러 개 동시 ON)이 들어와도 `tx_queue`에 쌓아 두고 한 번에 하나씩만 전송한다 (`_tx_queue_loop`). 하나가 끝나야(ACK 성공 또는 재시도 소진) 다음 명령을 보낸다.
- **ACK 대기 + 재시도**: 각 명령에는 참고 저장소 YAML의 `ack:` 필드에서 확인된 바이트 프리픽스를 붙여 보내고(`commax_protocol.lua`의 `ack_*` 함수들), 그 프리픽스로 시작하는 유효 패킷이 수신될 때까지 기다린다. 일정 시간(`tx_timeout`, 기본 200ms) 안에 ACK이 없으면 `tx_delay`(기본 10ms) 대기 후 재전송하며, 총 시도 횟수는 `tx_retry_cnt + 1`(기본 6회)이다. 모두 실패하면 예외를 던지지 않고 경고 로그만 남긴다 — 참고 저장소의 "resolve 대신 throw하지 않는다"는 설계를 그대로 따름.
- **rx_timeout(수신 버퍼 폐기)**: 마지막 수신 이후 `rx_timeout`(기본 10ms)을 초과해 새 데이터가 들어오면, 남아있던 불완전한 조각(끊긴 패킷 잔재)을 버리고 새로 시작한다. `packet-parser.ts`의 동일 로직을 반영.
- **버스 유휴(idle) 감지 후 송신**: 마지막 수신 후 100ms 이내에는 명령을 보내지 않고 대기한다(`_bus_busy`). 월패드나 다른 서브 컨트롤러가 막 버스를 사용한 직후에 끼어들면 충돌로 프레임이 깨질 수 있기 때문이다. `kimtc99/HAaddons`(CommaxWallpadBySaram)의 동일한 100ms 송신 지연 로직과 교차검증 후 반영했다.
- 이 값들(`tx_retry_cnt`/`tx_timeout`/`tx_delay`/`rx_timeout`/버스 유휴 100ms)은 참고 저장소들의 기본값을 그대로 사용했다. 우리 집 환경에서 명령이 자주 씹히거나 반대로 응답이 늦게 온다면 `src/ew11.lua`의 `DEFAULT_TX_*`/`rx_timeout`/`BUS_IDLE_GUARD` 값을 조정해야 할 수 있다.

## 3. 코맥스 패킷 구조 (근거: homenet2mqtt `gallery/commax/*.yaml`)

모든 패킷은 **8바이트 고정 길이**이며, 별도의 시작/종료 프레이밍 바이트는 없다(참고 저장소의 브리지 설정에 `rx_header: [], rx_footer: []`로 명시됨). 각 기기군의 Head 바이트 자체가 패킷 종류를 구분한다.

```
[Index 0]     Head        기기군 + 상태/명령 구분 코드
[Index 1~6]   Data        ID, ON/OFF, 온도(BCD), 속도 등 (기기별 위치 다름)
[Index 7]     Checksum    Index 0~6의 8-bit 합산 (add) & 0xFF
```

- **체크섬**: `sum(byte[0..6]) & 0xFF`. 근거: 참고 저장소 `checksum.ts`의 `add()` 함수 및 각 YAML의 `add checksum` 주석. ([src/commax_protocol.lua](src/commax_protocol.lua) `calculate_checksum`)
- **주소 체계**: 아파트 동/호수 등 상위 네트워크 주소 바이트는 확인되지 않았다. 각 YAML에서 확인되는 것은 "기기군 Head + 그 안의 기기 ID(1~9)"뿐이다. → **정보 불충분** (8절 참고)

### 3.1 기능별 패킷 표

| 기능 | 관련 파일 | 명령(Tx) | 상태(Rx) | 응답(Ack) | 비고 |
|---|---|---|---|---|---|
| 조명 ON | `lights_new.yaml` | `31 ID 01 00 00 00 00 [cs]` | `B0 01 ID 00 00 00 00 [cs]` | `B1 01 ID` | ID 1~9 |
| 조명 OFF | `lights_new.yaml` | `31 ID 00 00 00 00 00 [cs]` | `B0 00 ID 00 00 00 00 [cs]` | `B1 00 ID` | |
| 난방 ON(가동) | `heaters_new.yaml` | `04 ID 04 81 00 00 00 [cs]` | `82 81/83 ID Cur Tar 00 00 [cs]` | `84 81 ID` | Cur/Tar = BCD |
| 난방 OFF | `heaters_new.yaml` | `04 ID 04 00 00 00 00 [cs]` | `82 80 ID Cur Tar 00 00 [cs]` | `84 80 ID` | |
| 난방 온도설정 | `heaters_new.yaml` | `04 ID 03 BCD(temp) 00 00 00 [cs]` | (동일 상태 패킷) | `84 00 ID` | |
| 난방 상태요청 | `heaters_request.yaml` | `02 ID 00 00 00 00 00 [cs]` | — | — | 폴링용(주기 요청) |
| 환기 ON | `fan_new.yaml` (entities 실코드 기준) | `78 ID 01 04 00 00 00 [cs]` | `(F0..FE 짝수, F6 등) 01 ID SPD 00 00 00 [cs]` | `F8 04` | 헤더는 `(byte&0xF1)==0xF0` 패밀리 |
| 환기 OFF | `fan_new.yaml` | `78 ID 01 00 00 00 00 [cs]` | 위와 동일 헤더, PWR=00 | `F8 00` | |
| 환기 속도 | `fan_new.yaml` | `78 ID 02 SPD 00 00 00 [cs]` | 위와 동일, index3=SPD | `F8 04` | SPD: 1약/2중/3강 |
| 가스 상태조회 | `gas_valve.yaml` | (요청 명령 정보 불충분, passive listen만) | `90 80/40 80/40 00 00 00 00 [cs]` | — | open=80,80 / closed=40,40 |
| 가스 닫기 | `gas_valve.yaml` | `11 01 80 00 00 00 00 [cs]` | (위와 동일 상태) | `91 88 88` | |
| 가스 열기 | — | **정보 불충분** | — | — | 원문에 command_open 자체가 없음 → 미구현(안전) |

> 환기 헤더에 대한 참고: `fan_new.yaml` 파일 안의 **주석(설명 표)**은 상태 헤더를 `0xF6`/`0xF7`, 명령 헤더를 `0x04`로 적어놓았지만, 같은 파일의 **실제 실행 로직(entities.fan)**은 상태 매칭을 `(byte & 0xF1) == 0xF0` 마스크로, 명령 헤더를 `0x78`로 정의한다. 이 드라이버는 요청에 따라 **실제 실행 로직(entities)을 신뢰**하여 구현했다. 두 값을 비트 단위로 비교하면 `0xF6 & 0xF1 == 0xF0`이 되어 서로 모순되지는 않지만(상태 헤더로서는 둘 다 유효), 명령 헤더는 `0x78`이 확정값이다.

### 3.2 타 오픈소스 저장소와의 교차검증 (zooil/wallpad, kimtc99/HAaddons)

패킷 신뢰도를 높이기 위해 코맥스 월패드를 다루는 다른 두 오픈소스 저장소의 실제 소스코드도 대조했다.

| 기능 | 우리 기준 | zooil/wallpad | kimtc99/HAaddons(CommaxWallpadBySaram) | 결과 |
|---|---|---|---|---|
| 조명 ON/OFF 명령·상태 | `31`/`B0`/`B1` | 동일 | 동일 | **일치** |
| 난방 ON/OFF 명령 | `04 ID 04 81/00...` | 동일 | 동일 | **일치** |
| 난방 상태 ON/OFF 코드(byte1) | `81`/`83` | `81`/`84` | `81`/`80` | **3곳 모두 다름 → 정보 불충분** |
| 환기 명령 바이트 정렬 | `78 ID 01/02 ...` | 미구현 | `78 01 01 04...` (ID 위치가 우리 기준과 다르게 보임) | **불일치 → 정보 불충분** |
| 가스밸브 상태값 | open=`80,80`/closed=`40,40` | 미구현 | open=`A0,A0`/closed=`50,50` | **값 자체가 다름 → 정보 불충분** |
| 가스밸브 닫기 명령 | `11 01 80...` | 미구현 | 동일 | **일치** |
| 가스밸브 열기 명령 | 없음(미구현) | 없음 | 없음 | **일치**(3곳 모두 미구현) |
| 체크섬 알고리즘 | 바이트 단순합 & 0xFF | 코드 미노출(값 하드코딩) | **니블 분리 합산**(다른 알고리즘) | 알고리즘 자체가 다름 |

**결론**: 조명·난방 ON/OFF 명령과 가스 닫기 명령은 3개 저장소가 일치해 신뢰도가 높아졌다. 반면 **난방 상태의 ON/OFF 코드, 환기 명령의 바이트 정렬, 가스밸브 상태값**은 세 저장소가 서로 다른 값을 쓰고 있어(오히려 근거가 늘어날수록 불일치가 드러남), 이 세 항목은 코드를 변경하지 않고 "정보 불충분"으로 유지한다 — 서로 다른 값 중 하나를 임의로 골라 덮어쓰는 것이 오히려 더 위험하기 때문이다. 실제 우리 집 EW11 로그로만 확정할 수 있다.

## 4. SmartThings Device / Capability 설계

| Device (profile) | Capability | 처리 Handler |
|---|---|---|
| `commax-bridge` | refresh | `discovery_handler`, `device_init` — EW11 연결·자식기기 생성 |
| `commax-light` | switch, refresh | `handle_switch_on/off` |
| `commax-thermostat` | thermostatMode, thermostatOperatingState, thermostatHeatingSetpoint, temperatureMeasurement, refresh | `handle_thermostat_mode`, `handle_heating_setpoint` |
| `commax-fan` | switch, fanSpeed, refresh | `handle_switch_on/off`, `handle_fan_speed` |
| `commax-gas` | valve, refresh | `handle_valve_close` (open은 항상 차단) |

데이터 흐름: `SmartThings Capability → device_handler.lua → commax_protocol.lua (패킷 생성) → ew11.lua (TCP 송신)`, 수신은 `ew11.lua (TCP 수신/프레이밍) → commax_protocol.lua (파싱) → device_handler.lua (Capability 이벤트 emit)`.

## 5. 프로젝트 구조

```text
commax-ew11-edge/
├── config.yml
├── profiles/
│   ├── commax-bridge.yml
│   ├── commax-light.yml
│   ├── commax-thermostat.yml
│   ├── commax-fan.yml
│   └── commax-gas.yml
├── src/
│   ├── init.lua              # 드라이버 라이프사이클, 자식기기 생성, 캡ability 라우팅
│   ├── device_handler.lua    # Capability ↔ 프로토콜 연결
│   ├── ew11.lua              # EW11 TCP 클라이언트, 프레이밍
│   ├── commax_protocol.lua   # 패킷 빌더/파서 (유일한 근거: homenet2mqtt)
│   └── bcd.lua                # BCD 인코딩/디코딩 (온도)
├── tests/
│   └── test_commax_protocol.lua
└── README.md
```

## 6. 설정값 (하드코딩 없음)

모든 접속 정보는 `commax-bridge` 기기의 Device Preference로 설정한다 (`profiles/commax-bridge.yml`):

| 설정 | 기본값 | 설명 |
|---|---|---|
| EW11 IP | `192.168.0.83` (예시) | 실제 우리 집 EW11의 IP로 반드시 변경 |
| EW11 Port | `8899` | EW11 웹 설정에서 지정한 TCP 포트와 일치해야 함 |
| Number of Lights | 4 | 실제 조명 개수(1~9)로 설정 |
| Number of Thermostats | 4 | 실제 난방 구역 수(0~9) |
| Enable Ventilation Fan | true | 참고 저장소 기준 구현(3절 주의사항 참고) |
| Enable Gas Valve | true | 상태조회 + 닫기만 |
| Heater Status Polling Interval | 10초 | 0으로 설정 시 폴링 비활성화 |

## 7. 설치 / 등록 / 테스트 방법

### 7.1 EW11 설정
1. EW11 웹 콘솔 접속 → Serial: 9600 / 8 / None / 1 로 설정
2. Communication: TCP Server 모드, 원하는 Local Port 지정 후 저장·재부팅

### 7.2 드라이버 패키징 및 설치 (SmartThings CLI)
```bash
smartthings edge:drivers:package commax-ew11-edge
smartthings edge:channels:assign <DRIVER_ID> --channel <CHANNEL_ID>
smartthings edge:drivers:install <DRIVER_ID> --hub <HUB_ID> --channel <CHANNEL_ID>
```

### 7.3 디바이스 생성
1. SmartThings 앱 → 기기 추가 → 주변 기기 검색
2. "코맥스 월패드 브릿지" 추가 → 설정에서 EW11 IP/Port/조명개수 등 입력
3. 저장 시 조명/난방/환기/가스 자식 기기가 자동 생성됨

### 7.4 패킷 테스트 (실제 월패드 없이 실행 가능)
```bash
lua tests/test_commax_protocol.lua
```
체크섬/패킷 생성/파싱을 모두 오프라인으로 검증한다. 실제 월패드 동작 여부는 이 테스트로 보장되지 않으며, EW11 연결 후 로그(`log.debug` TX/RX hex)로 실제 응답을 비교해야 한다.

## 8. 정보 불충분 항목 (추측하지 않고 보류한 부분)

```
정보 불충분 — 환기(팬) 상태 헤더의 정확한 값
- 현재 확인된 정보: fan_new.yaml의 문서 주석(0xF6/0xF7)과 실제 코드(마스크 0xF1==0xF0, ack 0xF8)가 표기상 다름
- 이 드라이버의 처리: 실제 코드(entities.fan)의 마스크 매칭 로직을 채택
- 추가로 필요한 테스트: 실제 환기 조작 시 EW11 로그로 헤더 값 확인

정보 불충분 — 가스밸브 열기(Open) 명령
- 현재 확인된 정보: 참고 저장소에 command_open 자체가 정의되어 있지 않음
- 이 드라이버의 처리: valve open 명령은 항상 차단하고 closed 상태로 되돌림 (handle_valve_open)

정보 불충분 — 조명 상태 능동 조회(query) 패킷
- 현재 확인된 정보: 조명에 대한 query/request 패킷은 참고 저장소에서 발견되지 않음 (난방만 heaters_request.yaml 존재)
- 이 드라이버의 처리: 조명은 refresh 요청 시에도 능동 질의를 보내지 않고, 월패드가 브로드캐스트하는 상태 패킷(B0/B1)만 수신해 반영

정보 불충분 — 동/호수 등 상위 주소 체계
- 현재 확인된 정보: 참고 저장소 패킷에는 기기군 Head + 기기 ID(1~9)만 존재, 상위 네트워크 주소 바이트는 없음
- 이 드라이버의 처리: 우리 집 EW11에 그대로 연결해서 동작 여부를 확인해야 하며, 세대별 ID 매핑이 다를 경우 lightCount/heaterCount 범위 내에서 실제 브로드캐스트를 관찰해 맞는 ID를 찾아야 함

정보 불충분 — 난방 상태 패킷의 ON/OFF 코드(byte1) ⚠️ 3개 저장소 교차검증 결과 전부 다름 (3.2절 참고)
- 현재 확인된 정보: 우리 기준(homenet2mqtt) = ON `81`/HEATING `83`, zooil/wallpad = ON `81`/OFF `84`, kimtc99/HAaddons(BySaram) = ON `81`/OFF `80`
- 이 드라이버의 처리: homenet2mqtt 값(81/83, 헤더 82)을 그대로 유지 (임의로 다른 저장소 값으로 덮어쓰지 않음)
- 다음 작업 시 참고: 실제 난방 조작 시 EW11 로그로 상태 패킷의 byte1 값을 확인해서 81/83/84/80 중 어느 것이 우리 집 난방기와 일치하는지 확정할 것. `src/commax_protocol.lua`의 `THERMO_OFF`/`THERMO_HEAT_IDLE`/`THERMO_HEATING` 상수를 그 결과에 맞게 수정

정보 불충분 — 환기 명령의 바이트 정렬(ID 위치) ⚠️ 교차검증 결과 불일치 (3.2절 참고)
- 현재 확인된 정보: 우리 기준 명령 `78 ID 01/02 PWR/SPD 00 00 00 [cs]`(byte1=ID). kimtc99/HAaddons(BySaram)의 실제 명령은 `78 01 01 04...`로 byte1이 고정값 `01`처럼 보여 ID 위치가 우리 기준과 다르게 해석될 여지가 있음
- 이 드라이버의 처리: homenet2mqtt(entities.fan) 값을 그대로 유지
- 다음 작업 시 참고: 환기팬이 여러 개가 아니라 1개뿐이라면 이 차이는 실질적으로 드러나지 않을 수 있음(ID=1 고정). 환기가 2개 이상인 세대라면 실제 로그로 ID 바이트 위치를 재확인할 것

정보 불충분 — 가스밸브 상태값(open/closed 바이트) ⚠️ 교차검증 결과 값 자체가 다름 (3.2절 참고, 안전 관련)
- 현재 확인된 정보: 우리 기준(homenet2mqtt) = open `80,80`/closed `40,40`. kimtc99/HAaddons(BySaram) = open `A0,A0`/closed `50,50`
- 이 드라이버의 처리: 두 값 모두 "정확히 0x80일 때만 open, 그 외 전부 closed로 간주"하는 fail-safe 파싱(`commax_protocol.lua`의 `is_open = (status == 0x80)`)이라 즉시 위험하지는 않지만, 우리 집 세대가 kimtc99 쪽 값을 쓴다면 현재 코드는 열림 상태를 감지하지 못하고 항상 "닫힘"으로 잘못 표시할 수 있음
- 다음 작업 시 참고: **반드시 실기 확인 후에만 값 변경**. 가스밸브를 실제로 열어본 뒤(안전한 상태에서) EW11 로그로 상태 패킷의 byte1/byte2 실제 값을 확인하고, `0x80`이 아니라면 `STATE_GAS` 파싱 로직을 그 값으로 교정할 것
```

## 9. 트러블슈팅

1. **소켓 연결 실패**: EW11이 TCP Server 모드인지, 허브와 같은 서브넷인지 확인.
2. **가스밸브 원격 열기 불가**: 의도된 동작이다 (8절, 안전상 미구현).
3. **환기 동작이 이상함**: 8절의 헤더 불일치 이슈 참고 — 실제 로그를 보고 필요 시 `commax_protocol.lua`의 `STATE_FAN_MASK`/`STATE_FAN_VALUE`를 조정해야 할 수 있다.
4. **난방 온도가 갱신되지 않음**: `Heater Status Polling Interval`을 5~10초로 설정하면 `0x02` 상태요청 패킷을 주기적으로 전송한다.
5. **동작 확인 관련 주의**: 이 문서와 코드의 모든 패킷은 참고 저장소 소스코드 분석에 근거하며, 실제 우리 집 월패드에서 100% 동일하게 동작함이 검증된 것은 아니다. 최초 연동 시에는 로그(`log.debug` TX/RX)를 반드시 확인하며 진행해야 한다.
6. **명령을 보냈는데 반영이 안 됨 / 씹힘**: 로그에 `Command failed: no ACK after N attempt(s)`가 보이면 재시도(기본 6회)까지 모두 실패한 것이다. RS485 버스 혼잡, EW11-월패드 배선 문제, 또는 ACK 패킷 자체가 우리 집 세대에서 다르게 오는 경우일 수 있다 — `log.debug`의 RX 로그로 실제 응답 패킷을 확인해 `commax_protocol.lua`의 `ack_*` 값과 비교해본다 (2.1절 참고).
7. **EW11이 장시간 꺼져 있었음**: 재연결은 5초→10초→…→최대 60초로 백오프하며 계속 시도하므로 별도 조치가 필요 없다. 연결이 복구되면 다음 명령부터 정상 동작한다.
8. **Preference에 잘못된 IP/Port를 입력함**: 로그에 `Invalid EW11 preferences`가 보이면 값이 비어있거나 포트가 1~65535 범위를 벗어난 것이다. Settings에서 값을 고치면 다음 저장 시 자동으로 재연결을 시도한다 (드라이버가 크래시하지 않는다).

## 10. 장애 대응 설계 (Driver Lifecycle / 장애 격리)

장시간(24시간 이상) 실행되는 월패드 연동 드라이버라는 전제로, 다음 방어 로직이 반영되어 있다.

- **오류 격리**: TCP 읽기 루프(`_connection_tick`), 명령 큐(`_tx_queue_tick`), 패킷 파싱(`parse_packet`), 개별 패킷의 상태 반영(`on_packet_cb`) 각각을 `pcall`로 감싸, 하나의 잘못된 패킷/명령/디바이스 오류가 드라이버 전체 또는 다른 디바이스에 영향을 주지 않는다. 특히 여러 패킷이 한 TCP read에 뭉쳐 들어온 경우(coalescing), 그중 하나의 콜백이 실패해도 나머지 패킷은 계속 처리된다.
- **버퍼 상한**: RS485 노이즈 등으로 유효한 8바이트 프레임이 전혀 나오지 않는 상황이 계속돼도 수신 버퍼가 512바이트를 넘으면 폐기하여 메모리 증가를 막는다.
- **명령 큐 상한**: 자동화 등으로 명령이 폭주해도 큐는 최대 20개까지만 유지하고, 넘치면 가장 오래된 명령을 버린다(최신 사용자 의도를 우선).
- **오프라인 중 재시도 소진 방지**: EW11 연결이 끊긴 동안에는 ACK 재시도 횟수를 소모하지 않고 재연결을 기다린다.
- **재연결 백오프**: 연결 실패 시 5초→10초→…→60초로 점점 늘려가며 재시도해 장애 시 로그 폭증과 불필요한 재시도를 줄인다.
- **Preference 검증**: EW11 IP/Port가 비어있거나 범위를 벗어나면 연결을 시도하지 않고 로그로만 알린다(무한 재시도 루프 방지).
- **Device 생성 격리**: 조명/난방/환기/가스 중 하나의 생성이 실패해도 나머지는 계속 생성된다.
- **중복 스케줄 방지**: `device_init`이 여러 번 호출돼도 난방 상태 폴링 스케줄은 한 번만 등록된다.
- **정보 불충분**: SmartThings Lua 런타임의 `driver:call_on_schedule` 타이머가 Device 삭제 시 자동으로 취소되는지, 그리고 Driver 프로세스 자체의 정확한 재시작/크래시 복구 동작은 실제 SmartThings Hub 환경에서만 확인 가능하며 이 저장소만으로는 검증할 수 없다.
