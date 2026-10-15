# Emacs Agent после MVP: выводы из Pi/Pigo и план развития

**Статус:** F0 и F0b реализованы; 95 offline ERT и byte compilation с
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

Политика проектных сессий этим решением не меняется. Это **согласованное
будущее поведение**, реализуемое в F6, а не описание текущего MVP, который
пока автоматически восстанавливает единую сохранённую глобальную сессию.

### 1.2. Согласованное изменение: новый разговор вручную

Пользователь может явно начать новую пустую сессию в текущем global/project
scope, не перезапуская Emacs. Для этого нужна отдельная команда (предварительное
имя — `emacs-agent-session-new`). Новый разговор получает новый conversation ID
и становится выбранным в этом scope. Старая сессия сохраняется и остаётся
доступной в списке для просмотра и продолжения.

Это не очистка/сброс истории и не clone: история старого разговора и его
ожидающие задачи не переносятся в новый. Перед переключением старая сессия
должна быть успешно сохранена; при ошибке записи переключение не выполняется,
а пользователь получает понятное сообщение. Поведение при активном run
уточняется перед F6; базовый план разрешает переключение только в idle,
без автоматической отмены или повторного исполнения.

Это требование реализуется в F6 вместе с несколькими разговорами на scope.

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

Это полезное будущее улучшение нашего общего `interrupted`. Но Pigo требует
успешного сохранения intent перед dispatch, а наш autosave — best-effort.
Изменение этой политики требует явного согласования.

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
| AGENTS/CLAUDE instructions + prompt templates | Меньше повторяемых указаний; reusable workflows | F1 |
| Steering, отзыв/редактирование pending input | Управление долгой задачей без cancel/restart | F2 |
| Полный output artifact + ограниченный preview | Не терять stdout, значение и ошибку | F3 |
| Context usage + manual/automatic compaction | Длинные разговоры без переполнения | F4 |
| Agent Skills, lazy loading и resource inspection | Переиспользование специализированных инструкций | F5 |
| Несколько именованных диалогов, поиск, clone | Не смешивать независимые задачи одного проекта | F6 |
| Tool intent/outcome и recovery inspection | Понятнее последствия сбоя в середине инструмента | F7 |
| Branches, bookmarks, продолжение из прошлого | Альтернативные решения без удаления истории | F8 |
| Model selection, declared thinking, diagnostics/export | Контроль конфигурации и наблюдаемость | Отдельные небольшие этапы после выбора пользователя |

Это рекомендуемый порядок, не обещание реализовать всё за один проход.
F1–F5 не требуют заранее строить session tree или framework расширений.

## 5. План реализации с проверяемыми результатами

Нумерация **F0, F0b, F1–F8** относится к post-MVP и не заменяет этап 6 исходной
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
отдельно не измерялся. F0b остаётся следующим отдельным этапом.

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
не запускался; F1 — следующий этап.

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

### F1 — Инструкции проекта и шаблоны

**Работа:**

1. Согласовать корни ресурсов, hierarchy, precedence и template syntax.
2. Для instruction discovery предлагается приоритет одного файла на каталог:
   `AGENTS.override.md` → `AGENTS.md` → `AGENTS.MD` → `CLAUDE.md` → `CLAUDE.MD`,
   как в изученных загрузчиках; подтвердить его вместе с hierarchy.
   Добавить небольшой загрузчик ресурсов, например `emacs-agent-resources.el`;
   не разбивать его на множество абстракций до реальной необходимости.
3. Загружать инструкции из настроенного global root и согласованной иерархии
   директорий рабочего буфера; фиксировать список/содержимое для конкретного
   submitted input. Изменения файлов во время run не меняют его молча.
4. Отделить diagnostic editor snapshot от project instructions. Отключение
   `context-history` не должно неявно выключать независимо настроенные ресурсы.
5. Дать opt-out и просмотр фактически загруженных путей/предупреждений.
6. Выбирать template через `completing-read`, раскрывать его до enqueue,
   сохранять provenance отдельно от текста. В журнале показывать реально
   отправленный user text, включая явно выбранный template, без скрытых вставок.
7. Зафиксировать раскрытые inputs для FIFO, не перечитывать их при старте
   отложенного run. Сохранить прежний захват source/point до минибуфера.

