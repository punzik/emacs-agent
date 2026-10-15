# ADR-0004: Экономный model I/O после сравнения с Pi

Статус: F0c реализован: plain-string, компактное чтение, пакетные замены,
metadata/prompt и per-request/run usage. Offline tests и пользовательские
live smoke дополнены разрешённым live usage smoke через доступный gptel.
Реализация usage не доказывает экономию токенов на исходной задаче.

## Контекст и наблюдения

На одинаковой по смыслу задаче — добавить Doxygen-комментарии в `hashmap.c` —
пользователь сообщил о 64k токенов у нашего агента против 4k у Pi.
Приватные логи исследованы как данные, без исполнения форм. Они не входят
в репозиторий и не используются как fixtures.

Канонические сообщения (не сумма `:messages` и дублирующего `:events`):

| Метрика | Emacs agent | Pi |
|---|---:|---:|
| Tool calls | 37 | 3 |
| Символы текстовых tool results | 136919 | 3483 |
| Tool errors | 5 | 0 |
| Редактирование | 10 helper-вызовов, 7 успешных; затем recovery/перезапись | 6 точечных замен одним edit |

Первый `buffer-string` исходника из 2823 символов дал 32768 символов результата
и был обрезан. В Lisp-представление попали font-lock/eglot text properties.
Пять результатов с `buffer-string` дали 87269 символов (~64% всего tool output).
17 read-helper вызовов дали 48643 символа на 13226 символов полезного текста
без newline separators (~3.68×). Были многократные полные и перекрывающиеся чтения.
После изначальных правок агент ошибочно выполнил `(erase-buffer)` до
`(insert (buffer-string))`, стёр содержимое, затем восстанавливал файл через
revert и полную перезапись. Это не нормальная проверка результата и не безопасное
восстановление undo; unrestricted eval позволяет обход helper.

Usage нельзя сравнивать как одно число: Pi сохранил input=2987, output=1362,
cacheRead=8864, totalTokens=13213 по четырём ответам. Input+output=4349, а
последний totalTokens=4350 — оба округляются до 4k, но имеют разный смысл.
Наш лог не содержит provider usage; число 64k и cache breakdown по нему не
проверяются. У Pi явная модель qwen3.8-27B-Q6, у Emacs алиас main, совпадение
фактической модели/настроек не доказано. Символы и байты не называются токенами;
суммы повторяющихся префиксов истории не выдаются за измеренный HTTP traffic.

F0b уменьшает durable events на диске, но намеренно не меняет tool results
в model history. Он не решает обнаруженную проблему model I/O.

## Решение и последовательность F0c

### 1. Plain-text финальные строки evaluator — минимальный slice

При успешном eval строковое финальное значение печатается после
`substring-no-properties`. Source buffer и сам объект не мутируются. Captured
stdout забирается из output buffer без свойств. Существующие Lisp quoting,
метки результата/ошибки, output limit, эффекты eval и поведение undo не меняются.

Это осознанный display contract: text properties финальной строки не являются
обычным текстовым ответом инструмента. Для явного исследования свойств агент
может вернуть `text-properties-at`/`get-text-property` как данные. Не рекурсивно
нормализовать произвольные Lisp objects: списки, vectors, cycles и другие
нестроковые значения сохраняют текущую семантику печати. Явный `prin1` в stdout
также остаётся действием выполняемого Lisp, а не перехватывается.

ERT: свойственная строка из живого буфера выводится как plain string без #(...)
и скрытых metadata; строки Unicode/пустые/newline сохраняются; source properties,
contents, point, tick и undo не меняются. Небольшой полезный текст с огромным
свойством не должен усекаться из-за этого свойства. Явная инспекция свойств,
нестроковые результаты, stdout/errors/limits продолжают работать.

### 2. Компактный default для чтения

Metadata на диапазон, а не plist с несколькими координатами на каждую строку.
Сохранить пустые строки, абсолютные координаты и надёжное продолжение, tick,
narrowing и bounded preview. Не потерять различие EOF/newline и исходный текст.
До кода определить точное представление (plain/numbered text или иной формат),
поведение around и совместимость с чтением координат для edits. Не вводить
скрытый summary, не обрезать старые tool results автоматически в history.

