# ADR-0003: Durable streaming-блоки F0b

Статус: принято пользователем; реализовано, проверено offline.
Пользователь исключил миграцию и обратную совместимость: приложение в глубокой
альфе. Исследованы реализации Pi и Pigo. Partial checkpoints сохраняются.

## Контекст

Schema 1 хранит каждую assistant/reasoning delta как отдельное событие.
Model messages уже собираются отдельно и служат единственным источником replay.
Renderer склеивает соседние текстовые события одного типа/run и сбрасывает
appendable tail на end-событиях и остальных смысловых границах.

Цель F0b — уменьшить постоянный архив, не менять live streaming, текст журнала,
порядок, смысловые границы, model history или восстановление interrupted runs.
Это не LLM compaction, summary или удаление reasoning.

## Исследование аналогов

### Pi

Исходники: `/home/np/projects/personal/pi/pi`, штатный coding-agent SessionManager.

- `packages/coding-agent/src/core/agent-session.ts:1144–1164`: сохранение
  сообщения на `message_end`, не `message_update`. Streaming partial живёт
  отдельно в памяти/UI; обычных промежуточных streaming checkpoints нет.
- `packages/coding-agent/src/core/session-manager.ts:1161–1215`: JSONL-дерево
  записей, сообщение целиком с id/parentId/timestamp. После первоначальной
  выгрузки — append, не snapshot. Сериализация компактная, без pretty-print.
- `packages/agent/src/agent-loop.ts:459–468`: сохраняемый finalMessage берётся
  из результата stream. Error/aborted тоже могут завершить message; это не
  гарантия сохранения каждого показанного символа при любом исключении.
- `packages/ai/src/types.ts`: assistant содержит массив text/thinking/toolCall
  blocks с provider metadata/signatures. Контекст строится из выбранной ветви,
  не из журнала token deltas. Подписи — opaque replay data, не мусор.
- В штатном append writer нет temp-file/rename, явного fsync или транзакции
  нескольких records. Это не повод ослаблять наш существующий atomic snapshot.

### Pigo

Исходники: `/home/np/projects/personal/pi/pigo`.

- `internal/session/session.go:292–329`: append-only JSONL, entry с parent,
  затем отдельный head_update. Это дерево сообщений, не архив streaming deltas.
  Каждая запись синхронизируется, но entry/head не одна транзакция.
- `internal/agent/agent.go:280–339`: текст/reasoning накапливаются в памяти;
  после успешного stream формируется assistant message. Все reasoning chunks
  объединяются перед text, исходное чередование не сохраняется.
- `internal/app/run.go:490–524`: deltas отправляются UI, durable assistant
  сохраняется после успешного `Agent.Run`. При отмене/stream error в этом пути
  накопленный текущий partial не записывается как assistant message.
- Переносимый принцип: durable единица — логическое сообщение/блок, не token.
  Не переносим потерю partial и перегруппировку reasoning: наши требования
  сохраняют partial checkpoints и исходный порядок журнала.

### Вывод для F0b

Оба проекта подтверждают принцип: durable единица — логическое сообщение/блок,
не token delta. Ни формат JSONL, ни tree/branching не нужны ради уменьшения
наших snapshots; добавлять их в F0b было бы отдельной архитектурной сменой.
Сохраняем atomic snapshot и независимый model history, агрегируем только копию
UI-events. В отличие от штатных путей аналогов, сохраняем промежуточный partial
при checkpoint и исходный порядок interleaved reasoning/assistant. Миграцию
не реализуем. Технический формат блоков ниже выбран для этих требований,
а не скопирован из Pi/Pigo.

## Решение

### Schema 2

Оставить верхнеуровневую структуру snapshot и отдельные `:messages`.
Склеивать только соседние строковые assistant/reasoning события с одинаковыми
session/run/type. Любой иной тип, end, tool, status, смена run/type или
неизвестные дополнительные поля — граница; через неё не склеивать.

Блок сохраняет `:id`/`:time` первого фрагмента, `:last-id`/`:last-time`
последнего, исходные `:session-id`, `:run-id`, `:type`, точный объединённый
`:payload` и `:state` (`partial` или `complete`). Пустые chunks не выбрасываются:
последовательность пустых chunks представляется блоком с пустой строкой.

Lossless относится к тексту, порядку, смысловым границам и replay, не к точной
истории доставки token chunks: промежуточные ID/timestamps намеренно исчезают.
Массив идентификаторов всех deltas не хранится.

