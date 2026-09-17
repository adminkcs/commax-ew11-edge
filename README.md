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

### 3.3 실제 EW11 캡처로 확정된 값 (2026-09-16, `tools/capture_ew11.ps1`)

실제 조작 없이 버스를 몇 분간 수신 대기만 한 캡처에서도 다음이 **우리 집 하드웨어 기준으로 직접 확정**됐다 (더 이상 "정보 불충분" 아님):

| 항목 | 실측 값 | 이전 상태 | 결과 |
|---|---|---|---|
| 조명 상태(`B0 00 ID...`) | 정확히 일치 | 확정 | 그대로 유지 |
| **조명 조회 패킷(`30 ID 00...`)** | `30 01 00 00 00 00 00 31` 등, ID 순차 폴링 실제 확인 | 이전에 "근거 없음"으로 제거(`REQ_LIGHT`) | **복원**: `commax_protocol.lua`에 `REQ_LIGHT=0x30`, `build_light_query()` 재추가, `handle_refresh`에서 다시 사용 |
| 난방 상태 헤더 `82`, OFF=`80`, HEAT_IDLE=`81` | `82 80 02 27 05...`, `82 81 01 28 12...` 그대로 관측 | homenet2mqtt 기준값과 동일 | **확정**(단, 실제 가동 중 `83`은 이번 캡처에는 없어 여전히 미확인) |
| 난방 조회 패킷(`02 ID`) | 정확히 일치 | 확정 | 그대로 유지 |
| 환기 상태 `F6`, OFF | `F6 00 01 00 00 00 00 F7` | 확정 | 그대로 유지 (ON/속도는 여전히 미관측) |
| **가스밸브 상태값** | `90 50 50 00 00 00 00 30`(닫힘) | 3.2절에서 homenet2mqtt(`40,40`)와 kimtc99(`50/A0`)가 불일치했던 항목 | **정정**: 실측이 kimtc99 값과 일치 → `GAS_CLOSED=0x50`로 코드 수정. `GAS_OPEN=0xA0`은 직접 관측은 못했지만 같은 소스가 닫힘값을 정확히 맞혔으므로 신뢰도 상향, 다만 열림은 여전히 "정보 불충분"으로 8절에 유지 |

이 캡처에서 추가로 관측됐지만 **이번 개발 범위(조명/난방/환기/가스) 밖**이라 구현하지 않은 장치:

- 콘센트/플러그로 추정되는 주기적 상태(`79`/`F9`, 매우 빈번)
- 월패드 자체의 시각 브로드캐스트로 추정(`7F 26 09 16 23 43 ...` → BCD로 "2026-09-16 23:43:xx"와 캡처 시각이 일치)
- 일괄소등/조명 차단기로 추정(`20`/`A0`)

이 장치들은 실제 필요성이 확인되면 추후 별도로 분석 후 추가할 수 있다.

### 3.4 공기질 센서(CO2/PM2.5/PM10) — 실측으로 확정 및 추가 (2026-09-17)

3.3절에서 "헤더 불일치로 보류"했던 공기질 센서를 **월패드 화면 숫자와 실시간으로 직접 대조**해서 확정했다.

| 항목 | 패킷 | 실측 검증 방법 | 결과 |
|---|---|---|---|
| CO2 | `F7 82 01 00 1A [BCD hi][BCD lo] [cs]` | 월패드가 "1313"→"1235"→"1223"→"1221"로 표시하는 순간마다 캡처값의 마지막 2바이트가 정확히 같은 숫자로 일치(BCD 2바이트 = ppm) | **확정** |
| PM2.5 | `C8 31 01 ?? ?? [BCD hi][BCD lo] [cs]` | 월패드 PM2.5=1 표시 시점에 `C8 31 01 13 13 00 01 21` 관측, 마지막 2바이트 BCD=`0001`=1 | **확정** |
| PM10 | `C8 3F 01 ?? ?? [BCD hi][BCD lo] [cs]` | 월패드 PM10=1 표시 시점에 `C8 3F 01 13 13 00 01 2F` 관측, 마지막 2바이트 BCD=`0001`=1 | **확정**(단, 두 번째 바이트가 homenet2mqtt 문서의 `0x39`가 아니라 `0x3F` — 우리 집 모델 실측값 사용) |