Контракт принят пользователем после сравнения форматов Pi и Pigo: оба
возвращают ненумерованный текст и краткое range/continuation notice, не
per-line metadata. У нас metadata остаётся в одном plist вокруг `:text`:

- Удалить per-line `:lines` plist из результата чтения, заменить одним `:text`
  с точным текстом диапазона (включая внутренние newline и пустые строки).
  Не добавлять альтернативный verbose mode без потребности.
- Сохранить buffer metadata и `:requested-lines`, абсолютные `:start`/`:end`
  (конец исключителен), `:tick`, `:truncated` и `:next-position`; добавить
  `:start-line`/`:end-line` — строки позиций start/end. Поскольку end исключителен,
  он может указывать на начало следующей строки после возвращённого newline.
- Inclusive START..END означает от начала START до конца END, без newline
  после END; terminal empty line сохраняется в координатах и тексте диапазона.
- `:limit` ограничивает длину непрерывного текста. При усечении next-position
  равен end; повтор с `:from`/`:tick` позволяет конкатенировать `:text` без
  пропущенных/добавленных символов, в том числе при разрыве на newline.
- Around использует тот же текстовый результат и прежний `:at` с явными
  position/line/column/symbol. Narrowing, state preservation и output budget
  остаются прежними. Для координат конкретной строки можно прочитать её отдельно.
- В prompt по запросу пользователя явно указано: если нужны только metadata
  (tick/point/bounds/modified), использовать `emacs-agent-buffer-info`, не читать
  текст повторно. Уже полученные metadata переиспользовать. Новый tick сам по
  себе не подтверждает актуальность ранее прочитанного текста; stale tick
  требует перечитывания затронутого диапазона перед правкой. После live-теста
  с выдуманным `:fields (tick)` добавлен точный пример:
  `(plist-get (emacs-agent-buffer-info BUFFER) :tick)`. Результат — plist,
  в edit передаётся извлечённое целое число; `:fields` не существует.
- Это намеренное изменение API в deep alpha; обновить docstrings, prompt,
  README и tests, не вводить compatibility adapter для старого `:lines`.

### 3. Пакетные exact-text замены в живом буфере

Один вызов для нескольких OLD/NEW замен, без ручного вычисления каждой позиции.
Сохранить undo, atomic rollback, read-only/narrowing и защиту от stale текста;
сохранение отдельно через `save-buffer`. До кода согласованы уникальность
OLD, перекрытия, порядок применения, expected tick, отчёт о результате и
семантика no-op/ошибок. По неоднозначному OLD — ошибка, не угадывание места.
Не добавлять новый LLM tool, sandbox или массовую перезапись файлов.

Контракт принят пользователем:

```elisp
(emacs-agent-replace-texts BUFFER
  '((:old "exact old text" :new "replacement")
    (:old "another unique fragment" :new "another replacement"))
  :tick TICK :widen t)
```

- BUFFER — явный живой буфер/его имя; список замен непустой. `:tick` обязателен
  и проверяется один раз для исходного состояния всего пакета.
- Все непустые OLD ищутся буквально и должны встречаться ровно один раз
  в исходном доступном тексте. Учитывать также самоперекрывающиеся вхождения,
  например OLD="aa" в "aaa" неоднозначен. Недоступный текст не искать без
  явного `:widen t`.
- Все диапазоны находятся и проверяются **до первой правки** в одной версии
  буфера. Не разрешать зависимости вида «следующий OLD появился из NEW».
  Пересекающиеся/дублирующиеся диапазоны — ошибка всего пакета; соседние можно.
- Пустой OLD запрещён. Для вставки использовать уникальный OLD-якорь и NEW,
  содержащий добавленный текст вместе с якорем; пустой NEW означает удаление.
  OLD=NEW — no-op; полностью no-op пакет не меняет tick/modified/undo.
- Применять снизу вверх независимо от порядка входного списка. Уважать
  read-only, narrowing, undo-enabled и внешний file-modtime как в существующем
  helper. Before/after-change hooks работают нормально; повторно проверять OLD
  на рассчитанной позиции перед заменой, чтобы не писать по устаревшему месту,
  если hook неожиданно поменял другие участки.
- Все реальные замены — одна atomic change group и один undo-шаг, отделённый
  от пользовательских правок. Ошибка в любой замене/выводе откатывает текст всего
  пакета в целевом буфере; произвольные внешние эффекты hooks не откатываются.
