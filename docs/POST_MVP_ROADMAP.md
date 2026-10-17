# Emacs Agent после MVP: выводы из Pi/Pigo и план развития

**Статус:** F0, F0b, F0c, ограниченный F1, lifecycle/UI F2, минимальный F3, F4 и F6 реализованы; F5 отложен;
инструментированные live F2/F4 smoke ещё отдельно. Устранён измеренный секундный pretty-print
autosave stall. 252 offline ERT и byte compilation с
warnings-as-errors проходят. Для буферного редактирования F0 есть пользовательский
live smoke и подтверждение undo; отдельный live smoke F0b ещё не выполнялся.
Остальные post-MVP этапы не реализованы.

**Основание:** обсуждение после завершения MVP, этапов 0–5.

**Граница:** документ дополняет [MVP-спецификацию](EMACS_AGENT_SPEC.md), не заменяет её.

## 1. Исходное состояние и неизменяемые принципы

В базе реализованы глобальная/проектные истории, снимки редакторского контекста,
FIFO run, отмена, возобновление после tool budget, streaming, read-only журнал,
валидированный Chat Completions replay и атомарное сохранение/восстановление.
Последний подтверждённый прогон перед этим документом: 58 ERT-тестов,
warning-as-error byte compilation; проверены отдельный свежий batch Emacs и
реальное продолжение загруженного диалога с LLM. Это не новый прогон проверок.
Подробности и ограничения: [GPTEL_INTEGRATION.md](GPTEL_INTEGRATION.md).

Сохраняем:

- один unrestricted `eval_elisp` в живом общем Emacs;
- отсутствие sandbox и обязательных подтверждений каждого действия;
- разделение разговоров, а не полномочий или редакторских объектов;
- gptel как транспорт, авторизацию и provider layer, без собственной HTTP-копии;
- отсутствие неявных изменений глобальных gptel settings/tools/hooks;
- последовательное исполнение Elisp, независимое ожидание LLM разных сессий;
- отсутствие автоматического повторного выполнения после восстановления;
- штатные Emacs-команды, completion, буферы и keymaps вместо копирования TUI.

Расширение возможностей не означает расширение обещаний совместимости:
Responses, Anthropic, Gemini и opaque replay остаются вне текущей границы,
пока отдельный адаптер не исследован и не проверен.

### 1.1. Согласованное изменение: новая глобальная сессия после restart

При каждом новом запуске Emacs активной глобальной сессией становится новый
пустой разговор с отдельным conversation ID. Предыдущая глобальная сессия
остаётся сохранённой: её можно найти в списке и явно выбрать для продолжения.
Её история не подмешивается автоматически в новый разговор, а файл не
перезаписывается новой сессией.

В пределах одного запуска непроектные буферы разделяют выбранную глобальную
сессию. Повторная загрузка пакета, показ журнала или переключение буфера не
создают новых разговоров. Если пользователь выбрал старую глобальную сессию,
она становится текущей до следующего явного выбора или restart; следующий
запуск Emacs снова начинает новый глобальный разговор.

Реализовано в F6: проектный выбор сохраняется, global choice — только на запуск.
Это относится к F6 schema-3 разговорам. Pre-F6 root-level файлы остаются
нетронутым архивом и не импортируются по явному решению пользователя.

### 1.2. Согласованное изменение: новый разговор вручную

Пользователь может явно начать новую пустую сессию в текущем global/project
scope, не перезапуская Emacs. Реализована команда `emacs-agent-session-new`. Новый разговор получает новый conversation ID
и становится выбранным в этом scope. Старая сессия сохраняется и остаётся
доступной в списке для просмотра и продолжения.

Это не очистка/сброс истории и не clone: история старого разговора и его
ожидающие задачи не переносятся в новый. Перед переключением старая сессия
должна быть успешно сохранена; при ошибке записи переключение не выполняется,
а пользователь получает понятное сообщение. В F6 involved conversations должны
быть idle: без active/paused, очереди, compaction или prepared/queued inputs.
Withdrawn recovery остаётся у старого разговора. Нет автоматической отмены,
переноса очереди или повторного исполнения.

## 2. Что исследовано и насколько подтверждены выводы

### Pi

Checkout: `/home/np/projects/personal/pi/pi`, исследованная ревизия `cdaf6c227`.
Изучены документация, полный `packages/agent/src/agent-loop.ts`, обработка
ограниченного tool output и релевантные части очередей, загрузчика ресурсов,
проекции истории и compaction. Это исследование, не полный аудит репозитория.

### Pigo

Checkout: `/home/np/projects/personal/pi/pigo`, HEAD `a190107` **с незакоммиченными
изменениями**. Выводы относятся к прочитанному рабочему дереву, а не только HEAD.
Изучены README, архитектура, профильные ADR, полный generation kernel,
application run, steering, подготовка/выполнение compaction, контекстные файлы,
provider contract и выбранные тесты. Тесты Pigo не запускались; реальные
провайдеры не вызывались; private credentials/config/session files не читались.

| Область | Ориентиры Pi, относительно checkout | Ориентиры Pigo, относительно checkout |
|---|---|---|
| Generation/run и границы очередей | `packages/agent/src/agent-loop.ts`; `packages/coding-agent/src/core/agent-session.ts` | `internal/agent/agent.go`; `internal/app/run.go`; `internal/app/steering.go` |
| Архив и model projection | `packages/coding-agent/src/core/session-manager.ts`; `docs/session-format.md` внутри coding-agent | `internal/session/session.go`; `docs/adr/0003-session.md` |
| Compaction и бюджет | `packages/coding-agent/src/core/compaction/compaction.ts`; `docs/compaction.md` внутри coding-agent | `internal/compaction/compaction.go`; `internal/app/compact.go`; `docs/adr/0009-compaction-and-budget.md` |
| Инструкции, skills, templates | `packages/coding-agent/src/core/{resource-loader,skills,prompt-templates}.ts` | `internal/prompts/`; `docs/adr/0010-resources-and-search.md`; `docs/adr/0029-agent-skills.md` |
| Вывод инструментов | `packages/coding-agent/src/core/tools/{truncate,bash}.ts` | `internal/tools/`; описанный контракт Bash artifacts в README |
| Capabilities и thinking | model/settings documentation coding-agent | `provider/provider.go`; `docs/adr/0022-thinking-level.md` |
| Расширения | extension API coding-agent | `extension/`; `docs/adr/0008-extension-contract.md` и его amendments |

Реализация циклов, steering, budgeting и compaction подтверждена чтением кода,
а не только наличием планов. Для иных возможностей использованы документация
и карта исходников; перед переносом необходимо прочитать конкретную реализацию
и тесты. Не выдавать этот список за проверку всех заявленных контрактов.