**Готово:** ERT проверяют hierarchy/duplicates/opt-out, отсутствующие и плохие
файлы, escaping, multiline template arguments, незаполненные переменные,
исходный буфер и неизменность queued inputs; wire dry-run подтверждает состав
запроса. Никакой ресурс не выполняет Lisp и не перенастраивает gptel.

### F2 — Steering и редактируемый ожидающий ввод

**Работа:**

1. Проверить отдельным offline spike точку вставки user input перед следующим
   HTTP-запросом в текущем gptel FSM. Не предполагать, что text callback даёт
   управление продолжением; не переписывать transport ради удобства.
2. Добавить явную команду steering, сохранив существующую семантику `ask`/FIFO.
3. Разделить prepared, queued, delivered и withdrawn inputs. Ограничить объём
   и число записей; показать pending state, предоставить отзыв для редактирования.
4. Захватывать контекст steering при его собственном вводе. Согласовать,
   какой snapshot является `current` внутри уже работающего run. Steering
   не переносит run в другую сессию и не меняет default tool source buffer
   молча; отличать source корректировки от execution context инструмента.
5. Применять сообщения после полной tool batch, до следующей генерации;
   согласовать поведение сообщения, принятого на границе final answer.
6. При cancel/error возвращать недоставленный текст для явного повторного
   использования, не запускать его автоматически. Не включать его в delivered
   model history; durable audit может отдельно сохранять pending input.

**Готово:** mock FSM проверяет порядок двух инструментов и steering, несколько
pending messages, отзыв, overflow, финальную границу, отмену, late callbacks и
отсутствие повторных effects. Opt-in live smoke корректирует задачу без restart.

### F3 — Полный результат инструмента и артефакты

**Работа:**

1. Сохранить multiple forms, lexical eval, успешный nil и маркированные ошибки.
2. Отделить stdout, final value/error и preview. По умолчанию preview должен
   не терять final value/error из-за длинного stdout; правила усечения явные.
3. Большой полный текст сохранять приватным артефактом под data directory,
   а не в project tree. В result возвращать ID/reference, размеры и truncation.
4. Предоставить чтение диапазонов через Elisp helper и открытие из журнала.
5. Определить жизненный цикл, лимиты хранения, очистку и поведение при missing
   artifact; не обещать доступность приватного временного файла после restart.
6. Согласовать отказ записи: вычисление уже могло завершиться; нельзя повторять
   его ради сохранения или выдавать неполный preview за полный результат.

**Готово:** ERT проверяют длинный stdout с итогом/ошибкой в конце, Unicode,
чтение диапазонов, 0600, restore references, failed writes, missing files и
очистку. Нет новых advertised LLM tools и нет усечения самого вычисления.

### F4 — Контекстный бюджет и compaction

**Работа:**

1. Ввести явный builder model projection поверх неизменяемых original records;
   сначала сохранить эквивалентность нынешнего wire replay.
2. Добавить declared context window, output reserve, оценку полного запроса
   и доступный usage. UI помечает оценки как оценки; неизвестные capabilities
   не превращаются в выдуманное точное окно/цену.
3. Сделать ручную compaction только в idle session: без tools, с отменой,
   retained boundary и отдельной записью summary/provenance.
4. Начать с консервативных границ завершённых run; split большой tool chain
   рассматривать только при отдельной необходимости и доказанном pairing.
5. Публиковать новую проекцию после успешной summary и persistence. При ошибке
   оставить прежнюю проекцию; повторная compaction учитывает предыдущую summary.
6. После ручного режима добавить opt-in automatic compaction на безопасной
   границе перед запросом. Включение по умолчанию — отдельное решение.
7. После summary заново проверять бюджет. Если места нет — остановка/понятная
   ошибка, без молчаливого удаления. Summary также имеет собственный бюджет.

**Готово:** regression/property-style ERT проверяют точные tool pairs/IDs и
reasoning, repeated compaction, три context policies, restore summary,
смену модели/usage anchor, пустую/оборванную summary, cancel и failure без
замены старого контекста. Live smoke проверяет сохранение целей/ограничений.

### F5 — Agent Skills и инспекция ресурсов

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

**Работа:**

1. Отделить conversation ID от global/project scope. Хранить выбранный диалог
   каждого scope; перейти от одного файла на root к нескольким conversation IDs.
   Для global при каждом новом запуске Emacs выбирать новый пустой разговор;
   сохранённый выбор прошлого запуска не восстанавливать автоматически.