- Сохранение только отдельным `save-buffer`. Результат — компактный plist
  `:buffer`, итоговые `:tick`, `:modified`, число реально изменённых участков
  `:changed`. Не возвращать весь текст/diff по умолчанию. Source point/mark и
  narrowing отслеживают изменения как markers, окна не выбираются.

Последующий live-тест компактного чтения подтвердил новый `:text` и дал
18 tools/12298 символов (против предыдущих 8/25736). Модель пыталась собрать
пакет вручную, но `symbol-value` для lexical tick привёл к ошибке после первой
успешной замены; оставшиеся пять потребовали отдельных поисков/вызовов. Все
фактические замены шли через helper, `save-buffer` выполнен. Undo/usage не
проверены. Это подтверждает необходимость одного атомарного пакетного API.

Реализация: `emacs-agent-replace-texts` в `emacs-agent-helpers.el`; в prompt
это рекомендуемый default для одной/нескольких exact-text замен, region helper
остаётся для явных координат. Результат и OLD/NEW не содержат скрытой копии
всего исходника. После мутации — только компактные counters/tick/state.
Narrowing на самой границе замены следует обычному `save-restriction`:
вставка на границе может быть включена восстановленным boundary marker,
это не числовое «замораживание» старых bounds.

### Исполняемые примеры в system prompt

После live-ошибки с `:fields` пользователь согласовал точные примеры и для
остальных helpers. Prompt переписан в структурированные правила + 7 примеров:
metadata-only integer tick, первое EOF-safe чтение с полным результатом,
две части продолжения, read→batch с tick того же чтения, around явной позиции,
read→region по реальным bounds и отдельный save. Все примеры синтаксически
полные, на условном живом `example.el` с тремя строками; имена/ranges/OLD/NEW
адаптируются к задаче. Локальные переменные не обещаются между tool calls.

Демонстрация continuation возвращает конкатенацию обеих крошечных частей и
сохраняет next-position/tick/truncated, а не теряет первый фрагмент. В реальных
follow-ups указано брать next/tick из предыдущего результата, не перечитывать
начало. Оговорка output budget для wrappers/stdout сохранена.

Prompt заменяет повторяющуюся прозу, а не наращивается: 5037 → 4984 символа.
Это не замер токенов. `test/emacs-agent-prompt-test.el` извлекает именно fenced
примеры из актуального prompt и запускает каждый через настоящий evaluator
на отдельном временном visiting buffer; проверяет результаты, undo, сохранение,
отсутствие записи при чтении/edits и отказ продолжения после изменения tick.

После live smoke 7 tools / 3065 result characters / 1 EOF error (шесть замен и
save успешны, post-edit чтения не было) пользователь согласовал дополнение:

- `buffer-info`, `read-lines`, `read-around` возвращают `:total-lines` —
  абсолютный whole-buffer count независимо от narrowing. Пустой buffer = 1;
  терминальный newline добавляет пустую строку, как в line-range API.
- Доступ к hidden text это не разрешает. END за EOF по-прежнему ошибка, а не
  silent clamp. EOF-проверка использует тот же count из metadata.
- Первый пример получает count и tick через metadata внутри одного eval,
  читает `1..min(100,total-lines)` и возвращает helper plist целиком. Модель
  получает total-lines/continuation/bounds, а не только text/tick. Извлечение
  полей показано в локальном read→edit, не как основной wire-формат чтения.
- Count вычисляется из текущего текста при каждом вызове, без кэша: для
  больших buffers это проход до EOF, не бесплатная O(1) metadata. В read-lines
  этот проход заменяет прежний самостоятельный подсчёт для EOF-проверки.
- Ревизия покрыта тестами на пустые/короткие/>100-line файлы, newline,
  narrowing и обновление count после edit. Последующий live smoke подтвердил
  отсутствие EOF-ошибок: 4 calls / 7609 result characters / 0 errors, batch из
  шести замен и save успешны. Проверка была усечена на 4096 из 4646 символов;
  последние 550 символов модель не дочитала.