## 3. Сводные выводы

### 3.1. Переносить принципы, не интерфейс терминала

Главная ценность Pi — управление контекстом и ходом работы, а не наличие
отдельных `read/edit/bash` tools. Pigo показывает, что это можно выразить
небольшими явными контрактами без универсального framework расширений.

В Emacs нужны команды с completion и обычные буферы; slash/colon-команды,
терминальный редактор, OAuth UI, RPC и Go/TypeScript plugin hosts не нужны.

Pigo разделяет kernel одной генерации и controller полного run. Нам полезна
граница ответственности: lifecycle, подготовка контекста и dispatch принадлежат
controller, UI наблюдает события. Но gptel уже управляет tool continuations;
не копировать Go-loop буквально и не строить второй конкурирующий планировщик.

### 3.2. Архив, model context и UI — три разных представления

Pi строит `buildSessionProjection()` поверх сохранённых записей. Context edits
и summary меняют будущий запрос, но не переписывают исходный архив.
Pigo отдельно определяет durable records, branch projection и runtime events.

Для нас:

- сохранённые оригинальные сообщения/результаты остаются доступными;
- фильтрация context metadata, summary и будущие ветки выполняются в проекции;
- folding, скрытие reasoning и preview clipping не меняют API-данные;
- временный progress не становится модельным сообщением;
- не следует бессрочно сохранять каждое progress/stream уведомление только
  потому, что оно нужно UI. Изменение текущего хранения deltas — отдельная
  проверяемая эволюция схемы, а не немедленная перепись MVP.

### 3.3. Управление работой должно иметь безопасные границы

Steering корректирует текущую работу перед следующим LLM-запросом, после
завершения предыдущей генерации и её полной tool batch. Follow-up — новая
задача после завершения run; эту роль уже выполняет наша FIFO.

Pigo дополнительно предлагает отзыв недоставленного текста, ограниченную
очередь и согласование завершения с приёмом последнего сообщения. Для Emacs
нужны аналогичные инварианты при reentrant event loops, не копирование mutex.
Нельзя терять принятый текст или прерывать batch посередине ради steering.

### 3.4. Ограниченный вывод не должен уничтожать полный результат

Pi/Pigo ограничивают model-facing output и оставляют полный shell output
артефактом. У нас `emacs-agent-eval--limit` сохраняет только начало общей
строки: большой stdout может скрыть итоговое значение или сообщение ошибки.

Нужен полный приватный результат, ограниченный preview, явное описание
усечения и способ чтения диапазонов через тот же `eval_elisp`. Сохранение
артефакта не ограничивает вычисление и не добавляет второй LLM tool.

### 3.5. Compaction — добавление новой проекции, не удаление прошлого

Summary создаётся без tools; архив остаётся. Граница retained suffix не
разрывает tool call/result или необходимые protocol поля. Неуспешная/пустая/
незавершённая summary не должна заменять рабочий контекст.

Бюджет учитывает сообщения, system/resources, tool schema и резерв ответа.
Provider usage полезен как опорное измерение, но дальнейший прирост обычно
оценочный. После смены модели/compaction старая опора недействительна.
При невозможности уложиться — понятная ошибка, не молчаливое удаление истории.
Не копировать численные defaults Pi/Pigo без проверки наших моделей.

### 3.6. Durable intent/outcome уточняет неизвестные эффекты

В Pigo synced intent предшествует tool dispatch; outcome сохраняется после
выполнения. Сохранённый outcome может восстановить потерянное result message
без повторного исполнения. Intent без outcome означает неизвестные эффекты.
Storage не гарантирует exactly-once для файлов, Emacs или внешних процессов.

Это описание Pigo, **не принятый план для нашего помощника**. Пользователь
исключил F7: редактор разделён с пользователем, который может изменить, отменить
или сохранить результат независимо от вызова. Ledger фиксировал бы прошлое
выполнение, но не актуальное состояние. Сохраняем best-effort audit, fresh reads,
проверки tick/OLD и отсутствие автоматического повтора после прерывания.
Решение: [ADR-0013](adr/0013-interactive-editor-no-tool-ledger.md).

### 3.7. Resources — данные, capabilities — явные сведения

Инструкции проекта, skills и templates не исполняются при обнаружении и не
настраивают автоматически endpoint, credentials или права. Skill metadata
`allowed-tools` не вводит sandbox и не меняет доступ нашего инструмента.

Для thinking различать неизвестные capabilities, известное отсутствие
уровней и поддерживаемые значения. Server default не равен `off`; скрытие
reasoning не управляет генерацией. Нельзя угадывать capability по имени модели.

### 3.8. Что не стоит безусловно копировать

- Собственные provider/HTTP/OAuth слои Pigo: у нас уже есть gptel.
- Расширения Pi целиком или Go static-plugin механизм: сначала реальный
  потребитель, затем небольшой Elisp API с определёнными гарантиями.
- Retry всего run: это может повторить эффекты. Pigo generation kernel
  повторяет только классифицированный transient/rate-limit запрос до
  видимых text/reasoning/tool-call deltas; у нас даже такой retry требует
  проверки фактического gptel lifecycle и отсутствия вложенных retries.
- Unlimited resource/UI buffers: всё длительно растущее требует политики.
- Branch/head navigation как rollback: редактор и файлы не откатываются.
- Жёсткий timeout для произвольного синхронного Lisp: гарантировать его
  без изменения модели исполнения нельзя.

## 4. Полезные возможности и приоритет

| Возможность | Польза | Порядок |
|---|---|---|
| Проверенные Elisp helpers для чтения и навигации | Устранить наблюдаемые ошибки координат и потерю пустых строк | F0, перед F1 |
| Lossless уплотнение streaming-записей на диске | Уменьшить архив без ухудшения save/restore и replay | F0b, перед F1 |
| Компактный model I/O, пакетные правки и usage | Устранить выявленный перерасход контекста и лишние tool rounds | F0c, перед F1 |
| AGENTS/CLAUDE instructions из корня проекта | Меньше повторяемых проектных указаний; templates отложены | F1 |
| Steering, отзыв/редактирование pending input | Управление долгой задачей без cancel/restart | F2 |
| Полный output artifact + ограниченный preview | Не терять stdout, значение и ошибку | F3 |
| Context usage + manual/automatic compaction | Длинные разговоры без переполнения | F4 |
| Agent Skills, lazy loading и resource inspection | Переиспользование специализированных инструкций | F5 |
| Несколько именованных диалогов, поиск, clone | Не смешивать независимые задачи одного проекта | F6 |
| Branches, bookmarks, продолжение из прошлого | Альтернативные решения без удаления истории | F8 |
| Model selection, declared thinking, diagnostics/export | Контроль конфигурации и наблюдаемость | Отдельные небольшие этапы после выбора пользователя |

