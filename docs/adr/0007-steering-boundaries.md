# ADR-0007: Контекст steering и финальная граница

Статус: семантика контекста и final boundary согласована пользователем.
Offline spike выполнен. Пользователь согласовал pending UX ниже;
production реализация прошла offline проверку; пользователь также сообщил,
что проверил результат, и одобрил commit.

## Принятые решения

- Steering относится к уже работающему run, обычный ask сохраняет FIFO
  самостоятельных задач. Доставка — после полной tool batch, перед следующим
  HTTP-запросом, не между отдельными инструментами.
- Снимок уточнения захватывается по месту его ввода. При policy `current`
  модель сохраняет исходный снимок run и снимки всех доставленных уточнений
  этого run до его завершения. Это не замена исходного снимка последним.
- Ожидающий/отозванный input не меняет delivered model history или current.
  При новом самостоятельном run старые snapshots остаются audit/history,
  но не отправляются при `current`. Policy `full` и nil сохраняют свой смысл.
- Для `current` соседние одинаковые snapshots сравниваются целиком (`equal`),
  включая region/text/narrowing, а не только file/point. Дублируется не pointer,
  но текст уточнения доставляется всегда. A→B→A не схлопывается.
  Исходные snapshots сохраняются в audit даже при устранении wire-дубликата.
- Контекст — диагностический снимок, не живой marker и не доказательство
  актуальности текста. Steering не меняет session и default execution buffer
  инструментов текущего run.
- Если уточнение не успело в следующую генерацию до final boundary,
  считать его новым запросом в обычной FIFO-очереди той же сессии, без
  переоткрытия завершённого run. Сохранять введённый текст и снимок; не
  перечитывать их молча при превращении в новый запрос.
- Эта final policy не означает auto-retry после cancel/error: недоставленный
  текст там сохраняется для явного повторного использования, не запускается.

## Следующая проверка

Проверить приватный handler перед стандартным WAIT, после TRET/protocol
restoration: оба tool results уже должны быть в wire data. Пауза по tool budget
не должна доставить уточнение раньше последнего результата. Сравнить
canonical history и actual dry-run, не полагаться на текстовые callbacks.
На DONE уточнение должно становиться отдельным run через существующий FIFO,
без дополнительной генерации в старом FSM. Global gptel handlers не менять.
UI, pending lifecycle/limits, отзыв/редактирование и recovery реализуются после
этого spike; сам spike не добавляет пользовательскую команду steering.

## Результат spike и основа нормализации

`test/emacs-agent-steering-spike-test.el` использует настоящий pinned parser,
TOOL→TRET→WAIT и default handlers; подменён только сетевой HTTP. Локальный
прототип вставляет inputs после protocol restoration, перед `gptel--handle-wait`.
Оба результата инструментов уже находятся в wire. При budget=1 после первого
инструмента нет ни HTTP, ни доставки; resume исполняет второй и лишь затем
передаёт inputs. Прогнаны nil/current/full, A→A→B→A, сохранение исходного source
и context. Следующий самостоятельный run при current получает только свой
snapshot, full сохраняет все, nil не отправляет context. Global handlers не
меняются. На DONE prototype создаёт отдельный run; уже queued обычный ask
идёт раньше, повторный terminal callback не добавляет input повторно.

Обнаружено ограничение прежней нормализации: один user input на run-id.
Добавлено optional `:input-id` для user records: дополнительные inputs в том же
contiguous run требуют nonempty уникального ID. Неименованные дубликаты,
повторы input-id, неправильные типы и возврат к прежнему run после нового
запрещены. Старые single-input записи остаются валидными; schema не меняется.
Model wire не получает служебные input-id.

Projection `current` хранит весь контекст группы run, пропуская только соседние
полностью equal snapshots; текст остаётся всегда. Изменение region text при
том же point не дедуплицируется, A→B→A сохраняется. Canonical snapshots и
messages не мутируются; full не дедуплицируется. Это уже реализованная основа,
но не API доставки/управления pending input.

При reserialization gptel объединяет некоторые соседние user messages; поэтому
проверяются все rendered context blocks и текст, а не равенство числа wire
messages числу inputs. Это не потеря snapshots и не смена run.

161 ERT и byte compilation с warnings-as-errors прошли. Новых real-model
запросов в spike нет. Production WAIT/DONE не получили steering handlers:
прототип живёт только в тестах. Ещё предстоит заморозка всех prepared inputs
при финальном преобразовании (включая resources/config), лимиты, команды,
редактирование/отзыв, сохранение pending и cancel/error recovery.

## Согласованный UX после spike

- Pending view охватывает обычные ожидающие ask и steering. `ask` остаётся
  независимым FIFO; отмена активной задачи по-прежнему не отменяет следующие
  обычные ask. Недоставленные steering отменённой/ошибочной задачи — recovery,
  не продолжение следующего run.
- Редактирование сначала отзывает input, до открытия minibuffer. RET повторно
  ставит его в конец, сохраняя context/config/instructions; C-g оставляет
  исходный текст отозванным и доступным. Доставленные inputs неизменяемы.