값 인코딩은 homenet2mqtt `haatz_air_quality_sensors.yaml`이 설명한 "마지막 2바이트를 BCD 2바이트 숫자로 디코딩"(`bcd.decode_word`) 규칙과 정확히 일치했다. 다만 discovery 헤더의 두 번째/세 번째 바이트는 문서와 다르고, 우리 실측값(`F7 82 01`, `C8 31 01`, `C8 3F 01`)을 그대로 코드에 반영했다.

`commax-airquality` 프로필(SmartThings 표준 capability: `carbonDioxideMeasurement`, `dustSensor`(PM10 → `fineDustLevel`), `veryFineDustSensor`(PM2.5 → `veryFineDustLevel`))로 읽기 전용 센서 Device를 추가했다. 명령은 없다(원래 이 장치는 상태 브로드캐스트만 존재).

### 3.5 콘센트 10개 — 명령/응답 실측으로 완전 확정 (2026-09-17)

이전에 사용자가 갖고 있던 옛 패킷 기록(참고용, 정확성 불확실)을 근거로 삼지 않고, **콘센트 1~10번을 실제로 하나씩 켜고 끄면서 명령→ACK→상태 변화를 전부 직접 캡처**해서 확정했다.

```
명령 OFF: 7A ID 01 00 00 00 00 [cs]
명령 ON:  7A ID 01 01 00 00 00 [cs]
응답 OFF: FA 10 ID 10 00 00 00 [cs]
응답 ON:  FA 11 ID 10 00 00 00 [cs]
상태:     F9 (10=OFF/11=ON) ID 10 00 00 ?? [cs]
조회:     79 ID 01 00 00 00 00 [cs]
```

콘센트 1번을 끄고 켰을 때, 명령 직후 정확히 예상한 ACK(`FA 10.../FA 11...`)와 이후 폴링 상태(`F9 10.../F9 11...`)가 그대로 바뀌는 것을 확인했다. 이어서 콘센트 1~10번(ID `01`~`0A`) 전부를 순서대로 껐다 켰을 때, 동일한 공식(`7A ID 01 PWR 00 00 00`, 체크섬은 ID가 늘어날수록 정확히 +1)이 10개 전부에서 그대로 성립하는 것을 확인했다 — ID 파라미터화된 하나의 프로토콜임이 실측으로 완전히 검증됨.

`commax-outlet` 프로필(capability: `switch`, `refresh`)로 `commax:outlet:1~10` Device를 추가했다. Bridge Preference `outletCount`(기본 10, 최대 12)로 개수를 조정할 수 있다.

> 참고: 사용자가 예전에 남겨둔 패킷 기록에는 콘센트 명령 헤더가 `79`로 (실측 결과 `79`는 조회 헤더, 실제 명령은 `7A`), 난방 명령 헤더가 `A0`으로 (실측 결과 `A0`은 콘센트/조명차단기 계열의 다른 장치, 난방 명령은 기존에 이미 확정된 `04`) 기록되어 있었다 — 옛 기록과 실측이 다른 경우 실측을 신뢰한다는 원칙을 여기서도 재확인했다.

### 3.6 엘리베이터 하강 호출 — 실측 확정 및 추가 (2026-09-17)

월패드 자체의 호출 버튼은 이 RS485 버스에 아무 패킷도 남기지 않았다(다른 경로로 통신하는 것으로 추정). 반면 사용자가 별도로 보유한 "브릿지허브"(RS485↔Matter 변환 기기)로 하강 호출을 실행했을 때는 이 버스에도 명령이 그대로 실렸다 — 우리 EW11이 같은 버스를 듣고 있으므로 관측 가능했다.

```
명령: 22 01 40 07 00 00 00 6A
응답: A2 01 01 00 00 00 00 A4
```

**중요한 실측 디테일**: 버튼을 한 번 눌러도 이 명령이 **정확히 2번, 약 12ms 간격으로, 각각 개별 ACK를 받으며** 전송되는 것을 반복 확인했다(단발 호출 테스트로 재현). 그래서 이 드라이버도 추측 없이 실측 그대로 **2번 전송**하도록 구현했다(`handler.handle_elevator_call_down`이 `safe_send`를 두 번 호출).