Это рекомендуемый порядок, не обещание реализовать всё за один проход.
F1–F5 не требуют заранее строить session tree или framework расширений.

## 5. План реализации с проверяемыми результатами

Нумерация **F0, F0b, F0c, F1–F8** относится к post-MVP и не заменяет этап 6 исходной
спецификации — отдельное исследование второго shell tool.
Названия новых команд/файлов ниже предварительные.

### F0 — Проверенные Elisp helpers для чтения и навигации

**Дополнение по результатам live-теста:** helper `emacs-agent-replace-region`
и правила штатного сохранения/undo —
[ADR-0002](adr/0002-buffer-native-editing.md). Сессия выявила не обход буфера,
а `write-region` без VISIT + ручное снятие modified, оставлявшие stale modtime.
Теперь есть проверенная атомарная замена диапазона с ожидаемыми текстом/tick,
отдельным undo-шагом и явным `save-buffer` после неё. Это обычный helper через
`eval_elisp`, не новый tool или sandbox. Повторный live-тест подтвердил вызовы
helper и `save-buffer`, но выявил путаницу string indices/buffer positions и
обход отказа прямым `insert`. В prompt добавлены правила BASE+I и перечитывания
после отказа, а ошибка OLD показывает bounded actual-text preview; см. ADR-0002.
Всего 83 offline ERT. Последующий пользовательский live smoke подтвердил
шесть замен через helper, перечитывание после OLD mismatch без обхода и
штатный `save-buffer`; пользователь подтвердил undo. Итоговый file-modtime
отдельно не измерялся. F0b выполнен; следующий после него F0c также реализован (см. ниже).

**Реализация:** `emacs-agent-helpers.el`, контракт —
[ADR-0001](adr/0001-f0-buffer-helpers.md). Загружаются вместе с `emacs-agent`;
инструкции модели содержат краткие сигнатуры и правила координат/продолжения.
Offline-проверки: 69 ERT всего, включая regression обеих ошибок, и компиляция
с warnings-as-errors. Eval tool остаётся единственным; gptel lifecycle и
схема хранения не менялись. Live smoke отдельно, ещё не выполнялся.

**Основание: наблюдаемый сбой в пользовательской сессии.**

Исследована сохранённая сессия
`project-c576c13636f13f35488650ab1a127968f0967d275cab5c770095d3b72f3ae401.eld`
из пользовательского data directory. Исходник не менялся; S-выражение прочитано
как данные и отформатировано в приватной временной копии. Содержимое полной
сессии не добавляется в репозиторий.

В коде модели подтверждены две независимые ошибки:

- `(split-string text "\\n" t)` исключал пустые строки и искажал номера строк
  при построении numbered output.
- `(line-beginning-position 14)` и аналогичный `line-end-position` использовались
  как абсолютные номера. Аргумент относителен текущей строке: при нахождении
  на строке 14 такой вызов читает строку 27, а не 14.

Воспроизведение на текущем `emacs-agent-eval.el` в отдельном batch Emacs:
`point=367` соответствует строке 14 с `defcustom emacs-agent-eval-output-limit`,
а относительный вызов возвращает docstring со строки 27. Объяснение модели
«буфер изменился» не было подтверждено; её заключение, что проблема только
в пустых строках, неполно. Новый helper должен устранять обе ошибки.

**Принцип:** helpers — обычные доступные Elisp-функции, вызываемые через
unrestricted `eval_elisp`, а не отдельные advertised LLM tools, whitelist или
sandbox. Агент по-прежнему может использовать любые Emacs API. Начать с малого
набора, расширять его по наблюдаемым повторяющимся проблемам, не строить заранее
копию всего набора tools Pi/Pigo.

**Работа:**

1. Согласовать сигнатуры, формат результата и правила narrowing/EOF. Реализовать
   небольшой модуль, например `emacs-agent-helpers.el`, без перестройки ядра.
2. Добавить чтение диапазона строк **живого указанного буфера** с абсолютными
   номерами, пустыми строками и позициями начала/конца каждой возвращённой строки.
   Несохранённые изменения учитываются; не заменять buffer чтением файла с диска.
3. Добавить чтение вокруг явно заданного `point`: фактические line/column,
   диапазон/текст и символ в этой позиции, если он есть. Координаты вычисляются
   для указанной позиции, а не случайного текущего курсора. Снимок из старого
   запроса не выдаётся за гарантированно актуальное состояние.
4. Добавить сведения о буфере: identity/name/file, текущие point/line/column,
   narrowing bounds, modified state и modification tick. Tick помогает
   обнаруживать изменения, но не превращает старый snapshot в живой marker.
5. Не менять пользовательские point, mark/region, narrowing, выбранное окно
   или содержимое буфера. Temporary widening допускается только по явному
   контракту, с восстановлением исходных ограничений.
6. Установить единые правила: line — 1-based, column — 0-based; позиции — Emacs
   character positions, не байты. Для narrowed buffer сохранять однозначность
   абсолютных координат. Не делать молчаливые clamp/переходы к другому буферу
   при неверном диапазоне, умершем buffer или устаревшей позиции.
7. Вывод ограничивать явно: сообщать returned range, truncation и координаты
   продолжения, включая усечение длинной строки. Согласовать preview с общим
   `eval-output-limit`, чтобы его обрезание не уничтожало навигационные metadata.
8. Добавить краткие сигнатуры/примеры в инструкции агенту и docstrings для
   дальнейшей introspection. Объяснить различие absolute lines и относительных
   стандартных функций. Не прикладывать автоматически весь исходный буфер.

**Готово:** ERT проверяют последовательные/начальные пустые строки, empty buffer,
последнюю строку с/без newline, EOF, Unicode и tabs, narrowing, invalid ranges,
устаревшие позиции, несохранённые правки, сохранение point/mark/region/restriction
и отсутствие перемещения окон. Regression воспроизводит обе ошибки выше и
подтверждает правильную строку 14 независимо от исходного point. Проверяются
явное усечение/продолжение, loading helpers и сохранение единственного LLM tool.
Opt-in live smoke: модель читает строку/символ у captured point через helper,
не теряет пустые строки и не выводит изменение буфера из ошибки своих координат.

### F0b — Lossless уплотнение streaming-журнала при сохранении