- Лимиты на сессию: 8 недоставленных inputs, включая withdrawn/recovery;
  256 КиБ суммарных frozen payload (UTF-8 Lisp serialization полей run,
  включая text/context/instructions, без backend objects/credentials).
  Mutable lifecycle metadata не расходует payload budget. Лимиты настраиваемы;
  overflow отклоняет новый ввод, не вытесняет старый. Отозванный input можно
  явно забыть с подтверждением; audit остаётся. Retention всего старого audit
  относится к последующим этапам, не к этой pending квоте.
- После cancel/error/restart автоматической отправки recovery нет. Явная
  повторная отправка остановленного/restarted input — новый самостоятельный
  запрос. У ещё живого target ручное редактирование steering сохраняет intent
  steering. Исходный context/instructions не переснимаются. После restart
  живой source и configured backend проверяются/при необходимости выбираются
  явно; credentials не сериализуются. Model/stream/policy/budget остаются
  snapshot, проблемы конфигурации возвращаются ошибкой, без молчаливой замены.
- `steer` при изначально idle session — user-error. Paused run принимает ввод,
  но ждёт остаток batch. Target захватывается до minibuffer: если за это время
  завершился, новый input становится FIFO ask той же сессии; если отменился
  или упал, текст сохраняется для recovery. Не направлять его новому active run.

## Production реализация

`emacs-agent-input.el` отделяет prepared input от исполнения. У каждого input
есть стабильный ID и frozen run; pending ledger хранит только недоставленные
или withdrawn записи. Доставка удаляет запись из ledger до reentrant hooks;
canonical user records сохраняют input-id и исходные snapshots. Повторная
постановка недоставленного текста сохраняет ID, поскольку в model history
его ещё нет. Forgotten/delivered данные остаются в audit, не в live quota.

Приватный WAIT wrapper сохраняет pinned default handlers, но проверяет live
ownership перед каждым transport handler. Только TRET с полными results всей
batch допускает steering. Preview history и copied wire проходят validation
до commit. Между commit canonical/wire/identities и запуском HTTP нет event
hooks; затем публикуется один audit batch. Успешный возврат transport отмечается
временными forwarding bindings curl/url, строго для данного FSM; другие FSMs
делегируются без изменений, global advice/hooks не устанавливаются. Ошибка до
launch откатывает ещё живой claim в recovery; ошибка post-request hook после
launch сохраняет delivered history. Это граница запуска, не provider ack.
Повтор WAIT без нового INIT/TRET не запускает новый HTTP.
Usage остаётся per-HTTP, а не per-input. Initial WAIT steering не принимает.

DONE disposition централизован в finish: оставшиеся queued steering inputs
становятся fresh run objects с собственными сохранёнными context/source,
backend/model/stream/policy/tool budget/instructions; они идут позади уже
стоящих обычных ask. Ничего не перечитывается. Cancel/error снимает eligibility
сразу до event hooks; повторные terminal/stale callbacks не конвертируют input
повторно. Active system prompt и default execution source steering не меняет.

Schema 2 получает optional `:inputs`; это расширение data как ранее frozen
instructions, без миграции/исполнения старых записей. Данные проверяются до
registry update. Restore создаёт только withdrawn/restart, не transports,
очередь выполнения или backend objects. Повтор restore→save→restore сохраняет
recovery. IDs резервируются до новых interrupted events. Сохраняются fast
per-record printer (включая inputs), atomic rename, 0600 и best-effort autosave:
ошибка записи видна, но не откатывает уже выполненные tools/начатый HTTP.
Offline inspection по-прежнему не требует установленного gptel.

Команды: `emacs-agent-steer`, `emacs-agent-pending`. В pending view `g` refresh,
`e` edit, `d` withdraw, `r` explicit recover, `D` forget с подтверждением,
RET — полный текст без context/API JSON. Live view обновляется на lifecycle,
не на streaming deltas; callbacks не создают и не выбирают окна.
Journal: C-c C-s steering, C-c C-p pending. Global bindings не добавляются.

## Проверка production

187 ERT и warnings-as-errors compilation прошли. Проверены actual pinned SSE
с индексами calls и non-stream parsing, полная batch/pause-resume, nil/current/
full и A→A→B→A, final FIFO без reread и с другим frozen model/stream/budget,
withdraw/edit/abort/overflow UTF-8, inert durable recovery и malformed input
rejection до registry update. Recovery сохраняется повторным save/restore;
подтверждены отсутствие secrets/backend objects и permission/atomic-failure.

Независимый review воспроизвёл три bugs, исправленные regression ERT:
assistant-end recursive finish терял нового FIFO owner; tool-call cancel всё
ещё запускал eval; ошибка post-request hook возвращала уже отправленный
steering в recovery. Теперь terminal ownership claimed до любых hooks,
clear active только при eq owner; после tool-call live проверяется заново;
post-launch exception не откатывает доставленный текст. Отдельно проверено,
что reentrant уточнение на final не обгоняет ранее принятые inputs.

Прежний приватный ~391 КБ sample: full atomic save ~15 мс, 5 повторов без GC.
Модель и пользовательские исходники не трогались; новых provider вызовов и
interactive F2 smoke не было. Старые in-memory structs в рабочем Emacs не
перезагружались: для применения нужен restart. Файлы schema 2 читаются без
миграции. Затем пользователь сообщил «Проверил» и одобрил commit.
Подробности пользовательского прогона не фиксировались: это не отдельный
инструментированный отчёт по всей real-provider smoke matrix.