호출 직후 `23 01 01 04 07 00 00 30`(상태) / `A3 01 01 00 00 00 00 A5`가 도착 여부와 무관하게 계속(약 1초 간격) 반복 관측됐는데, 이는 실시간 층수가 아니라 고정 상태값/폴링으로 보여 파싱하지 않았다(파싱해도 의미를 알 수 없는 값을 SmartThings에 노출하지 않기 위함).

`commax-elevator` 프로필(capability: `momentary`)로 `commax:elevator:1` Device를 추가했다. 버튼을 누르면(`push` 명령) 하강 호출 명령을 2번 전송한다. **상승(위) 호출은 구현하지 않았다** — 8절 "정보 불충분" 참고. Bridge Preference `enableElevator`(기본 true)로 이 Device 생성 여부를 조정할 수 있다.

**확정된 헤더 충돌 (2026-09-17)**: 같은 집의 "일괄소등/점등" 스위치도 동일한 0x22/0xA2 헤더를 쓴다.

```
일괄소등: 명령 22 01 00 01 00 00 00 24 / 응답 A2 00 01 00 00 00 00 A3
일괄점등: 명령 22 01 01 01 00 00 00 25 / 응답 A2 01 01 00 00 00 00 A4
```

일괄점등의 응답(A2 01 01 00 00 00 00 A4)은 엘리베이터 하강호출 응답과 체크섬까지 완전히 동일한 패킷이다 — 파싱 로직으로 구분할 방법이 없는, 월패드 프로토콜 자체의 근본적인 값 충돌이다. 실사용 영향은 미미하다: 하강호출 ACK 대기 중(초 단위) 우연히 일괄점등이 눌리면 TX 큐가 재시도를 한 번 덜 할 수 있지만, 이미 명령을 2번 보내므로 호출이 무효화되지는 않고, 엘리베이터 ACK는 어떤 SmartThings 이벤트에도 매핑되지 않아 조명 쪽에 잘못된 상태가 표시되지도 않는다. 일괄소등/점등 자체는 **기기로 구현하지 않기로 결정**(사용 안 할 예정).

### 3.7 난방 모드 바이트 전수 확정 (2026-09-17)

안방(thermostat ID 2)의 월패드 조작판에서 모드를 하나씩 바꿔가며 실측, `82 xx 02 ...` 상태 패킷의 byte1(mode) 값을 전부 대조했다:

| 월패드 모드 | byte1 값 | 비고 |
|---|---|---|
| 끄기 | `0x80` | 기존 확정값과 일치 |
| 외출 | `0x84` | **신규 확정** — `ACK_THERMO` 헤더값(0x84)과 같은 바이트지만 패킷 내 위치(헤더 vs 페이로드)가 달라 충돌 없음 |
| 난방(대기) | `0x81` | 기존 확정값과 일치 |
| 타이머 | `0x81` | **byte1로는 구분 안 됨** — 일반 난방과 완전히 동일한 값. 타이머 지속시간은 버스에 실리지 않는 것으로 보임(월패드 내부 관리로 추정). 별도 상태로 취급하지 않음 |
| 예약 | `0x00` | **신규 확정** |
| 가동중(발열) | `0x83`(추정) | 목표온도를 현재온도보다 높게(27→30도) 설정해 30초~1분 대기했지만 관측 안 됨(보일러 지연 또는 다른 조건 필요) — 실사용에 지장 없어 추가 실측은 보류, 계속 "정보 불충분"으로 유지 |

외출/예약/타이머 모두 SmartThings에는 별도 상태가 없어 기존 OFF/IDLE과 동일하게 표시된다(`src/commax_protocol.lua`의 `THERMO_AWAY`/`THERMO_RESERVE` 주석 참고). 이 과정에서 **콘센트 ID 2 = 안방**도 확인됐다(3.5절 대비 방 매핑 정보 추가).

### 3.8 환기팬 ON/속도/모드 전수 확정 (2026-09-17)

기존에는 OFF(`F6 00 01...`)만 확인돼 있었다. 실제로 켜고 1~3단, 그리고 전열/바이패스/자동/취침 모드를 하나씩 눌러가며 상태 패킷(`F6 [mode] 01 [speed] ...`)을 대조했다:

| 항목 | 값 | 비고 |
|---|---|---|
| ON, 전열, 1단 | `F6 04 01 01 00 00 00 FC` | |
| ON, 전열, 2단 | `F6 04 01 02 00 00 00 FD` | |
| ON, 전열, 3단 | `F6 04 01 03 00 00 00 FE` | speed 필드(byte3)가 그대로 1/2/3 — 기존 파싱 로직과 정확히 일치, 코드 변경 없음 |
| ON, 바이패스 | `F6 07 01 03...` | mode 값만 `0x04`→`0x07`로 변경, speed는 그대로 유지 |
| ON, 자동 | `F6 02 01 01 00 00 00 FA` | homenet2mqtt `fan_new.yaml` 설명표의 "Auto=0x02"와 정확히 일치 |
| 취침 | `F6 04 01 01 01 07 3B 3F` (예시) | byte1은 전열과 동일(`0x04`) — 별도 모드값 없음. 대신 이전엔 항상 0이던 뒤 3바이트가 채워지고 폴링마다 감소(`...01 08 00`→`...01 07 3B`→`...01 07 3A`) — 취침 타이머 카운트다운으로 추정되나 정확한 인코딩은 불확실. 제어에 필요 없어 파싱하지 않음 |

`is_on = (mode_byte ~= 0x00)` 조건은 이 네 가지 모드값(0x02/0x04/0x07, 취침도 0x04) 전부에서 올바르게 동작해 코드 변경이 필요 없었다. 모드(전열/바이패스/자동) 자체는 SmartThings에 별도 capability로 노출하지 않으며, 이 드라이버가 ON 명령을 보낼 때는 항상 전열(`0x04`)로 켠다.

## 4. SmartThings Device / Capability 설계

| Device (profile) | Capability | 처리 Handler |
|---|---|---|
| `commax-bridge` | refresh | `discovery_handler`, `device_init` — EW11 연결·자식기기 생성 |
| `commax-light` | switch, refresh | `handle_switch_on/off` |
| `commax-thermostat` | thermostatMode, thermostatOperatingState, thermostatHeatingSetpoint, temperatureMeasurement, refresh | `handle_thermostat_mode`, `handle_heating_setpoint` |
| `commax-fan` | switch, fanSpeed, refresh | `handle_switch_on/off`, `handle_fan_speed` |
| `commax-gas` | valve, refresh | `handle_valve_close` (open은 항상 차단) |
| `commax-airquality` | carbonDioxideMeasurement, dustSensor, veryFineDustSensor, refresh | 명령 없음(읽기 전용, `handle_parsed_packet`만) |
| `commax-outlet` | switch, refresh | `handle_switch_on/off` |
| `commax-elevator` | momentary | `handle_elevator_call_down` (하강만, 2회 전송) |

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
│   ├── commax-gas.yml
│   ├── commax-airquality.yml
│   ├── commax-outlet.yml
│   └── commax-elevator.yml
├── src/
│   ├── init.lua              # 드라이버 라이프사이클, 자식기기 생성, 캡ability 라우팅
│   ├── device_handler.lua    # Capability ↔ 프로토콜 연결
│   ├── ew11.lua              # EW11 TCP 클라이언트, 프레이밍
│   ├── commax_protocol.lua   # 패킷 빌더/파서 (유일한 근거: homenet2mqtt + 실측)
│   └── bcd.lua                # BCD 인코딩/디코딩 (온도, CO2, PM2.5/PM10)
├── tools/
│   └── capture_ew11.ps1      # 실제 EW11 패킷 캡처/로깅 진단 스크립트
├── tests/
│   ├── test_commax_protocol.lua
│   └── test_ew11_buffer.lua
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
| Number of Outlets | 10 | 실제 콘센트 개수(0~12), 2026-09-17 10개 전부 실측 확정 |
| Enable Elevator Down-Call | true | 하강 호출 버튼(momentary), 상승은 미구현 |
| Enable Ventilation Fan | true | 참고 저장소 기준 구현(3절 주의사항 참고) |
| Enable Gas Valve | true | 상태조회 + 닫기만 |
| Enable Air Quality Sensor | true | CO2/PM2.5/PM10 (읽기 전용) |
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