**Реализовано и проверено offline:** schema 2, snapshot-only агрегация,
pretty-print и сохранение partial checkpoints. Контракт и исследование Pi/Pigo:
[ADR-0003](adr/0003-durable-streaming-blocks.md). Миграции нет; для нового теста
выбрать отдельный приватный `emacs-agent-data-directory`, старые архивы не
изменять. Live events/renderer/gptel/model history не менялись. Синтетический
fixture без model messages: 4002 события → 4, примерно 460 КБ → 11 КБ (~42×).
95 ERT проходят, включая фактическое сравнение dry-run wire JSON до/после
restore, renderer/fold boundaries и свежий batch Emacs. Live smoke F0b ещё
не запускался; перед F1 добавлен F0c по результатам сравнения model I/O с Pi.

**Согласованное требование:** объединить мелкие streaming-записи в постоянном
архиве, если доказано, что это не ухудшает сохранение, восстановление и model
replay. Это не LLM-compaction F4: нет summary, потери текста или новых запросов
к провайдеру.

**Основание:** в исследованном пользовательском snapshot из F0 было 5852 события,
из них 1787 assistant deltas и 3943 reasoning deltas. Сериализация этих 5730
фрагментов занимала около 934 КБ из 1,24 МБ, при 37 model messages. Измерение
относится к прочитанной версии файла, не к любым будущим сессиям.

**Работа:**

1. Согласовать durable block format, идентификаторы, start/end timestamps,
   partial/completed markers. По решению пользователя обратная совместимость,
   schema migration и backup старой схемы не нужны на стадии глубокой альфы.
   Не хранить массив всех token IDs только ради воспроизведения ненужной
   детализации доставки.
2. Сохранить incremental streaming в UI. Начать с преобразования копии данных
   для snapshot: не менять live event list, cursor renderer, accumulated chunks
   или обработчики gptel. In-memory оптимизация — не обязательная часть этапа.
3. Склеивать только последовательные текстовые фрагменты одного типа и одного
   session/run внутри одного блока. Не переходить через assistant/reasoning-end,
   смену типа/run, tool call/result, статус или любую иную смысловую границу.
   Несколько HTTP-ответов одного run остаются различимыми; порядок сохраняется.
4. Хранить reasoning отдельными блоками, включая final-answer reasoning,
   которое сейчас может отсутствовать в model messages. Не удалять его при
   выключенном отображении и не реконструировать неподанные данные.
5. Сохранять накопленный незавершённый текст при checkpoint/cancel/error;
   в durable формате отличать завершённый блок от partial. Не flush/reset
   live accumulator ради сохранения и не дублировать текст после продолжения.
6. Model messages, tool-call IDs, results и protocol/reasoning fields не менять
   ради уплотнения UI-events. Восстановленный журнал не является источником
   model history; сохранённые model records остаются независимыми.
7. Старые per-delta snapshots явно отклонять как неподдерживаемую схему,
   без миграции и compatibility reader. Не удалять пользовательские архивы.
   Сохранить atomic rename, permissions, corruption isolation, отсутствие
   повторного выполнения и правило interrupted runs.
8. По возможности сделать новое data-only представление удобнее для чтения
   (например, pretty-print), не подменяя этим реальное сокращение записей.

**Готово:** ERT сравнивают полный текст, порядок и границы журнала до/после
save/restore, включая interleaved reasoning/assistant, пустые chunks, несколько
HTTP-ответов, tools/statuses между блоками и разные run. Проверяются checkpoints
посреди stream, продолжение после checkpoint без повторов, cancel/error,
повторное сохранение/идемпотентность преобразования и явный отказ старой схемы.
Фактический dry-run wire replay сохраняет исходные tool pairs и protocol поля.
Restart не возобновляет actions; failed write оставляет прежний файл целым.
Synthetic fixtures позволяют сравнить число записей/байты; частный
пользовательский лог не включается в тесты/репозиторий. Этап принимается только
после этих проверок: уменьшение файла не оправдывает потерю данных восстановления.

### F0c — Экономный model I/O и пакетные правки

**Приоритет перед F1**, принят пользователем после сравнения с Pi.
Факты, ограничения сравнения usage и последовательность:
[ADR-0004](adr/0004-efficient-model-io.md).

В исследованном запуске наш агент сделал 37 tool calls против 3 у Pi,
получил 136919 символов результатов против 3483. Главные факторы: сериализация
text properties в `buffer-string` (2823 → 32768 символов с усечением),
многословный per-line plist, повторные чтения/правки и аварийное стирание буфера
при попытке проверки с последующим recovery. Usage Emacs не записан; нельзя
выдать сравнение «64k/4k» за измеренное отношение token usage. У Pi 4349
некешированных input+output и 13213 с cacheRead; модель Emacs известна только
как алиас main. F0b меняет архив, а не model context, и эту проблему не решает.

Порядок небольших slices:

1. **Реализовано offline:** строковое финальное значение evaluator печатается
   без text properties, stdout забирается без свойств; source не меняется.
   Нестроковые значения и явная Lisp-печать остаются прежними. В prompt
   добавлено plain-text чтение без повторных whole-file reads и запрет
   мутировать буфер ради проверки. 99 ERT, включая actual wire regression,
   и warnings-as-errors; real-provider smoke нового поведения ещё не запускался.
2. **Согласовано и реализовано offline:** компактное default чтение — один
   `:text` с metadata на диапазон, пустыми строками, tick, EOF/narrowing и
   lossless продолжением, включая разрыв на newline. `:start-line`/`:end-line`
   описывают абсолютные позиции `:start`/exclusive `:end`. Старый `:lines`
   удалён без compatibility mode. Around сохраняет `:at`. 103 ERT и compile
   проходят; синтетические 100 строк: ~7532 → 2144 printed characters (~72%).
   Новый live smoke этого формата ещё не запускался.