`complete` означает только непосредственно следующий соответствующий
`assistant-end`/`reasoning-end` того же session/run. Во всех остальных случаях
`partial`: при interleaving ранний блок консервативно остаётся partial даже
если end был позже. Это не статус успеха HTTP/run: текущий assistant flush
выдаёт end и при cancel/error. Reasoning без end остаётся partial. Не выводить
неподанные границы HTTP из текста или итогового статуса.

### Live state и восстановление

Преобразовывать проверенную глубокую копию данных только для snapshot.
Live event list, его cons-ячейки, cursor renderer, накопленные chunks и gptel
callbacks не трогать. Model messages/protocol/tool IDs/results не изменять;
сохранение текущего незавершённого assistant message остаётся прежним.

После restore блоки остаются блоками: renderer использует прежние type/payload,
добавочные поля игнорирует. Новые события добавляются обычным способом.
Преобразование должно быть идемпотентно для смеси блоков и deltas, сохраняя
первые/последние IDs/times. Счётчик восстанавливается также по `:last-id`.
Никакие actions не возобновляются. Первый restore активного run по-прежнему
добавляет interrupted audit; это отдельный эффект, не ошибка идемпотентности
агрегации.

### Запись без обратной совместимости

По решению пользователя миграция schema 1, compatibility reader, backup старой
схемы и отдельная команда миграции не нужны. Новая версия читает только новый
формат; старые snapshots отклоняются явно, а не интерпретируются приблизительно.
Не выполнять массовое удаление или перезапись пользовательских архивов.

Сохранить существующие atomic rename, permissions 0600/0700 и corruption
isolation. Ошибка подготовки/записи/rename нового snapshot оставляет прежний
файл целым. Данные не исполняются. Atomic rename не обещает fsync/crash durability.

Новую запись делать pretty-printed data-only Lisp. Это улучшение читаемости,
не замена измерению реального уменьшения числа событий/байтов.

## Проверки перед принятием реализации

Синтетические fixtures, без приватных логов: полный текст и renderer до/после,
interleaving, пустые chunks, несколько HTTP-ответов одного run, tools/statuses,
разные run, reasoning при скрытом отображении, checkpoint в середине stream,
продолжение без дублей, cancel/error, повторные save/restore и идемпотентность.
Реальный gptel dry-run wire replay должен сохранять tool pairs и protocol.
Проверить явный отказ на старой/неизвестной схеме, сбои write/rename/валидации,
permissions, corruption isolation, interrupted runs и отсутствие повторных
действий. Измерить число событий и байты; полный ERT и warnings-as-errors.

## Результаты реализации

`emacs-agent-store.el` реализует schema 2, валидацию исходных записей **до**
агрегации, линейную по числу событий агрегацию (каждый payload склеивается один
раз на блок), проверку durable metadata, pretty-print и восстановление крайних
ID. Неизвестные поля не отбрасываются: такой text event остаётся отдельным
блоком. Неподдерживаемая схема явно отклоняется с предложением нового data dir.
Live event list/renderer/gptel/model records не менялись.

Полный прогон `nix-shell -p gnumake --run 'make clean test compile'`: 95 ERT,
0 failures, byte compilation с warnings-as-errors. Новые regressions находятся
в `test/emacs-agent-blocks-test.el`: renderer и fold bounds при обоих display
policies, end/tool/status/run/metadata/non-string границы, пустые chunks,
повторные checkpoints/продолжение, cancel/error/interrupted, неизменность live
cursor/chunks/messages, mixture restored blocks + новые deltas, counter по
last-id, проверка повреждений до merge, отказ schema 1, write failure, свежий
batch Emacs без gptel. Существующий rename-failure regression тоже проходит.
Фактический pinned-gptel dry-run wire JSON совпадает до/после restore для всех
context policies с исходными tool pairs и protocol reasoning.

Synthetic fixture без canonical model messages: 4002 события → 4, примерно
460 КБ schema-1-style snapshot → 11 КБ pretty-printed schema 2 (~42×).
Это не прогноз для всех пользовательских архивов; timestamps немного меняют
точное число байтов между прогонами. Общая память live history и полный обход
истории при save остаются. Копирование/валидация/печать всё ещё синхронны;
ускорение UI не заявляется без отдельного benchmark. Частные логи не использованы
в fixtures и не изменялись. Live smoke F0b с провайдером ещё не выполнялся.

Основание: [roadmap, F0b](../POST_MVP_ROADMAP.md).