정보 불충분 — 엘리베이터 상승(위) 호출
- 2026-09-17 하강 호출은 완전히 실측 확정되어 `commax-elevator` Device(momentary)로 구현됨 — 아래 3.6절 참고
- 상승 호출 패킷은 확인 못함: 브릿지허브 앱에 위 호출 기능 자체가 없어서 테스트 불가(물리적으로는 존재하나 앱에서 지원 안 함)
- 이 드라이버의 처리: 구현하지 않음(하강만 지원). 하강 명령의 byte3/byte4(`40`/`07`)가 방향을 나타내는 값인지, 다른 의미인지도 불확실하므로 그 값을 바꿔서 "상승"을 임의로 만들어내지 않음
- 다음 작업 시 참고: 상승 호출 기능이 있는 다른 방법(월패드 등)으로 실측하게 되면 `40`/`07` 값 변화를 대조해서 방향 구분 로직을 확정할 것

정보 불충분 — 조명 상태 능동 조회(query) 패킷
- 현재 확인된 정보: 조명에 대한 query/request 패킷은 참고 저장소에서 발견되지 않음 (난방만 heaters_request.yaml 존재)
- 이 드라이버의 처리: 조명은 refresh 요청 시에도 능동 질의를 보내지 않고, 월패드가 브로드캐스트하는 상태 패킷(B0/B1)만 수신해 반영

정보 불충분 — 동/호수 등 상위 주소 체계
- 현재 확인된 정보: 참고 저장소 패킷에는 기기군 Head + 기기 ID(1~9)만 존재, 상위 네트워크 주소 바이트는 없음
- 이 드라이버의 처리: 우리 집 EW11에 그대로 연결해서 동작 여부를 확인해야 하며, 세대별 ID 매핑이 다를 경우 lightCount/heaterCount 범위 내에서 실제 브로드캐스트를 관찰해 맞는 ID를 찾아야 함

정보 불충분 — 난방 상태 패킷의 "실제 가동 중(HEATING)" 코드(byte1=0x83)만 남음
- 2026-09-16 실측 캡처로 헤더 `0x82`와 OFF(`0x80`)/HEAT_IDLE(`0x81`)은 **확정됨** (3.3절 참고) — zooil(`84`)/kimtc99(`80`)와 교차검증에서 불일치했던 부분은 실측으로 우리 값(homenet2mqtt, `81`/`83`)이 OFF/IDLE 쪽은 맞다고 확인됨
- 2026-09-17 외출(`0x84`)/예약(`0x00`)/타이머(구분 없음, `0x81`과 동일)까지 추가 확정 (3.7절 참고) — 이제 `0x83`(실제 발열 중)만 남음
- 2026-09-17 목표온도를 현재온도보다 높게(27→30도) 설정해 최대 1분 정도 대기하며 재시도했지만 byte1 변화 없음 — 보일러 작동까지의 지연이 더 길거나 다른 조건(예: 특정 시간대 제한)이 있을 수 있음. SmartThings 표시상으로는 idle로 남아도 실제 난방 동작 자체엔 지장이 없어 우선순위를 낮춤
- 다음 작업 시 참고: 겨울철 등 난방이 자연스럽게 오래 가동되는 시기에 우연히 캡처해서 확인하는 편이 인위적으로 재현하려 애쓰는 것보다 나을 수 있음

정보 불충분 — 환기 명령의 바이트 정렬(ID 위치) ⚠️ 교차검증 결과 불일치 (3.2절 참고)
- 현재 확인된 정보: 우리 기준 명령 `78 ID 01/02 PWR/SPD 00 00 00 [cs]`(byte1=ID). kimtc99/HAaddons(BySaram)의 실제 명령은 `78 01 01 04...`로 byte1이 고정값 `01`처럼 보여 ID 위치가 우리 기준과 다르게 해석될 여지가 있음
- 이 드라이버의 처리: homenet2mqtt(entities.fan) 값을 그대로 유지. 2026-09-17 실측 캡처로 환기 ON/속도/모드는 완전히 확정됐지만(3.8절 참고), 그 테스트도 환기가 1개뿐인 우리 집 기준이라 ID 정렬 자체는 여전히 미확인
- 다음 작업 시 참고: 환기팬이 여러 개가 아니라 1개뿐이라면 이 차이는 실질적으로 드러나지 않을 수 있음(ID=1 고정). 환기가 2개 이상인 세대라면 실제 로그로 ID 바이트 위치를 재확인할 것