3. **Согласовано и реализовано offline:** `emacs-agent-replace-texts` с одним
   ожидаемым tick и непустым списком уникальных OLD/NEW. Все диапазоны ищутся
   в исходном доступном тексте; неоднозначные/самоперекрывающиеся OLD и
   пересечения/дубликаты диапазонов — отказ до edits, соседние допустимы.
   Применение снизу вверх, весь batch атомарен и отменяется одним undo-шагом;
   no-op не меняет историю, save отдельно. В prompt batch теперь default;
   region helper сохранён для явных координат. 126 ERT и compile проходят,
   включая rollback на hooks/budget, прежнюю undo history, actual wire и
   исполнение 7 реальных примеров из prompt на временных файлах. Prompt
   структурирован и сокращён с 5037 до 4984 символов (не token estimate).
   После live EOF-ошибки добавлен абсолютный :total-lines в metadata чтения и
   buffer-info; первый пример ограничивает END по EOF и возвращает весь plist,
   извлечение полей оставлено локальному потреблению. Пустые/короткие файлы,
   терминальный newline и narrowing покрыты offline tests. Следующий live smoke
   прошёл без EOF-ошибок, но модель не дочитала усечённую проверку. В prompt
   усилено правило: для полной проверки продолжать тот же range/tick до
   :truncated nil либо явно ограничивать scope проверки; полный reread файла
   не обязателен. Последний smoke подтвердил все 6 NEW в проверочном чтении
   (непрочитаны 75 символов неизменённого тела), один исправленный batch и save.
   Ошибка пустой replacement-пары отклонена до edits; итог 5 calls/7685 chars,
   1 validation error. Это покрытие изменений, не полная проверка файла.
   Пользовательский live smoke подтвердил один batch из 6 замен; затем
   metadata-only guidance устранил повторное чтение ради tick. Undo/rollback
   в этих успешных live-прогонах отдельно не проверялись.
4. **Реализовано и проверено offline/live:** `emacs-agent-usage.el` и локальные
   FSM handlers считают каждый HTTP request один раз, до рекурсивного TOOL→WAIT.
   `usage`/`usage-total` events и active audit сохраняются и отображаются,
   не попадая в model history. Input-uncached/output/cache-read отделены;
   input-total/total выводятся без двойного cache. Отсутствие usage — unknown,
   пропуск делает итог данного поля unknown. `:tokens-full` — только сверочная
   копия, не повторное сложение. Это gptel-normalized counts: некоторые
   отсутствующие raw provider поля gptel уже превращает в 0; zero cache не
   доказывает отсутствие кэша. TYPE слишком рано для streaming; TOOL/DONE и
   error/abort boundaries покрывают empty/tool-only ответы, cancel снимает
   уже parsed usage даже без callback. Durable non-stream text blocks остаются
   complete. 135 ERT и warnings-as-errors проходят. Разрешённый real-model smoke
   в streaming и non-streaming: по 2 HTTP и 1 eval, ответ 42, source не изменён;
   итоговые суммы совпали с cumulative. Token savings на исходной задаче не
   измерены, фактическая модель сервера за alias main не установлена.

Acceptance: source/undo не меняются от чтения, нормальная работа save/undo
сохраняется; сравнение реальных tool results в wire; новые синтетические
fixtures, не приватные логи. Для live-сравнения — одинаковый исходник,
фактическая модель/настройки, чистые сессии и сопоставимые cache-aware usage.
Точный выигрыш в токенах заранее не обещать. Автоматическое summary/truncation
истории и новый tool не входят в этот этап.

### F1 — Инструкции из корня проекта

**Согласованный scope:** только корень проекта; без global roots, обхода
родителей и вложенных каталогов. Templates отложены до появления реальных
повторяющихся сценариев. Решения: [ADR-0005](adr/0005-root-project-instructions.md).

**Работа:**

1. **Согласовано и реализовано:** отдельный блок в system prompt текущего run;
   diagnostic editor snapshot и пользовательский текст не переписываются.
2. Выбирать один файл в корне проекта по согласованному приоритету:
   `AGENTS.override.md` → `AGENTS.md` → `AGENTS.MD` → `CLAUDE.md` → `CLAUDE.MD`.
   Добавить небольшой загрузчик, например `emacs-agent-resources.el`, без
   преждевременных абстракций под hierarchy/templates.
3. Фиксировать выбранный путь/содержимое для конкретного submitted input.
   Изменения файла во время run или ожидания в FIFO не меняют его молча.
   Сохранить прежний захват source/point до минибуфера.
4. Отключение `context-history` не должно неявно выключать инструкции.
5. Дать opt-out и просмотр фактически загруженных путей/предупреждений.

**Реализовано:** `emacs-agent-resources.el`, source buffer-local opt-out,
снимок при enqueue, инструкции в system prompt, durable instructions event и
run audit. Journal показывает status/path/warnings; команда
`emacs-agent-show-instructions` — содержимое active/last-submitted snapshot,
в том числе после restart. Глобального/hierarchy/template loader нет.

**Проверено:** 148 ERT и warnings-as-errors compilation. Root-only discovery,
все filename priorities, пустой override, bad/unreadable/broken-link warnings
без fallback, чтение saved disk вместо unsaved buffer и отсутствие Lisp eval;
source opt-out после смены буфера в minibuffer, редакторский pre-input context,
заморозка FIFO и pending restart, read-only view, независимость от context
policy. Настоящий gptel wire dry-run подтверждает один system block текущего
snapshot, unchanged user text и отсутствие старых инструкций в model history.
Continuation dry-run с настоящим TOOL→TRET→WAIT и подменённым HTTP
подтверждает тот же system block после изменения файла/opt-out. Blank/aborted
input не читает resources; после restart новый run использует только новый
snapshot, warnings остаются видимыми в journal/view. Live F1 smoke отдельно
не запускался.

### Дополнение UX — финальный ответ в echo area

Реализовано по отдельному запросу пользователя между F1 и F2:
`emacs-agent-final-response-lines` (3 screen rows, 0 отключает) и
`emacs-agent-final-response-part` (`start`/`end`). Финальный completed ответ
показывается временным `message`, без отдельного view и без дубликата в
`*Messages*`; полный текст в journal/history не меняется. Учитываются wrapping,
Unicode/tabs, marker внутри лимита. Intermediate/tool/reasoning и error/cancel
не уведомляют; пустой final не подменяется прежним commentary. FIFO и late
callbacks проверены, display failure не блокирует очередь. Если selected window
уже показывает journal той же сессии, echo дубликат подавляется; фоновый journal,
другая сессия и instructions view не подавляют уведомление. 157 ERT и compile
прошли. Решения: [ADR-0006](adr/0006-final-response-echo.md).

### Приоритет перед F2 UI — отзывчивость ввода

По сообщению пользователя об input lag измерен synchronous autosave на
приватной копии его журнала (~391 КБ): recursive pp занимал ~1 с, тогда как
snapshot/validation ~6 мс. Fast per-record printer сохраняет те же schema 2
Lisp values, атомарность, permissions и частоту checkpoints; полный save
~976 → ~14 мс. 162 ERT и compile проходят. Renderer отдельно дал линейную
стоимость в batch; интерактивный redisplay и другие возможные причины lag
этим не исключены. Пользователь повторил live test и подтвердил: тормоза
ввода исчезли.
Решение: [ADR-0008](adr/0008-responsive-snapshots.md).

### F2 — Steering и редактируемый ожидающий ввод