- Пользователь согласовал усиление prompt: при `:truncated t` для полной
  проверки продолжать тот же START/END с next-position и тем же tick до nil.
  По частичному чтению нельзя заявлять полную проверку. Допустима проверка
  только изменённых диапазонов при явно указанном scope; обязательного
  перечитывания всего файла нет. Последний live smoke: 5 calls / 7685 result
  characters / 1 ошибка пустой OLD/NEW-пары до правок; исправленный batch
  применил все 6 замен с исходным tick. Проверка содержала все шесть NEW
  полностью, непрочитанными остались 75 символов неизменённого тела функции.
  `save-buffer` выполнен. Это проверка изменённых блоков, не всего файла.
  Качество Doxygen-комментариев остаётся ответственностью модели: специальных
  правил для этой предметной задачи в агент не добавляем.

### 4. Usage по каждому обращению и всему run

Пользователь разрешил реализацию и smoke на доступной реальной модели.
Проверен установленный gptel 0.9.9.5: `:tokens` — plist текущего HTTP-ответа;
`:tokens-full` — накопленная сумма внутри одного FSM/tool loop. WAIT очищает
текущие tokens, но сохраняет cumulative. Streaming TYPE приходит уже по headers,
до body/usage; текстовый callback, включая `t`, не является универсальной
границей: tool-only/empty non-streaming ответы могут не дать текста вообще.

Контракт для поддерживаемого Chat Completions backend:

- Счётчики имеют явное происхождение `gptel-normalized`: `:input` — uncached
  input, `:output` — output, `:cached` — cache-read. `:input-total` = input +
  cached; `:total` добавляет output ровно один раз. Это расход по запросам, не
  размер context window, не цена и не независимое provider billing измерение.
- Полное отсутствие usage и неизвестные/некорректные поля — символ `unknown`,
  не 0. Настоящие числовые нули сохраняются. Если хотя бы один запрос не имеет
  данного счётчика, соответствующий итог run — unknown, а не частичная сумма.
- Важно: gptel уже преобразует некоторые отсутствующие raw usage fields в 0.
  Этот слой не может восстановить исходное presence. Нормализованный cached=0
  не доказывает отсутствие кэша/наличие cache capability у провайдера. Для raw
  field-presence нужен отдельный parser contract; глобальное advice ради него
  не вводим. Полное отсутствие usage по-прежнему остаётся unknown.
- Ordinal назначается в request-local WAIT, до восстановления protocol и
  сетевого вызова. Текущие tokens также очищаются до восстановления protocol,
  чтобы ошибка setup не присвоила предыдущий usage новому запросу.
- Наблюдения callbacks заменяют скопированные текущие counters, а не суммируются.
  Request закрывается ровно раз в prepended TOOL/DONE/ERRS/ABRT handlers, до
  dispatch, который может синхронно начать следующий WAIT. TYPE не закрывает
  request. Глобальные hooks/handlers gptel не меняются.
- Cancel/error также снимает последнюю копию из FSM info: parser может получить
  usage на [DONE] без нового текстового callback. Незавершённый запрос без
  usage остаётся unknown даже при возможном биллинге. Уже наблюдённые counts
  сохраняются с terminal status; недостоверные стоимости не вычисляются.
- Cumulative snapshot сохраняется только как сверочное свидетельство. Итоги
  считаются из per-request records, не повторным сложением `:tokens-full`.
- Отдельный `emacs-agent-usage.el` хранит ledger и чистую агрегацию; `usage`
  events содержат по одному закрытому request, `usage-total` — итог run.
  Оба типа отображаются в journal, сохраняются/replay через schema 2 events,
  но не попадают в canonical model history. Active run audit содержит `:usage`,
  включая pending unknown; после restart остаётся interrupted audit, не retry.
  Schema bump/migration не нужны: форма events прежняя, audit поле добавлено.
- Перед usage boundary закрывается assistant accumulator: иначе non-streaming
  ответ получал usage event между последним text delta и assistant-end,
  ошибочно оставляя durable block partial. Это покрыто отдельной регрессией.
- Backend/model в журнале — настроенные имя и alias, не доказательство
  физической модели сервера. Никаких credentials/живых transport objects в usage.

