# ADR-0007: Контекст steering и финальная граница

Статус: семантика контекста и final boundary согласована пользователем.
Offline spike текущего pinned gptel FSM выполнен; пользовательский pending/UI
steering ещё не реализован.

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