**Статус:** production lifecycle, FSM seam, команды и durable recovery реализованы.
187 ERT и warnings-as-errors compile; новый real-model/interactive F2 smoke
ещё не выполнялся. Hot reload старых in-memory struct instances не делался:
для применения в уже работающем pre-F2 Emacs нужен restart.

**Работа:**

1. **Offline spike выполнен:** pinned TOOL→TRET→WAIT допускает доставку после
   обоих tool results, перед default WAIT HTTP. Проверены обычная batch и
   budget pause/resume, несколько snapshots и nil/current/full; DONE переводит
   pending input в отдельный run через обычный FIFO. Найдено ограничение
   one-user-per-run: добавлен уникальный :input-id для дополнительных user
   inputs того же contiguous run. Повторы/возврат к старому run запрещены.
   `current` проецирует все snapshots run, dedup только соседних equal; raw
   history не меняется. Actual dry-run сохраняет все contexts даже при
   объединении gptel соседних user messages. 161 ERT и compile проходят.
   Этот spike стал основой production private WAIT wrapper.
2. **Реализовано:** `emacs-agent-steer`, без изменения `ask`/FIFO; journal
   C-c C-s steering и C-c C-p pending view.
3. **Реализовано:** prepared/queued/delivered/withdrawn inputs в отдельном
   ledger; editable pending view обычных ask и steering. Defaults: 8 записей,
   256 КиБ UTF-8 frozen payload, overflow без вытеснения. Edit отзывает до
   minibuffer; C-g сохраняет withdrawn, RET возвращает в конец со старыми
   snapshots. Forget с подтверждением освобождает quota, audit остаётся.
4. **Согласовано:** снимок steering — по месту ввода. `current` сохраняет
   исходный снимок и все доставленные snapshots этого run до завершения;
   соседние полностью равные snapshots не дублируются в wire, текст уточнения
   доставляется всегда. A→B→A сохраняется; pending/withdrawn не меняют current.
   При новом run предыдущие snapshots не отправляются при `current`;
   full/nil сохраняют смысл. Steering не меняет session/default tool source.
5. Применять сообщения после полной tool batch, до следующей генерации.
   **Согласовано:** на final boundary недоставленное уточнение становится новым
   запросом обычного FIFO той же сессии, не продолжением завершённого run.
   Решения: [ADR-0007](adr/0007-steering-boundaries.md).
6. **Реализовано:** cancel/error переводят undelivered steering в recovery;
   restart восстанавливает только withdrawn, без очереди, transport и секретов.
   Явный resubmit остановленного input — новый ask; source/backend проверяются,
   context/instructions/config не переснимаются. Optional schema-2 :inputs
   сохраняется через restore-save-restore, fast printer не меняет cadence.
7. Независимый review нашёл три races: reentrant assistant-end orphaned FIFO,
   отмена в tool-call ещё запускала eval, post-launch hook error ошибочно
   возвращал уже отправленный steering в recovery. Все исправлены отдельными
   regression ERT. Terminal disposition всей batch claimed до hooks; tool eval
   проверяет live ownership после tool-call; rollback только до launch.
   Контроль прежнего ~391 КБ sample: full atomic save ~15 мс, 5 повторов без GC.

**Готово:** mock FSM проверяет порядок двух инструментов и steering, несколько
pending messages, отзыв, overflow, финальную границу, отмену, late callbacks и
отсутствие повторных effects. Opt-in live smoke корректирует задачу без restart.

### F3 — Полный результат инструмента и артефакты

**Реализован согласованный KISS scope**, заменяющий первоначальный план
structured channels/registry/helper/UI: [ADR-0009](adr/0009-simple-full-tool-output.md).

1. Строковый `eval_elisp` без нового протокола: stdout + final value/error.
2. При превышении 32768 characters (настраиваемо) полный текст UTF-8 сохраняется
   в уникальный 0600 файл под data-directory/tool-output/, новые каталоги 0700.
   Возвращаются tail и notice с quoted absolute path. Notice входит в budget;
   если сам длиннее лимита, возвращается целиком без tail. Exact limit без I/O.
3. Final value/error после длинного stdout обычно остаётся в хвосте; очень
   большой value может усечься сам, полный текст доступен в сохранённом файле.
4. Чтение обычным Elisp через тот же eval_elisp. Без новых helper, viewer,
   структурированных полей, registry, timers, quotas или automatic cleanup.
   Файлы остаются до ручного удаления; внешнее удаление ломает ссылки.
5. При write/quit failure partial file удаляется best-effort, модель получает
   явный unavailable warning без full-file reference. Вычисление не повторяется.
   Полный текст всё ещё собирается в памяти: memory/execution limit не добавлен.

**Проверка:** 196 ERT и warnings-as-errors compile. Девять новых regressions
покрывают stdout + value/error/quit/nil, Unicode/quoted paths, границы/tiny
budgets, permissions, save failure без повторных effects и отсутствие cleanup.
Новый real-model smoke не запускался; пользовательские исходники не менялись.

### F4 — Контекстный бюджет и compaction

**Реализован выбранный пользователем pigo-подход**, вместо первоначального
manual-first/opt-in плана: [ADR-0010](adr/0010-pigo-style-compaction.md).

1. Локальный настраиваемый budget 262144, reserve 16384, recent target 20000,
   automatic включён по умолчанию. Это не обнаруженное физическое окно `main`.
   Настройки заморожены при accepted input, сохранены в pending data/quota.
2. Перед каждым provider generation, после полного tool batch: chars/4 + framing,
   включая system/tools и preview steering. Доступный normalized usage anchor
   даёт input+cached+output и последующий estimated delta, не точный context size.
   Anchor сохраняется приватно; model/backend change и compaction его сбрасывают.
3. Один summary attempt без tools → rebuild → одна budget recheck. При превышении
   остановиться явно; успешная summary остаётся. Нет provider-overflow retry loop,
   токенизатора, молчаливого удаления или повторного выполнения инструментов.
4. Retention по user/assistant boundary; canonical tool record — уже атомарная
   call/result pair, поэтому допускается split длинного run только между такими
   парами. Retained IDs/reasoning сохранены. Recent target не гарантирует число
   оставшихся токенов. Current-run snapshots остаются explicit под `current`.
5. Original history/journal сохранены; модель получает latest summary + raw suffix.
   Summary с absolute cut/provenance публикуется после complete nonblank response
   и atomic snapshot. Repeated compaction не возвращает старый raw prefix.
   Генерация/cancel/save failure сохраняет прежнюю projection; restart inert.
