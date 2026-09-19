# SmartThings Edge Driver for Commax Wallpad (via Elfin EW11)

코맥스(Commax) 아파트 월패드와 Elfin EW11(RS485 ↔ TCP 변환기)을 연동하여 SmartThings 허브에서 조명, 난방, 환기팬, 가스밸브, 콘센트, 공기질 센서, 엘리베이터 하강호출을 로컬 제어/모니터링하는 SmartThings Edge Driver입니다.

이 드라이버의 패킷 정의는 **직접 추측한 값이 아닙니다**. 초기에는 공개 저장소 [wooooooooooook/homenet2mqtt](https://github.com/wooooooooooook/homenet2mqtt)(`gallery/commax/*.yaml`), `zooil/wallpad`, `kimtc99/HAaddons`를 교차검증해 가설을 세웠지만, **지금 코드에 들어간 값은 대부분 우리 집 EW11에 직접 연결해 실측 캡처로 확정**한 것입니다. 참고 저장소끼리 값이 갈리거나(예: 난방 상태 코드, 가스밸브 상태값), 참고 저장소의 주장이 실측으로 반박된 경우(콘센트 attr=0x02 소비전력설)는 실측을 우선했습니다. 여전히 근거가 확인되지 않은 항목은 구현하지 않고 "정보 불충분"으로 남겨 두었습니다 (7절 참고).

---

### 📌 기기별 연동 및 안정화 상태

| 기기군 | 프로필 / 식별자 | 주요 기능 / Capability | 안정화 상태 | 비고 |
|---|---|---|:---:|---|
| **조명 (Light)** | `commax-light` (ID 1~8) | 전원 ON/OFF, 개별/일괄 제어 | **안정화 완료** | 8개 전 조명 실측 패킷 검증 및 실사용 안정화 |
| **콘센트 (Outlet)** | `commax-outlet` (ID 1~10) | 전원 ON/OFF (대기전력 차단 콘센트 제어) | **안정화 완료** | 10개 전 콘센트 실측 패킷 검증 및 실사용 안정화 |
| **보일러 / 난방 (Thermostat)** | `commax-thermostat` (ID 1~4) | 희망온도 설정, 현재온도 측정, 모드(꺼짐/난방) 제어 | **안정화 완료** | 꺼짐/난방 2가지 모드만 노출하는 전용 커스텀 VID 적용 완료 |
| **전열기 / 환기팬 (Fan)** | `commax-fan` (ID 1) | 전열교환기 환기팬 전원 ON/OFF, 풍량(1~3단) 조절 | **안정화 완료** | 전열(0x04) 기본 운전 모드 및 실시간 풍량 연동 안정화 |
| **엘리베이터 (Elevator)** | `commax-elevator` | 엘리베이터 하강 호출 (`elevatorCall`) | **안정화 완료** | 15ms 버스트 2회 연속 전송 + ACK 검증/재시도 + 0x23 이동상태 연동 |
| **가스밸브 (Gas)** | `commax-gas` (ID 1) | 밸브 상태 모니터링 및 원격 닫기 | 연동 지원 | 안전 규정에 따라 원격 닫기만 허용 (열기 불가) |
| **공기질 센서 (Air Quality)** | `commax-airquality` | 실시간 CO2, 미세먼지(PM2.5/PM10) 모니터링 | 연동 지원 | 수신 전용 모니터링 |

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
        ├─ 조명 (Light 1~8)
        ├─ 난방 온도조절기 (Thermostat 1~4)
        ├─ 환기팬 (Ventilation Fan)
        ├─ 가스밸브 (상태조회 + 닫기만)
        ├─ 콘센트 (Outlet 1~10)
        ├─ 공기질 센서 (CO2 / PM2.5 / PM10, 읽기전용)
        └─ 엘리베이터 하강호출 (별도 RS485-Matter 브릿지 경유)
```

## 2. EW11 통신 구조 설계

- EW11은 보통 **TCP Server**로 동작하므로, Edge Driver는 **TCP Client**로 EW11의 IP:PORT에 접속하는 구조를 사용한다 ([src/ew11.lua](src/ew11.lua)).
- SmartThings Edge Driver(Lua)는 `cosock` 코루틴 기반 소켓(`cosock.socket`)으로 LAN 접속이 가능하며, `config.yml`의 `permissions.lan`으로 LAN 접근 권한을 선언해야 한다.
- 연결은 끊어질 수 있으므로 재연결 루프, 논블로킹 조회(`settimeout`)로 지속적인 스트림 파싱을 구현했다. (`"*a"`로 전체 스트림을 한 번에 읽으면 연결이 끊기기 전까지 블로킹되므로 사용하지 않음.)
- 수신 스트림은 프레이밍 바이트가 없는 고정 8바이트 패킷이므로, 버퍼에 8바이트가 쌓일 때마다 체크섬을 검증해 유효하면 소비하고, 무효하면 1바이트씩 밀어서 동기화를 재획득한다 (`_process_buffer`).

### 2.1 RS485 버스 방어 처리 (명령 큐 / ACK / 재시도)

RS485는 반이중(half-duplex) 공유 버스라서, 다른 기기가 동시에 송신 중이면 명령이 충돌로 씹힐 수 있다 — 실제로 이 세션의 테스트 중에도 재시도가 여러 번 필요했던 사례가 다수 있었다. `src/ew11.lua`에 다음 방어 로직이 반영되어 있다:

- **명령 큐 직렬화**: 여러 명령이 들어와도 `tx_queue`에 쌓아 두고 한 번에 하나씩만 전송한다 (`_tx_queue_loop`). 하나가 끝나야(ACK 성공 또는 재시도 소진) 다음 명령을 보낸다.
- **ACK 대기 + 재시도**: 각 명령에는 확정된 ACK 바이트 프리픽스를 붙여 보내고(`commax_protocol.lua`의 `ack_*` 함수들), 그 프리픽스로 시작하는 유효 패킷이 수신될 때까지 기다린다. 일정 시간(`tx_timeout`, 기본 200ms) 안에 ACK이 없으면 `tx_delay`(기본 10ms) 대기 후 재전송하며, 총 시도 횟수는 `tx_retry_cnt + 1`(기본 6회)이다. 모두 실패하면 예외를 던지지 않고 경고 로그만 남긴다.
- **rx_timeout(수신 버퍼 폐기)**: 마지막 수신 이후 `rx_timeout`(기본 10ms)을 초과해 새 데이터가 들어오면, 남아있던 불완전한 조각을 버리고 새로 시작한다.
- **버스 유휴(idle) 감지 후 송신**: 마지막 수신 후 100ms 이내에는 명령을 보내지 않고 대기한다(`_bus_busy`). 월패드나 다른 서브 컨트롤러가 막 버스를 사용한 직후에 끼어들면 충돌로 프레임이 깨질 수 있기 때문이다.
- 이 값들(`tx_retry_cnt`/`tx_timeout`/`tx_delay`/`rx_timeout`/버스 유휴 100ms)은 참고 저장소들의 기본값을 그대로 사용했다. 우리 집 환경에서 명령이 자주 씹히거나 반대로 응답이 늦게 온다면 `src/ew11.lua`의 `DEFAULT_TX_*`/`rx_timeout`/`BUS_IDLE_GUARD` 값을 조정해야 할 수 있다.

## 3. 코맥스 패킷 구조

모든 패킷은 **8바이트 고정 길이**이며, 별도의 시작/종료 프레이밍 바이트는 없다. 각 기기군의 Head 바이트 자체가 패킷 종류를 구분한다.

```
[Index 0]     Head        기기군 + 상태/명령 구분 코드
[Index 1~6]   Data        ID, ON/OFF, 온도(BCD), 속도 등 (기기별 위치 다름)
[Index 7]     Checksum    Index 0~6의 8-bit 합산 (add) & 0xFF
```

체크섬: `sum(byte[0..6]) & 0xFF` ([src/commax_protocol.lua](src/commax_protocol.lua) `calculate_checksum`). 상위 네트워크 주소(동/호수 등) 바이트는 확인되지 않았다 — 각 기기군은 "Head + 기기 ID"만으로 구분된다.

아래 표는 **현재 코드(`src/commax_protocol.lua`)에 실제로 구현된 값**만 정리한 것이다. 각 값의 실측/근거 상태는 표의 "출처" 열에, 조사 과정(참고 저장소 간 불일치, 반박된 가설 등)은 6절 "조사 히스토리"에 남겨두었다.

### 3.1 조명 (`commax:light`, ID 1~8)

| 항목 | 패킷 | 출처 |
|---|---|---|
| 명령 ON/OFF | `31 ID PWR(01=ON/00=OFF) 00 00 00 00 [cs]` | 실측 확정 |
| 상태 조회 | `30 ID 00 00 00 00 00 [cs]` | 실측 확정 (`build_light_query`) |
| 상태 | `B0 PWR ID 00 00 00 00 [cs]` | 실측 확정 |
| ACK | `B1 PWR ID 00 00 00 00 [cs]` | 실측 확정 |

### 3.2 난방 (`commax:thermostat`, ID 1~4)

| 항목 | 패킷 | 출처 |
|---|---|---|
| 전원 명령 | `04 ID 04 PWR(81=난방/00=끄기) 00 00 00 [cs]` | 실측 확정 |
| 전원 ACK | `84 ACK_PWR(81=난방/80=끄기) ID 00 00 00 00 [cs]` | 실측 확정 — OFF 명령 페이로드는 `00`이지만 ACK 값은 `80`으로 서로 다름 |
| 온도 명령 | `04 ID 03 BCD(온도) 00 00 00 [cs]` | 실측 확정 |
| 온도 ACK | `84 00 ID 00 00 00 00 [cs]` | 실측 확정 |
| 상태 조회 | `02 ID 00 00 00 00 00 [cs]` | 실측 확정 |
| 상태 | `82 MODE ID 현재온도(BCD) 목표온도(BCD) 00 00 [cs]` | MODE 값별로 아래 표 참고 |

**MODE 바이트(byte1)**:

| 월패드 모드 | 값 | 상태 |
|---|---|---|
| 끄기 | `0x80` | 실측 확정 |
| 난방(대기) / 타이머 | `0x81` | 실측 확정 — 타이머는 byte1로 구분 안 됨(일반 난방과 동일값), 지속시간은 버스에 안 실림 |
| 외출 | `0x84` | 실측 확정 — `ACK_THERMO` 헤더값과 같은 바이트지만 위치(헤더 vs 페이로드)가 달라 충돌 없음 |
| 예약 | `0x00` | 실측 확정 |
| 가동중(실제 발열) | `0x83` | **추정** — 목표온도를 현재보다 높여(27→30도) 1분 대기해도 재현 안 됨. 정보 불충분(7절) |

외출/예약/타이머 모두 SmartThings에는 대응 상태가 없어 OFF/IDLE과 동일하게 표시된다.

### 3.3 환기팬 (`commax:fan`, ID 1)

| 항목 | 패킷 | 출처 |
|---|---|---|
| 전원 명령 | `78 ID 01 PWR(04=ON/00=OFF) 00 00 00 [cs]` | 실측 확정 |
| 속도 명령 | `78 ID 02 SPEED(1~3) 00 00 00 [cs]` | 실측 확정 (`build_fan_speed`가 1~3으로 clamp) |
| 상태 | `F[x] MODE ID SPEED 00 00 00 [cs]` | 헤더는 `(byte&0xF1)==0xF0` 마스크 매칭 |
| ACK | `F8 04`(ON/speed) 또는 `F8 00`(OFF) | 실측 확정 |

**MODE 바이트(byte1, 속도와 별개)**:

| 모드 | 값 | 상태 |
|---|---|---|
| OFF | `0x00` | 실측 확정 |
| 전열(heat-exchange) | `0x04` | 실측 확정 |
| 바이패스 | `0x07` | 실측 확정 |
| 자동 | `0x02` | 실측 확정 |
| 취침 | `0x04`(전열과 동일) | 별도 모드값 없음. 대신 항상 0이던 뒷 3바이트에 카운트다운으로 추정되는 값이 채워짐(`...01 08 00`→`...01 07 3B`→`...01 07 3A`) — 인코딩 미해독, 파싱 안 함 |

`is_on = (mode_byte ~= 0x00)`은 이 모든 모드값에서 올바르게 동작한다. 모드 자체는 SmartThings에 별도 노출하지 않으며, ON 명령은 항상 전열(`0x04`)로 보낸다.

### 3.4 가스밸브 (`commax:gas`, ID 1, 항상 닫힘 운용)

| 항목 | 패킷 | 출처 |
|---|---|---|
| 닫기 명령 | `11 01 80 00 00 00 00 [cs]` | 실측 확정 — 열기 명령은 정의 자체가 없어 의도적으로 미구현 |
| 닫기 ACK | `91 88 88 00 00 00 00 [cs]` | 실측 확정 |
| 상태 | `90 STATUS STATUS 00 00 00 00 [cs]` | 닫힘=`0x50`(실측 확정), 열림=`0xA0`(**미실측**, kimtc99 근거) |

`is_open`은 fail-safe하게 구현됨: 정확히 `GAS_OPEN(0xA0)`과 일치할 때만 open, 그 외는 전부 closed로 간주 — 열림 바이트가 실제로 다르더라도 "닫혀있는데 열림으로 오탐"하는 일은 없다.

### 3.5 콘센트 (`commax:outlet`, ID 1~10)

| 항목 | 패킷 | 출처 |
|---|---|---|
| 명령 | `7A ID 01 PWR(01=ON/00=OFF) 00 00 00 [cs]` | 실측 확정(10개 전부 개별 검증) |
| 조회 | `79 ID ATTR(01) 00 00 00 00 [cs]` | 실측 확정 |
| 상태 | `F9 PWR(11=ON/10=OFF) ID ATTR 00 00 ? [cs]` | 실측 확정 |
| ACK | `FA PWR(11=ON/10=OFF) ID 00 00 00 ? [cs]` | 실측 확정 |

- attr(4번째 바이트)는 `01`만 사용(전원 상태). attr `02`는 homenet2mqtt가 소비전력(BCD, watts) 이라고 문서화했지만, **헤어드라이어 실부하로 실측 반박됨** — 30초 이상 작동시켜도 항상 `00 00 00`으로 불변. 실제 의미는 불명, 파싱하지 않음.
- 콘센트 ACK/상태 헤더(`0xF9`/`0xFA`)는 우연히 환기팬의 비트마스크(`&0xF1==0xF0`)에도 걸리므로, `parse_packet`에서 환기 분기보다 먼저 명시적으로 제외 처리한다(실제로 겪었던 오파싱 버그를 수정한 것).

### 3.6 공기질 센서 (`commax:airquality`, 읽기전용, 명령 없음)

| 항목 | 패킷 | 출처 |
|---|---|---|
| CO2 | `F7 82 01 00 1A [BCD hi][BCD lo] [cs]` | 실측 확정 — 월패드 화면 숫자와 실시간 대조(1313→1235→1223→1221 추적), 값은 마지막 2바이트(6-7번째) |
| PM2.5 | `C8 11 01 [BCD hi][BCD lo] 00 01 [cs]` | 2026-09-19 정정 — `tools/capture_20260917_175929.log` 실측 재검토 결과 `0x31`은 로그에 한 번도 없었고 `0x11`/`0x1F`가 27회 등장, 값 위치도 4-5번째 바이트로 정정. **PM2.5/PM10 중 어느 쪽이 `0x11`인지는 미확인** — 월패드 화면과 대조해서 확인 필요 |
| PM10 | `C8 1F 01 [BCD hi][BCD lo] 00 01 [cs]` | 위와 동일. `0x39`/`0x3F` 모두 이 캡처에는 등장하지 않음 |

CO2는 마지막 2바이트(6-7번째), PM2.5/PM10은 4-5번째 바이트를 2바이트 BCD 숫자로 디코딩(`bcd.decode_word`)한다 — 위치가 서로 다르니 주의.

**PM1.0(초미세먼지) 관련**: 45분 분량의 실측 캡처 전체에서 `0xC8` 헤더의 서브바이트는 `0x11`/`0x1F` 두 종류만 발견되었고 세 번째 값은 없었다. 즉 이 월패드/EW11 버스에는 PM1.0을 별도로 방송하는 패킷이 아예 존재하지 않는 것으로 보인다 — 코드 누락이 아니라 하드웨어가 PM1.0을 이 프로토콜로 노출하지 않을 가능성이 높다. 월패드 화면에 PM1.0 수치가 실제로 표시되는지, 그리고 표시된다면 그 값이 변할 때 버스에 어떤 새 패킷이 뜨는지 재확인이 필요하다.

### 3.7 엘리베이터 하강호출 (`commax:elevator`, `elevatorCall` capability, 상승 미구현)

| 항목 | 패킷 | 출처 |
|---|---|---|
| 하강호출 명령 | `22 01 40 07 00 00 00 6A` | 실측 확정 |
| ACK | `A2 01 01 00 00 00 00 A4` | 실측 확정 |
| 이동/호출 중 상태 | `23 01 40 00 00 00 00 64` | 실측 확정 (호출 중 주기적 브로드캐스트) |

- 월패드 자체 버튼은 이 RS485 버스에 아무 흔적을 안 남긴다(다른 경로 통신 추정). 사용자가 보유한 "브릿지허브"(RS485↔Matter 변환기)로 호출했을 때만 버스에 명령이 실린다.
- **물리 타이밍 요구사항 (15ms 연속 버스트)**: 월패드는 2개 패킷(`22 01 40 07 00 00 00 6A`)이 **12~20ms 이내 간격**으로 연속 도착해야만 하강 호출을 인정한다. 개별 큐잉 시 ACK 대기 지연(수백 ms)으로 인해 인식이 실패하므로, EW11 큐에서 15ms 간격 원자적(atomic) 버스트로 전송하고 이후 ACK를 대기/재시도한다.
- **0x23 상태 패킷 연동**: 엘리베이터가 실제 호출되어 이동 중일 때 월패드가 주기적으로 0x23 패킷을 브로드캐스트한다. 4초 타이머로 수신 중단(도착)을 감지해 `standby` 상태로 자동 복원된다.
- **실패 롤백**: ACK 타임아웃 및 재시도 소진 시 `on_fail` 콜백을 통해 즉시 `standby`로 롤백된다.
- 상승호출은 미구현: 브릿지허브 앱 자체에 상승 기능이 없어 테스트 경로가 없다(7절 참고).

## 4. 알려진 프로토콜 충돌 (구현에 영향 없음, 참고용)

이 집에는 사용하지 않지만 같은 버스에 존재가 확인된 "일괄소등/점등" 스위치가 엘리베이터와 **동일한 0x22/0xA2 헤더**를 쓴다:

```
일괄소등: 명령 22 01 00 01 00 00 00 24 / ACK A2 00 01 00 00 00 00 A3
일괄점등: 명령 22 01 01 01 00 00 00 25 / ACK A2 01 01 00 00 00 00 A4
```

일괄점등의 ACK(`A2 01 01 00 00 00 00 A4`)는 엘리베이터 하강호출 ACK와 **체크섬까지 완전히 동일한 패킷**이다 — 파싱으로 구분할 방법이 없는, 월패드 프로토콜 자체의 값 충돌이다. 실사용 영향은 미미하다: 하강호출 ACK 대기 중(초 단위)에 우연히 일괄점등이 눌리면 TX 큐가 재시도를 한 번 덜 할 수 있지만, 이미 명령을 2번 보내므로 호출 자체가 무효화되지는 않고, 엘리베이터 ACK는 어떤 SmartThings 이벤트에도 매핑되지 않아 조명 쪽에 잘못된 상태가 표시되지도 않는다. 일괄소등/점등은 사용자가 쓸 계획이 없어 기기로 구현하지 않았다.

## 5. SmartThings Device / Capability 설계

| Device (profile) | Capability | 처리 Handler |
|---|---|---|
| `commax-bridge` | refresh | `discovery_handler`, `device_init` — EW11 연결·자식기기 생성 |
| `commax-light` | switch, refresh | `handle_switch_on/off` |
| `commax-thermostat` | thermostatMode, thermostatOperatingState, thermostatHeatingSetpoint, temperatureMeasurement, refresh | `handle_thermostat_mode`, `handle_heating_setpoint` |
| `commax-fan` | switch, fanSpeed, refresh | `handle_switch_on/off`, `handle_fan_speed` |
| `commax-gas` | valve, refresh | `handle_valve_close` (open은 항상 차단) |
| `commax-outlet` | switch, refresh | `handle_switch_on/off` |
| `commax-airquality` | carbonDioxideMeasurement, dustSensor, veryFineDustSensor, refresh | 명령 없음(읽기 전용) |
| `commax-elevator` | elevatorCall | `handle_elevator_call` (하강, 15ms 버스트 2회 전송 + ACK 검증) |

데이터 흐름: `SmartThings Capability → device_handler.lua → commax_protocol.lua (패킷 생성) → ew11.lua (TCP 송신)`, 수신은 `ew11.lua (TCP 수신/프레이밍) → commax_protocol.lua (파싱) → device_handler.lua (Capability 이벤트 emit)`.

### 5.1 방 매핑 (전등/콘센트/난방 ID → 실제 위치)

전등은 하나씩 켜서, 콘센트는 하나씩 꺼서(평소 다 켜져 있어 끄는 쪽이 더 눈에 띔), 난방은 4개를 각각 다른 목표온도(21/22/23/24도)로 설정해서 실시간으로 확인했다. "안방"은 이 집에서 조명·콘센트·난방 라벨에 "곰돌이"라는 애칭으로 쓰인다(같은 방).

| ID | 전등 (`commax:light`) | 콘센트 (`commax:outlet`) | 난방 (`commax:thermostat`) |
|---|---|---|---|
| 1 | 거실보조불 | 거실커텐콘센트 | 거실난방 |
| 2 | 거실불 | 안방(곰돌이) | 곰돌이난방(=안방) |
| 3 | 곰돌이불 | 곰돌이창문콘센트 | 하트난방 |
| 4 | 곰돌이보조불 | 곰돌이콘센트 | 별별이난방 |
| 5 | 하트불 | 하트커텐콘센트 | — |
| 6 | 별별이불 | 하트콘센트 | — |
| 7 | 주방불 | 별별이커텐콘센트 | — |
| 8 | 주방간접등 | 별별이콘센트 | — |
| 9 | — | 주방밥솥콘센트 | — |
| 10 | — | 주방가스렌지콘센트 | — |

**주의**: 세 기기군의 ID는 서로 독립적인 번호 체계다(예: 콘센트 2번=안방, 난방 2번도 우연히 같은 방(곰돌이=안방)이지만 전등 2번은 거실). 같은 숫자라고 같은 방을 가리키지 않으니 이 표로만 대조할 것. `src/init.lua`의 `LIGHT_LABELS`/`OUTLET_LABELS`/`THERMOSTAT_LABELS`에 반영되어 있다(새로 생성되는 Device에만 적용, 이미 등록된 기존 Device는 자동 재라벨링 안 됨).

## 6. 조사 히스토리 (참고용 — 현재 값은 3절이 최종)

패킷 신뢰도를 높이기 위해 진행했던 과정을 기록으로 남겨둔다. **지금 코드가 실제로 사용하는 값은 3절이며, 이 절은 "왜 그 값이 됐는지"의 배경 설명이다.**

### 6.1 타 오픈소스 저장소 교차검증

| 기능 | 우리 값(현재) | zooil/wallpad | kimtc99/HAaddons | 결과 |
|---|---|---|---|---|
| 조명 ON/OFF | `31`/`B0`/`B1` | 동일 | 동일 | 일치 → 그대로 채택, 실측으로도 재확인 |
| 난방 ON/OFF 명령 | `04 ID 04 81/00...` | 동일 | 동일 | 일치 → 그대로 채택 |
| 난방 상태 코드(byte1) | `80`/`81`/`83`/`84`/`00` | `81`/`84` | `81`/`80` | 3곳 모두 다름 → 실측으로 전부 재확정(3.2절) |
| 환기 명령 바이트 정렬 | `78 ID 01/02 ...` | 미구현 | `78 01 01 04...`(ID 위치가 다르게 보임) | 우리 집엔 환기팬이 1개뿐이라 실질적 영향 없음, homenet2mqtt 값 유지 |
| 가스밸브 상태값 | 닫힘=`50` | 미구현 | 닫힘=`50`/열림=`A0` | kimtc99와 실측이 일치 → 채택 (homenet2mqtt의 `40`은 우리 집에서 틀렸음) |
| 체크섬 알고리즘 | 바이트 단순합 & 0xFF | 코드 미노출 | 니블 분리 합산(다른 알고리즘) | 우리 실측과 일치하는 단순합 방식 유지 |

### 6.2 실측으로 정정된 값

- **가스밸브 닫힘**: homenet2mqtt는 `0x40`이라 했으나 실측은 `0x50` (kimtc99와 일치) → 코드 정정
- **PM10 서브바이트**: homenet2mqtt 문서는 `0x39`이나 실측은 `0x3F` → 코드 정정
- **콘센트 명령 헤더**: 사용자가 예전에 남겨둔 메모에는 `79`로 되어 있었으나(실제로는 조회 헤더), 실측 결과 명령 헤더는 `7A`

### 6.3 실측으로 반박된 가설

- **콘센트 attr=0x02 = 소비전력**(homenet2mqtt `smart_plugs_new.yaml`의 BCD 공식): 헤어드라이어 실부하로도 값이 전혀 안 변해 반박됨(3.5절)
- **환기 취침모드 = 0x06**(homenet2mqtt 설명표): 실측 결과 취침모드는 별도 값 없이 전열과 동일한 `0x04`였음(3.3절). 다만 같은 표의 자동모드 `0x02`는 실측과 정확히 일치

## 7. 정보 불충분 항목 (추측하지 않고 보류한 부분)

| 항목 | 현재 상태 |
|---|---|
| 난방 가동중(실제 발열, `0x83`) | 목표온도를 현재보다 높여(27→30도) 1분 대기해도 재현 안 됨. SmartThings 표시상 idle로 남아도 실제 난방 동작엔 지장 없어 우선순위 낮춤. 겨울철 등 자연스럽게 오래 가동될 때 우연히 캡처하는 편이 나을 수 있음 |
| 가스밸브 열림(`0xA0`) | 우리 집 밸브가 실제로 열린 패킷을 관측 못함(항상 닫힘 운용). fail-safe 설계라 값이 틀려도 안전 위험은 없음 |
| 엘리베이터 상승호출 | 브릿지허브 앱에 상승 기능 자체가 없어 테스트 경로 없음. 하강 명령의 byte3/byte4(`40`/`07`)가 방향을 뜻하는지도 불확실해 임의로 값을 바꿔 만들어내지 않음 |
| 콘센트 attr=0x02의 실제 의미 | 소비전력이 아님은 확인됨(반박). 진짜 의미는 불명 |
| 상위 주소 체계(동/호수 등) | 참고 저장소·실측 모두 "기기군 Head + ID"만 확인됨, 상위 주소 바이트 없음 |
| SmartThings capability ID 정확성 | 이 개발 환경에 SmartThings SDK가 없어 `carbonDioxideMeasurement`/`dustSensor`/`veryFineDustSensor` 등의 정확한 속성명을 검증 못함. 실제 Hub 설치 후 확인 필요 |
| 환기팬 취침모드 뒷바이트 | 카운트다운 타이머로 추정되나 정확한 인코딩 불명. 제어에 불필요해 파싱 안 함 |

## 8. 프로젝트 구조

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
│   ├── init.lua              # 드라이버 라이프사이클, 자식기기 생성(+방 라벨), 캡ability 라우팅
│   ├── device_handler.lua    # Capability ↔ 프로토콜 연결
│   ├── ew11.lua              # EW11 TCP 클라이언트, 프레이밍, TX큐/ACK/재시도
│   ├── commax_protocol.lua   # 패킷 빌더/파서 (유일한 근거: 실측 + 참고 저장소)
│   └── bcd.lua                # BCD 인코딩/디코딩 (온도, CO2, PM2.5/PM10)
├── tools/
│   ├── capture_ew11.ps1      # 실제 EW11 패킷 캡처/로깅 진단 스크립트(읽기전용)
│   └── probe_packet.ps1      # 후보 패킷 1개를 직접 보내보는 진단 스크립트
├── tests/
│   ├── test_commax_protocol.lua
│   └── test_ew11_buffer.lua
└── README.md
```

## 9. 설정값 (하드코딩 없음)

모든 접속 정보는 `commax-bridge` 기기의 Device Preference로 설정한다 (`profiles/commax-bridge.yml`):

| 설정 | 기본값 | 설명 |
|---|---|---|
| EW11 IP | (예시값, 실제 IP로 반드시 변경) | 실제 우리 집 EW11의 IP로 반드시 변경 |
| EW11 Port | `8899` | EW11 웹 설정에서 지정한 TCP 포트와 일치해야 함 |
| Number of Lights | 4 | 실제 조명 개수(0~8)로 설정 (이 집은 8) |
| Number of Thermostats | 4 | 실제 난방 구역 수(0~9) (이 집은 4) |
| Number of Outlets | 10 | 실제 콘센트 개수(0~10)로 설정 (이 집은 10) |
| Enable Elevator Down-Call | true | 하강 호출 버튼(momentary), 상승은 미구현 |
| Enable Ventilation Fan | true | |
| Enable Gas Valve | true | 상태조회 + 닫기만 |
| Enable Air Quality Sensor | true | CO2/PM2.5/PM10 (읽기 전용) |
| Heater Status Polling Interval | 10초 | 0으로 설정 시 폴링 비활성화 |

## 10. 설치 / 등록 / 테스트 방법

### 10.1 EW11 설정
1. EW11 웹 콘솔 접속 → Serial: 9600 / 8 / None / 1 로 설정
2. Communication: TCP Server 모드, 원하는 Local Port 지정 후 저장·재부팅

**보안 주의사항**: 이 TCP 포트는 별도의 인증 계층이 없다 — 접속만 되면 누구나 조명/콘센트/난방/엘리베이터 호출 등을 제어하는 원본 패킷을 보낼 수 있다. 공유기 포트포워딩 등으로 외부(인터넷)에서 접근 가능하게 노출하지 말고, SmartThings 허브와 같은 신뢰할 수 있는 내부 LAN에서만 접근 가능하도록 구성한다.

### 10.2 드라이버 패키징 및 설치 (SmartThings CLI)
```bash
smartthings edge:drivers:package commax-ew11-edge
smartthings edge:channels:assign <DRIVER_ID> --channel <CHANNEL_ID>
smartthings edge:drivers:install <DRIVER_ID> --hub <HUB_ID> --channel <CHANNEL_ID>
```

### 10.3 디바이스 생성
1. SmartThings 앱 → 기기 추가 → 주변 기기 검색
2. "코맥스 월패드 브릿지" 추가 → 설정에서 EW11 IP/Port/조명개수 등 입력
3. 저장 시 조명/난방/환기/가스/콘센트/공기질/엘리베이터 자식 기기가 자동 생성됨(방 이름 라벨 포함, 5.1절 참고)

### 10.4 패킷 테스트 (실제 월패드 없이 실행 가능)
```bash
lua -e "package.path = 'src/?.lua;' .. package.path" tests/test_commax_protocol.lua
cd tests && lua -e "package.path = 'mocks/?.lua;mocks/?/init.lua;../src/?.lua;' .. package.path" test_ew11_buffer.lua
cd tests && lua -e "package.path = 'mocks/?.lua;mocks/?/init.lua;../src/?.lua;' .. package.path" test_ew11_queue.lua
cd tests && lua -e "package.path = 'mocks/?.lua;mocks/?/init.lua;../src/?.lua;' .. package.path" test_init_lifecycle.lua
```
체크섬/패킷 생성/파싱, TCP 버퍼 프레이밍(단편화/병합/노이즈 재동기화), TX 큐 직렬화/재시도/드롭 정책 및 ACK 매칭(알려진 프로토콜 충돌 포함, 4절 참고), driver 생명주기(브릿지 삭제/재등록 시 히터 폴링 재등록 여부)를 모두 오프라인으로 검증한다. 실제 월패드 동작 여부는 이 테스트로 보장되지 않으며, EW11 연결 후 실측 캡처(`tools/capture_ew11.ps1`)로 실제 응답을 비교해야 한다.

### 10.5 실측 캡처 도구 사용법

새 기기를 추가하거나 미확인 값을 검증할 때는 항상 이 순서를 따른다:

1. `tools/capture_ew11.ps1 -Ip <EW11_IP> -Port <PORT>`로 버스를 수동 관찰
2. 실제로 기기를 조작(월패드 또는 앱)하면서 명령→ACK→상태 변화를 전부 대조
3. 명령 헤더가 조회 헤더와 다를 수 있으므로(콘센트가 조회=`0x79`, 명령=`0x7A`로 서로 달랐던 사례) 반드시 실제 조작으로 확인
4. 후보 패킷 하나만 직접 보내 반응을 볼 때는 `tools/probe_packet.ps1 -Ip <IP> -Port <PORT> -HexBytes "..."` 사용 (읽기 전용이 아니므로 상태를 바꿀 수 있는 명령임을 인지하고 사용)

## 11. 트러블슈팅

1. **소켓 연결 실패**: EW11이 TCP Server 모드인지, 허브(또는 이 드라이버를 실행하는 장치)와 같은 서브넷인지 확인. IP가 바뀌었을 수도 있다(DHCP) — EW11 자체 설정 화면에서 재확인.
2. **가스밸브 원격 열기 불가**: 의도된 동작이다 (7절, 안전상 미구현).
3. **난방 온도가 갱신되지 않음**: `Heater Status Polling Interval`을 5~10초로 설정하면 `0x02` 상태요청 패킷을 주기적으로 전송한다.
4. **명령을 보냈는데 반영이 안 됨 / 씹힘**: 로그에 `Command failed: no ACK after N attempt(s)`가 보이면 재시도(기본 6회)까지 모두 실패한 것이다 — RS485 버스가 혼잡한 상황(다른 명령이 동시에 오가는 등)에서 실제로 자주 발생한다. 대개 재시도만으로 해결되며, 계속 실패하면 `log.debug`의 RX 로그로 실제 응답 패킷을 `commax_protocol.lua`의 `ack_*` 값과 비교한다 (2.1절 참고).
5. **EW11이 장시간 꺼져 있었음**: 재연결은 5초→10초→…→최대 60초로 백오프하며 계속 시도하므로 별도 조치가 필요 없다. 연결이 복구되면 다음 명령부터 정상 동작한다.
6. **Preference에 잘못된 IP/Port를 입력함**: 로그에 `Invalid EW11 preferences`가 보이면 값이 비어있거나 포트가 1~65535 범위를 벗어난 것이다. Settings에서 값을 고치면 다음 저장 시 자동으로 재연결을 시도한다(드라이버가 크래시하지 않는다).
7. **엘리베이터를 눌렀는데 조명이 잠깐 이상하게 반응하는 것 같음**: 4절의 0x22/0xA2 헤더 충돌 참고 — 실사용에는 지장 없는 수준이다.

## 12. 장애 대응 설계 (Driver Lifecycle / 장애 격리)

장시간(24시간 이상) 실행되는 월패드 연동 드라이버라는 전제로, 다음 방어 로직이 반영되어 있다.

- **오류 격리**: TCP 읽기 루프(`_connection_tick`), 명령 큐(`_tx_queue_tick`), 패킷 파싱(`parse_packet`), 개별 패킷의 상태 반영(`on_packet_cb`) 각각을 `pcall`로 감싸, 하나의 잘못된 패킷/명령/디바이스 오류가 드라이버 전체 또는 다른 디바이스에 영향을 주지 않는다. 특히 여러 패킷이 한 TCP read에 뭉쳐 들어온 경우(coalescing), 그중 하나의 콜백이 실패해도 나머지 패킷은 계속 처리된다.
- **버퍼 상한**: RS485 노이즈 등으로 유효한 8바이트 프레임이 전혀 나오지 않는 상황이 계속돼도 수신 버퍼가 512바이트를 넘으면 폐기하여 메모리 증가를 막는다.
- **명령 큐 상한**: 자동화 등으로 명령이 폭주해도 큐는 최대 20개까지만 유지하고, 넘치면 가장 오래된 명령을 버린다(최신 사용자 의도를 우선).
- **오프라인 중 재시도 소진 방지**: EW11 연결이 끊긴 동안에는 ACK 재시도 횟수를 소모하지 않고 재연결을 기다린다.
- **재연결 백오프**: 연결 실패 시 5초→10초→…→60초로 점점 늘려가며 재시도해 장애 시 로그 폭증과 불필요한 재시도를 줄인다.
- **Preference 검증**: EW11 IP/Port가 비어있거나 범위를 벗어나면 연결을 시도하지 않고 로그로만 알린다(무한 재시도 루프 방지).
- **Device 생성 격리**: 조명/난방/환기/가스/콘센트/공기질/엘리베이터 중 하나의 생성이 실패해도 나머지는 계속 생성된다.
- **중복 스케줄 방지**: `device_init`이 여러 번 호출돼도 난방 상태 폴링 스케줄은 한 번만 등록된다.
- **정보 불충분**: SmartThings Lua 런타임의 `driver:call_on_schedule` 타이머가 Device 삭제 시 자동으로 취소되는지, 그리고 Driver 프로세스 자체의 정확한 재시작/크래시 복구 동작은 실제 SmartThings Hub 환경에서만 확인 가능하며 이 저장소만으로는 검증할 수 없다.