2. Добавить new/name/select/search и clone завершённого разговора; проектные
   scope сохраняют выбранный default conversation. Старые глобальные сессии
   остаются доступными для явного выбора/продолжения, без перезаписи или
   автоматического объединения с новой. Команда ручного new действует в обоих
   scope: сохраняет старую сессию, создаёт новый ID с пустой историей и выбирает
   его. При failed save прежняя сессия остаётся выбранной; история и очередь
   не сбрасываются. Миграция `global.eld` сохраняет его разговор как доступную
   старую сессию, не назначая активным при новом запуске.
3. Явно мигрировать schema 1 с backup и сохранением project mapping, history,
   reasoning/tool pairs и interruption audit. Не переписывать файлы молча.
4. Clone получает новую identity и provenance; не копирует runtime handles,
   очередь или полномочия и не повторяет прежние actions.
5. Запретить неоднозначные mutations активного диалога. Не добавлять silent
   cross-project reassignment; семантика переноса требует отдельного решения.

**Готово:** migration/restore ERT, два независимых разговора одного проекта,
переключение source/journal, same-basename roots, global conversations, clone
с tool history и сохранённой provenance. Отдельные restart-тесты подтверждают
новую пустую глобальную сессию с новым ID, сохранность старой истории и её
явное продолжение; повторная загрузка пакета/показ журнала не создают дубликат.
После выбора старой глобальной сессии следующий restart всё равно создаёт
новую; проектный выбор восстанавливается как раньше. Ручное new в global и
project создаёт пустой разговор с новым ID, сохраняет старый без изменений и
позволяет вернуться к нему; failed save не переключает выбранную сессию и не
теряет историю/очередь. Никаких stale callback actions.

### F7 — Tool execution ledger и разбор прерываний

**Работа:**

1. Согласовать persistence policy: best-effort audit либо обязательное durable
   checkpoint перед dispatch, а также поведение при disabled autosave.
2. Ввести отдельные prepared intent и completed outcome со стабильной связью
   с call/run; фиксировать неизвестный исход, не синтезировать успешный result.
3. Если outcome сохранён, восстановить недостающее model result без вычисления;
   если outcome отсутствует — показать explicit inspection/recovery pathway.
4. Не обещать rollback/exactly-once и не дедуплицировать разные user actions
   только по совпадающему тексту выражения.

**Готово:** fault injection до dispatch, после effects, после outcome и до
model result; каждый тест считает реальные eval invocations. Restart ничего
не исполняет; обязательный failed intent write не допускает dispatch.

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
| F1 | Собственные roots или чтение `.pi`/`.pigo`? | Настраиваемые roots агента; существующие ресурсы подключать явно, не смешивать автоматически |
| F1 | Читать инструкции всех filesystem ancestors или только scope? | Global + project root → directory source buffer; для global и TRAMP согласовать отдельно |
| F1 | Template syntax и история ввода | Один формат, например именованные `{{name}}`; явно показывать expansion/provenance, не auto-detect несколько диалектов |
| F1/F5 | Когда перечитывать ресурсы? | При подготовке каждого input; queued inputs/run используют frozen snapshot |
| F2 | Что означает `current` после steering? | Предлагается последний delivered user input; original и steering snapshots остаются в archive; подтвердить изменение семантики |
| F2 | Последнее сообщение на final boundary | Принятое до закрытия run требует следующую генерацию; после закрытия текст остаётся для явного нового run |
| F3 | Хранение и cleanup artifacts | Приватное durable хранилище с references; явная cleanup policy, не бессрочный temp-file мусор |
| F4 | Auto compaction default/окно модели | Начать с manual + opt-in auto; окно задаётся явно/из проверенных metadata |
| F5 | YAML/parser dependency и precedence | Совместимость Agent Skills, bounded data parsing, ошибки duplicates одного уровня |
| F6/F8 | Schema/migration и активные mutations | Backup и явная миграция; mutations выбора/истории только idle |
| F7 | Неуспешный durable intent checkpoint | В строгом режиме не dispatch; выбор строгого режима/default согласовать отдельно |

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

**Рекомендуемый следующий шаг:** при желании выполнить opt-in live smoke F0b
в отдельном приватном data directory. Затем согласовать три решения F1
(roots, hierarchy, template syntax) и перейти к instructions, после них — templates. Большая перестройка ядра для этого не требуется.