6. `M-x emacs-agent-compact` в idle, prefix для retention (включая 0) и focus.
   Существующий cancel/FIFO работают с session lock; arriving steering не claimed
   до task HTTP. Auto требует autosave; manual — явная durable операция.
7. Summary input как pigo: UTF-8-safe prefix 2000 bytes/block; total
   min(128 KiB, context/3) bytes с first-quarter/newest-tail. Это lossy источник,
   не гарантия сохранения всех value/error/file references. Исходные данные целы.

Summary framing позже заменён на TypeScript Pi: отдельные conversation/previous
blocks, initial/update instructions и checkpoint template после данных.
[ADR-0011](adr/0011-pi-summary-request-framing.md). Без новых validators/retries,
изменений budget/cut/acceptance или переписывания уже сохранённых summaries.

**Проверка:** 227 ERT и warnings-as-errors compile/diff-check; production private
FSM dry-run, post-whole-batch steering/cancel без повторных effects, usage anchor,
повторная summary, malformed checkpoints, failed save, FIFO/reentrant events,
restore без установленного gptel в свежем `emacs -Q`. Независимый read-only review
coordinator/integration не нашёл подтверждённых проблем. Пользователь проверил
manual compaction; один отдельный tool-free probe нового framing на
`aiserver/main` дал структурированные заметки, но с фактической ошибкой. Полной
live matrix и гарантии сохранения смысла нет.
Structs изменились: нужен restart, не hot-load в pre-F4 пользовательский Emacs.

### F5 — Agent Skills и инспекция ресурсов

**Статус:** отложен по решению пользователя; F6 выполнен раньше F5.

**Работа:**

