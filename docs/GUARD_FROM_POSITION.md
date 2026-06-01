# Guard-From-Position (нова механіка керування юнітами)

## TL;DR

Юніт ставиться у точку **A (home)** і охороняє віддалену зону **B (watch)**. Якщо ворог зайшов у B — юніт виходить з A, атакує, потім повертається в A. Якщо B затягнута туманом війни — поки розвідка її не освітить, юніт стоїть.

Реалізовано в гілці **GeneralsMD/** (Zero Hour), повністю мод-сумісно через INI.

## Що зроблено в коді (engine)

Деталі коміту/файлів — у git diff. Висока думка:

- `GameCommon.h` — нове значення `GUARDMODE_FROM_POSITION` у `GuardMode` enum.
- `AIGuard.h/cpp` — нове поле `m_attackFromPosition` у `AIGuardMachine` + getter/setter; xfer-версія підвищена з 2 до 3.
  - `AIGuardReturnState::onEnter()` повертається до `m_attackFromPosition` коли мод `FROM_POSITION`.
  - `AIGuardOuterState::onEnter()` поводиться як `WITHOUT_PURSUIT` коли мод `FROM_POSITION` (не переслідує за межі watch-зони).
  - Існуючий `lookForInnerTarget()` природно сканує `m_positionToGuard` (тобто watch-зону) — додаткових змін не треба.
- `AIUpdate.h/cpp`:
  - нове поле `m_attackFromLocation`,
  - нова virtual `privateGuardPositionFromPosition(homePos, watchPos, mode, src)`,
  - новий getter `getGuardAttackFromLocation()`,
  - дispatch case `AICMD_GUARD_POSITION_FROM_POSITION`,
  - xfer-версія підвищена 5→6 (під `RETAIL_COMPATIBLE_*` гардом, не ламає retail saves).
- `AI.h` — інлайн-обгортка `aiGuardPositionFromPosition`; нове enum-значення `AICMD_GUARD_POSITION_FROM_POSITION` додано в кінець (save-format safe).
- `AIGroup.h/cpp` — `groupGuardPositionFromPosition` за зразком `groupGuardPosition`.
- `AIStates.cpp` — `AIGuardState::onEnter()` передає `m_attackFromLocation` у `AIGuardMachine`.
- `MessageStream.h/cpp` — нове `MSG_DO_GUARD_POSITION_FROM_POSITION` (3 args: homeLoc, watchLoc, guardMode).
- `Core/GameLogicDispatch.cpp` — handler нового повідомлення, обгорнутий `#if RTS_ZEROHOUR` щоб не ламати Generals/ build.
- `ControlBar.h` — нове `GUI_COMMAND_GUARD_FROM_POSITION` + `"GUARD_FROM_POSITION"` у `TheGuiCommandNames[]`.
- `ControlBar.cpp` — у `ControlBar::init` додано додатковий load `Data\INI\OverrideCommandButton\` і `Data\INI\OverrideCommandSet\` у режимі `INI_LOAD_CREATE_OVERRIDES`. Це загальний "override-slot" для модерів: раніше переписати існуючий CommandSet через loose-INI було неможливо (engine кидав `INI_INVALID_DATA` на duplicate в `parseCommandSetDefinition`). Тепер достатньо покласти файл у `Data/INI/OverrideCommandSet/щось.ini` — він проходить через `newCommandSetOverride()` і чисто перекриває базовий запис.
- `GUICommandTranslator.cpp` — двофазовий `doGuardFromPositionCommand`: перший клік → зберігає home pos у `TheInGameUI`, лишається в pending-mode; другий клік → шле MSG із обома точками.
- `InGameUI.h/.cpp`:
  - поля `m_guardFromPositionHomePos`/`m_guardFromPositionHomeSet`/`m_guardFromPositionHomeDecal`,
  - публічні методи `setGuardFromPositionHome`/`clearGuardFromPositionState`/`hasGuardFromPositionHome`/`getGuardFromPositionHome`,
  - **візуалізація**: під час очікування 2-го кліку на сцені тримається `RadiusDecal` на home-позиції (реюз GUARD_AREA-декалі), а звичайний radius-курсор плаває під мишею як watch-зона.
  - `setGUICommand(nullptr)` тепер також очищає двокроковий стан (Esc / cancel правильно прибирає home-decal).

## Що треба додати у data-pack (`.gib` або `Data/INI/`)

Цей репо містить тільки C++. INI/Art/Texts тримаються окремо (для гри з оригінальним установленим ZH, для модів типу CWC — у своїх `.gib`). Нижче — точні INI-сніпети для додавання.

### 1. `Data/INI/CommandButton.ini` — нова кнопка

```ini
CommandButton Command_GuardFromPosition
  Command           = GUARD_FROM_POSITION
  Options           = NEED_TARGET_POS OK_FOR_MULTI_SELECT
  TextLabel         = CONTROLBAR:CommandGuardFromPosition
  DescriptLabel     = CONTROLBAR:ToolTipCommandGuardFromPosition
  ButtonImage       = SCCavalry_Guard       ; реюз існуючої Guard-іконки; замінити пізніше окремою артою
  CursorName        = Guard
  InvalidCursorName = GenericInvalid
  RadiusCursorType  = GUARD_AREA            ; реюз існуючої радіус-декалі
  ButtonBorderType  = ACTION
End
```

### 2. `Data/INI/CommandSet.ini` — додати до існуючих юнітів із Guard

Знайти всі `CommandSet`, що вже містять `Command_Guard` / `Command_GuardWithoutPursuit`, і вписати `Command_GuardFromPosition` у наступний вільний слот.

Приклад патерну (Crusader tank):

```ini
CommandSet AmericaTankCrusaderCommandSet
  1 = Command_AttackMove
  2 = Command_Stop
  3 = Command_Guard
  4 = Command_GuardFromPosition  ; <-- нове
End
```

Швидкий пошук вразливих CommandSet-ів:

```bash
grep -nE 'Command_Guard(WithoutPursuit|FlyingUnitsOnly)?$' Data/INI/CommandSet.ini
```

### 3. `Data/<lang>.str` — локалізація

```
CONTROLBAR:CommandGuardFromPosition
"Стояти й охороняти зону"
END

CONTROLBAR:ToolTipCommandGuardFromPosition
"Перший клік — позиція юніта (home). Другий клік — зона, яку охороняти. Коли ворог заходить у зону, юніт виходить атакувати з home і повертається назад коли загроза зникає."
END
```

(Англійська версія за бажанням, INI/Strings формат стандартний).

### 4. `Data/INI/GameData.ini` (опційно) — окрема декаль

Якщо хочеш візуально відрізнити home-зону від watch-зони (зараз обидві використовують GUARD_AREA), можна додати окрему RadiusCursor-декаль. Для цього треба:

- C++ зміна: додати `RADIUSCURSOR_GUARD_FROM_POSITION_HOME` у `RadiusCursorType` enum + `"GUARD_FROM_POSITION_HOME"` у `TheRadiusCursorNames[]` + новий рядок у `s_fieldParseTable` InGameUI.cpp.
- INI:
  ```ini
  GuardFromPositionHomeRadiusCursor
    Texture           = SCMRadiusDecalGuardArea   ; або власна текстура
    Style             = SHADOW_ALPHA_DECAL
    OpacityMin        = 35%
    OpacityMax        = 70%
    OpacityThrobTime  = 1000
    Color             = 0       ; 0 = колір гравця
  End
  ```

Поки що в коді `setGuardFromPositionHome()` явно бере шаблон `m_radiusCursors[RADIUSCURSOR_GUARD_AREA]`. Якщо додаси окремий тип — змінити цей індекс.

## Мод-сумісність (CWC та інші)

- Базова логіка C++ (`AIGuardMachine`, нова GuardMode, нові команди) увімкнена для всіх ZH-модів автоматично — це частина engine.
- Моди, які перевизначають CommandSet-и (як CWC у `_469_CWC.gib`), мусять самостійно додати `Command_GuardFromPosition` у потрібні юніти. Це звичайний INI-override через `INI_LOAD_CREATE_OVERRIDES` — без перекомпіляції моду.
- Якщо мод хоче змінити іконку, hot-key, чи параметри радіуса — це через override існуючого `CommandButton`/`RadiusCursor` за іменем.

## Verification (тестовий план)

1. **Smoke build (macOS Metal)** — переконатись що `cmake --build build` проходить без помилок.
2. **INI parse** — у `release/<...>/log.txt` не повинно бути `INI_INVALID_DATA` для `GUARD_FROM_POSITION` / нової CommandButton.
3. **UI**: у skirmish побудувати танк, переконатись що поруч із Guard зʼявилась нова кнопка Guard-From-Position.
4. **Двокроковий ввід**:
   - Клік на кнопку → курсор Guard, очікує клік.
   - Клік 1 (поряд із юнітом) → юніт **не рухається**, на терені залишається home-decal, курсор лишається guard, очікує клік 2.
   - Клік 2 (у віддалену зону) → юніт лишається у home-точці, watch-зона запамʼятовується.
5. **Фог-оф-вор**:
   - Дозор біля watch-зони. Ворожий юніт заходить → охоронець виїжджає з home, атакує.
   - Ворог іде з watch-зони → охоронець повертається у home (а не залишається на місці бою чи в центрі зони).
6. **Save/load (Xfer v3 на AIGuardMachine, v6 на AIUpdate)**: Зберегтись посеред режиму, завантажитись → юніт продовжує охороняти ту ж пару точок.
7. **Esc cancel**: активувати команду, зробити перший клік, натиснути Esc → home-decal зникає, режим виходить.
8. **CWC (опційно)**: запустити CWC, переконатись що:
   - кнопка не зʼявляється на CWC-юнітах за замовчуванням (CWC має свої CommandSet overrides),
   - якщо додати `Command_GuardFromPosition` у який-небудь CWC CommandSet, фіча працює без перекомпіляції моду.

## Майбутні TODOs (не входить у поточний MVP)

- **Hover preview на кнопці команди**: коли курсор наведено на Command_GuardFromPosition і виділений юніт уже в режимі FROM_POSITION — підсвітити його збережені home/watch зони. Потребує патчу `ControlBarCommand.cpp` (hover-state tracking) + нового методу `Drawable::getGuardFromPositionPair()` що читає `AIGuardMachine::getAttackFromPosition()` + `getPositionToGuard()`.
- **Окрема арта** для іконки кнопки (зараз — реюз `SCCavalry_Guard`) і окрема текстура декалі для home-зони (зараз — реюз GUARD_AREA).
- **AI player використання**: навчити комп'ютерного AI використовувати цю команду в захисних кластерах.
- **Generals/ (без ZH) parity**: дзеркалити зміни у `Generals/` дерево, якщо знадобиться.
- **AITNGuard** (тунельні юніти): свідомо НЕ підтримуємо — тунельні юніти обмежені топологією тунелю, фіча не має сенсу.