Offline coverage: настоящий pinned token normalizer и TOOL→TRET→WAIT recursion
с подменой только HTTP, повторные callbacks, неизвестный второй ответ при
сохранённом cumulative, пустой DONE, ранний TYPE, ошибки/cancel без callback,
изоляция sessions, pending restart audit, journal replay и отсутствие usage в
model history. Независимый review нашёл потерю уже parsed counts при cancel
без callback; finish теперь снимает FSM info, регрессия воспроизводит это окно.
Live smoke stream/non-stream выполнен на временном visiting-free source с
одним `(+ 17 25)` и двумя HTTP-ответами в каждом режиме. Оба завершились,
результат 42, source не изменён; per-request суммы совпали с final cumulative.
Приватные snapshots/metrics вне репозитория, права 0600. Это проверка учёта,
не сравнение token savings/latency между режимами (history/cache различаются).
Полный финальный прогон: 135 ERT и byte compilation с warnings-as-errors.

## Проверка результата

Первый slice: `nix-shell -p gnumake --run 'make clean test compile'` — 99 ERT
и byte compilation с warnings-as-errors. Regression с 50000 символов metadata
и 10 символами текста возвращает полный короткий plain-text result вместо
усечения из-за свойства. Проверен actual pinned-gptel dry-run wire tool content;
его стандартное trimming framing whitespace не менялось. Source properties,
contents, tick, point и undo сохраняются.

Промежуточный live-тест после первого slice: 8 tools/25736 символов результатов
вместо 37/136919, без property dumps и destructive recovery; но buffer-string
не вызывался, так что это не прямое доказательство stripping в live. Почти весь
вывод пришёлся на verbose read helpers. Модель сгруппировала прямые insert/delete
без helper/atomicity и оставила буфер несохранённым; это не завершённый F0c.

Компактное чтение: полный прогон — 103 ERT, warnings-as-errors проходят.
Actual pinned-gptel dry-run проверяет один `:text` с диапазоном в tool content,
без per-line rows. Coverage проверяет все символы, включая newline, продолжение
по limit и печатному budget, EOF/empty lines, around/narrowing и обе исходные
регрессии F0; edit regression обновлён на BASE+string-index внутри :text.
Синтетический fixture 100 строк с total-lines: 7532 → 2144 printed characters (~72% меньше).
Это не token count и не прогноз числа запросов; длина имени буфера/tick слегка
меняет точные числа. Последующие live smoke компактного чтения описаны выше.


Пакетные правки и исполняемые примеры prompt: 126 ERT и byte compilation
с warnings-as-errors. Новый
`test/emacs-agent-batch-edit-test.el` проверяет один общий undo с предыдущей
пользовательской историей, все validation failures до edits, self-overlap,
case-sensitive/adjacent/original-text matching, no-op/insert/delete, read-only,
disabled undo, rollback всего batch на hook/budget errors, изменение planned
OLD hook-ом, hooks с undo boundaries, narrowing/native boundary markers,
внешний file conflict и штатные save/undo/file-modtime. Независимый review
выявил окно между delete/insert: hook может сдвинуть point или изменить текущий
OLD после первоначальной проверки. Воспроизведение подтвердило неверное место
вставки. Общий primitive для region/batch теперь сохраняет insertion anchor,
проверяет OLD последним before-change hook и восстанавливает point перед
вставкой. Новые regressions покрывают сдвиг point обоими hooks, изменение
текущего OLD с atomic rejection и сохранностью предыдущего undo, и смещение
anchor после удаления. Повторный review обнаружил stale bounds у region
helper при таком сдвиге; primitive теперь возвращает реальные marker bounds,
которые используются в region result и проверены отдельной регрессией.
Actual gptel dry-run
проверяет одну tool call для нескольких правок и краткий tool result в wire.
Пользовательские live smoke подтвердили один batch из шести замен и отдельный
save; результаты описаны выше. Undo/rollback этих live batch отдельно не
проверялись; token savings не заявляются.

Каждый slice — полный ERT и byte compilation с warnings-as-errors. Синтетические
fixtures с реалистичными text properties, без приватных исходников и секретов.
Dry-run проверяет настоящий tool result в wire history. Live сравнение отдельно:
одинаковый исходник, фактическая модель/настройки, чистые сессии, сопоставимые
usage/cache metrics, число requests/tools/errors и размеры результатов.
Не обещать заранее токенное ускорение в N раз. Коммит только по запросу.