1. Использовать формат [Agent Skills](https://github.com/agentskills/agentskills):
   `SKILL.md` с YAML metadata. Перед реализацией сверить актуальную спецификацию
   формата; выбрать и проверить parser/dependency, не выдавать regex-подмножество
   за полную YAML-поддержку.
2. Discovery загружает metadata; модель читает тело и references по необходимости
   через тот же `eval_elisp`. Пути разрешаются относительно выбранного skill.
3. Определить global/project precedence, duplicate/override semantics, limits,
   opt-out и disable policy. Override заменяет bundle целиком, без скрытого
   fallback references к другой копии.
4. Добавить list/show/reload и явный выбор skill. Inspection не требует сети,
   LLM backend или credentials. Обнаружение не запускает scripts/Lisp.
5. Зафиксировать skills snapshot для input/run; reload действует на будущие
   inputs, а не изменяет текущий запрос или архив задним числом.

**Готово:** fixtures покрывают multiline description, malformed frontmatter,
Unicode names, duplicates, override references, disabled skills и limits;
dry-run содержит только нужные metadata/явно выбранный body. Реальный workflow
читает существующий skill и references без новых tools.

### F6 — Несколько диалогов в одном scope

**Реализовано без миграций**, по явному решению пользователя:
[ADR-0012](adr/0012-multiple-conversations.md). Старые `global.eld`/`project-*.eld`
не переписываются, но и не загружаются/не показываются в новом каталоге.

1. ID→object registry отделён от scope→selected-ID. Новая schema 3:
   conversations/<hash-ID>.eld и project pointers в selections/<hash-root>.eld.
   Canonical scope неизменяем; cross-project reassignment нет.
2. `emacs-agent-session-new`, `-rename`, `-select`, `-search`, `-clone`. Выбор только
   внутри scope; names не identity/filename. Список/search локальные, без backend.
   RET показывает журнал, не выбирает. Nonselected journal явно адресует owner;
   рабочий буфер — выбранный conversation, зафиксированный до minibuffer.
3. Первый implicit global use после restart создаёт свежий разговор; catalog,
   reload и показ existing journal не восстанавливают старый global выбор.
   F6 old globals доступны через explicit select. Проектный выбор persisted.
4. New/select/clone только idle involved conversations; rename — idle target.
   До публикации сохраняются old/source/candidate и project pointer. Ошибка
   не меняет выбор/history/queue; сохранённый unselected candidate может остаться.
   Initial project identity/pointer durable даже при autosave off; subsequent
   chat checkpoints по-прежнему подчиняются autosave policy.
5. Clone deep-copies history/events/compaction, rewrites event session IDs и
   получает source-ID/time provenance. Не копирует input recovery/queues,
   usage anchor, editor/backend/transport handles и не исполняет старые actions.
   F3 artifacts остаются ссылками, не копируются/не перечитываются.
6. Mutation lock отвергает новые admissions и ручной recovery до изменения
   ledger, но не блокирует уже accepted F2 conversions в других разговорах.
   Run/input/summary liveness проверяет ID+object identity, не selection.

**Проверка:** 252 ERT и warnings-as-errors compile/diff-check. В том числе реальные
pinned gptel wire/tool/reasoning replay на clone, parallel nonselected journal
ownership, minibuffer selection changes, failure stages, orphan candidates,
withdrawn recovery isolation и backend-free fresh-process restart tests.
Два subprocess подтверждают новые global IDs, explicit old-global continuation,
project selection и отсутствие reload duplicates. Независимый read-only review
не нашёл подтверждённых F6 проблем. Пользовательский live F6 smoke ещё отдельно;
новые structs в рабочий Emacs не hot-loaded, нужен restart.

### F7 — Исключён: tool execution ledger

Пользователь исключил этот этап из обязательного плана: это интерактивный
помощник в общем редакторе, не автономный исполнитель. Пользователь может
вручную изменить/отменить/сохранить результат; прошлый tool outcome не доказывает
актуальное состояние. Отдельные intent/outcome и durable dispatch gate не нужны
без реального сценария, оправдывающего усложнение.

Остаются текущий best-effort audit, native undo, явный save, fresh reads и
проверки tick/OLD. После прерывания ничего не повторяется автоматически;
продолжение требует проверки текущих буферов/файлов, а не доверия старому result
или summary. Это не обещание exactly-once/rollback. Нумерация F8 сохраняется.
См. [ADR-0013](adr/0013-interactive-editor-no-tool-ledger.md).

### F8 — Ветки и bookmarks

**Работа:**

1. Добавить parent/selected-head модель с проверкой ancestry и migration.
2. Сначала выбирать только safe completed boundaries; затем добавлять удобные
   bookmarks и повторное редактирование выбранного user input.
3. Raw alternatives сохраняются, model projection выбирает одну ветвь.
4. Branch summary — отдельная opt-in операция без tools; ошибки generation
   не переключают рабочую ветвь. Branch selection не откатывает общий Emacs.
5. Правила model/resources/summary inheritance и interrupted heads должны быть
   явными. Не разрешать переключение head посреди active run.

**Готово:** проверены tree/restore/ancestry, tool pairs, metadata inheritance,
late callbacks и независимость старой ветви; UI явно предупреждает, что файлы,
буферы и процессы не возвращаются к старому состоянию.

## 6. Следующие кандидаты, но не обязательства текущего плана

- **Model/thinking selection:** session/run-local настройки, реальные capabilities,
  frozen per-run selection, default отдельно от off/visibility; не менять
  глобальные gptel defaults. Существующая support boundary остаётся явной.
- **Статистика/diagnostics/export:** модель, длительность, call count, usage,
  preview фактического контекста и provenance ресурсов; без credentials и raw
  transport headers. Export может содержать секреты — пользователь предупреждён.
- **Emacs-native context actions:** явно приложить выделение, buffer range,
  compilation diagnostics или diff. Никакой автоматической отправки полного
  буфера; payload фиксируется при выборе, учитывается в budget.
- **Асинхронные jobs:** helpers поверх `make-process`, status/result/cancel;
  управление только своими jobs, не обещание остановить любой процесс агента.
- **Transient retries:** только после отдельного lifecycle spike и тестов
  отсутствия повторных Lisp effects/двойного retry gptel и агента.
- **Context edits:** append-only изменения будущей model projection с явным
  provenance; не менять original UI/archive и не разрушать tool pairing.
- **Расширения, MCP, субагенты/workflows, изображения:** отдельные исследования
  после конкретного пользовательского сценария. Не добавлять инфраструктуру
  или второй инструмент автоматически.
- **Transport-buffer reclamation:** отдельная небольшая задача после проверки
  ownership terminal FSM/paused continuations; не убивать произвольные buffers
  или пользовательские процессы.
- **Эксперимент eval против eval+shell:** остаётся этапом 6 MVP-спецификации;
  критерии — надёжность, время, calls и качество, а не сходство с Pi.

## 7. Решения перед соответствующими этапами

Ниже **предложения, не согласованные defaults**. Вопросы закрываются поэтапно,
не нужно выбирать всё до начала F1.

| Когда | Вопрос | Предлагаемая отправная точка |
|---|---|---|
| F0 | Helpers: сигнатуры, структурированный результат, narrowing и EOF | Принято: [ADR-0001](adr/0001-f0-buffer-helpers.md); абсолютные координаты, явный widening, terminal empty line, plist с продолжением |
| F0b | Durable blocks, partial markers, identifiers/timestamps | Принято: [ADR-0003](adr/0003-durable-streaming-blocks.md); schema 2, snapshot-only, partial checkpoints, без миграции/обратной совместимости |
| F0c | Экономный model I/O, пакетные OLD/NEW edits, usage | [ADR-0004](adr/0004-efficient-model-io.md); plain strings, compact reads, batch edits и gptel-normalized usage реализованы; offline/live checks пройдены |
| F1 | Roots и instruction discovery | Принято: [ADR-0005](adr/0005-root-project-instructions.md); только project root, один AGENTS/CLAUDE файл по priority, никаких global/parents/children |
| F1 | Доставка инструкций | Принято: frozen saved-disk snapshot на input; отдельный блок в system prompt текущего run, старые snapshots только audit |
| F1 | Template syntax и история ввода | Templates отложены пользователем до реальных повторяющихся сценариев |
| F1/F5 | Когда перечитывать ресурсы? | При подготовке каждого input; queued inputs/run используют frozen snapshot |
| F2 | Что означает `current` после steering? | Принято: original + все delivered snapshots текущего run; dedup только соседних equal, A→B→A сохраняется; pending не влияет |
| F2 | Последнее сообщение на final boundary | Принято: недоставленное уточнение становится новым запросом обычного FIFO; не переоткрывать run и не смешивать с recovery после cancel/error |
| F3 | Хранение и cleanup artifacts | Приватное durable хранилище с references; явная cleanup policy, не бессрочный temp-file мусор |
| F4 | Auto compaction default/окно модели | Начать с manual + opt-in auto; окно задаётся явно/из проверенных metadata |
| F5 | YAML/parser dependency и precedence | Совместимость Agent Skills, bounded data parsing, ошибки duplicates одного уровня |
| F6/F8 | Schema/migration и активные mutations | F6: schema 3 без миграций, legacy archives не импортируются; mutations только idle. F8 согласуется отдельно |
| F7 | Tool execution ledger | Исключён пользователем: общий интерактивный редактор; актуальное состояние проверяется заново, без durable dispatch gate |

Remote resources не должны неявно запускать длительное TRAMP discovery только
ради status rendering. Scope/provider/settings нельзя менять через resource
loading. Любые новые пользовательские настройки должны иметь понятный opt-out.

## 8. Общие правила выполнения и проверки

1. Перед кодом этапа прочитать соответствующие исходники/тесты проекта и точный
   gptel contract. Research map выше — ориентир, не готовая реализация.
2. Сначала закрыть решения этапа, записать их в этот документ, затем реализовать
   минимальный вертикальный slice. Не совмещать все F-этапы в один refactor.
3. ERT и `make compile` с warnings-as-errors обязательны; на NixOS:

   ```sh
   nix-shell -p gnumake --run 'make clean test compile'
   ```

4. Offline tests должны проверять фактические запросы, IDs, эффекты и отказные
   пути, не только наличие строк в UI. Property-style fixtures дополняют ERT
   для границ истории, corruption и transition sequences.
5. Opt-in real-provider smoke отдельно документируется; mock/dry-run не равен
   реальному HTTP. Секреты и пользовательские settings не копировать в fixtures.
6. Изменения durable schema требуют roundtrip fixtures, ясной политики
   несовместимости и сохранения прежнего файла при failed writes. На текущей
   стадии глубокой альфы миграция/обратная совместимость не требуются по решению
   пользователя; прежние предложения migration для будущих этапов пересмотреть
   перед их реализацией.
7. После каждого этапа обновить README/интеграционные ограничения, зафиксировать
   проверенные факты и оставшиеся вопросы. Коммит — только по запросу пользователя.

**Рекомендуемый следующий шаг:** restart и пользовательская проверка F6
(new/select/clone и project/global restart). F5 отложен, F7 исключён; следующий scope
согласовать после проверки. Pre-F6 файлы оставлены архивом без импорта. F2 пользователь
проверил и одобрил commit; отдельной инструментированной full real-provider
matrix нет. Исходный F4 не hot-loaded в pre-F4 Emacs; поздняя смена framing
не меняет layouts structs.
Templates по решению пользователя отложены. Отдельный benchmark экономии
токенов F0c остаётся опциональным и требует одинакового исходника, фактической
модели/настроек и сопоставимого cache state.