**반박됨 — 환기팬 auto(0x02)/night(0x06) 바이트를 그대로 믿을 수 있다는 가정**
- 참고: 이 항목은 실측으로 오히려 **부분 확인**됐다. 자동모드는 정확히 `0x02`로 확정(3.8절). 다만 취침(night)모드는 `0x06`이 아니라 `0x04`(전열과 동일)로 나왔고, 대신 뒷바이트에 타이머로 추정되는 값이 붙는 방식이었다 — homenet2mqtt 설명표의 `0x06` 값은 우리 집 기준으로는 틀렸다

**반박됨 — 콘센트 attr 0x02가 소비전력(W)이라는 설**
- 출처: homenet2mqtt `gallery/commax/smart_plugs_new.yaml` — `79 ID 02...` 조회의 응답 `F9 [PWR] ID 0x20 [D1][D2][D3]`을 BCD 소비전력(`(D1*10000+D2*100+D3)*0.1` W)으로 해석하는 공식
- **2026-09-17 실측으로 반박**: 1번 콘센트에 헤어드라이어(수백W급 실부하)를 꽂고 30초 이상 작동시켰지만, attr=0x02 응답은 켜기 전/도중/후 내내 `F9 11 01 20 00 00 00 2B`(D1~D3 전부 0x00)로 전혀 변하지 않았다. 다른 idle 콘센트들과 완전히 동일한 값 — 이 필드는 소비전력이 아니거나, 최소한 이 공식/바이트 위치로는 표현되지 않는다
- 이 드라이버의 처리: attr 0x02는 여전히 파싱/노출하지 않음 (의미 불명, `src/commax_protocol.lua`의 `build_outlet_query` 주석 참고). 실제 의미를 알아내려면 다른 접근(예: 개통 시 설치기사용 진단 모드, 다른 attr 값 탐색 등)이 필요 — 현재로선 우선순위 낮음

정보 불충분 — 가스밸브 OPEN 바이트(0xA0)만 남음 (CLOSED는 실측 확정, 안전 관련)
- 2026-09-16 실측 캡처로 `GAS_CLOSED=0x50`은 **확정됨** (3.3절 참고) — 3.2절에서 불일치했던 homenet2mqtt(`40`) 값은 우리 집에서는 틀린 것으로 확인되어 코드에서 교체함
- 현재 확인된 정보: `GAS_OPEN=0xA0`은 kimtc99/HAaddons에서만 확인된 값이며, 우리 집 밸브가 실제로 열린 상태의 패킷은 아직 관측하지 못함(캡처 당시 밸브가 계속 닫혀 있었음)
- 이 드라이버의 처리: "정확히 0xA0일 때만 open, 그 외 전부 closed로 간주"하는 fail-safe 파싱을 유지 — 열림 바이트가 실제로 다르더라도 항상 "닫힘"으로만 잘못 표시될 뿐, 닫혀있는데 "열림"으로 잘못 표시될 위험은 없음
- 다음 작업 시 참고: 가스밸브가 실제로 열려 있는 상태(예: 밸브를 잠깐 원상태로 열어야 하는 상황이 생겼을 때)에 EW11 로그를 확인해서 상태 패킷의 byte1/byte2가 정말 `0xA0`인지 검증할 것

정보 불충분 — 공기질 센서 Device의 SmartThings capability 이름 미검증
- 2026-09-17 실측으로 CO2/PM2.5/PM10 패킷 자체는 확정됐다(3.4절 참고). 다만 `profiles/commax-airquality.yml`과 `device_handler.lua`에서 사용한 SmartThings 표준 capability(`carbonDioxideMeasurement.carbonDioxide`, `dustSensor.fineDustLevel`, `veryFineDustSensor.veryFineDustLevel`)는 이 개발 환경에 SmartThings SDK가 없어 **정확한 capability/속성 이름을 실제로 검증하지 못했다**
- 다음 작업 시 참고: 실제 SmartThings CLI로 드라이버를 설치한 뒤, 공기질 Device 타일에서 CO2/PM2.5/PM10 값이 정상적으로 표시되는지 확인할 것. capability 이름이 틀렸다면 SmartThings 개발자 문서의 정확한 capability id로 `commax-airquality.yml`과 `device_handler.lua`의 이벤트 emit 코드를 수정해야 함
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
