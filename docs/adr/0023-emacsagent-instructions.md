# ADR-0023: EMACSAGENT.md после общих инструкций проекта

Статус: согласовано пользователем, реализовано; verification ниже.

## Решение

Существующий выбор одного общего файла не меняется:
`AGENTS.override.md` → `AGENTS.md` → `AGENTS.MD` → `CLAUDE.md` → `CLAUDE.MD`.
После него независимо читается необязательный `EMACSAGENT.md` из того же
корня проекта. Это дополнительный файл только для нашего агента, не ещё один
кандидат fallback и не замена AGENTS.md. Без общего файла EMACSAGENT.md также
работает. Отсутствие дополнительного файла — нормальный случай.

Оба файла — saved-disk data; opt-out `emacs-agent-project-instructions`
отключает оба. Нет global/parent/child discovery, eval или настройки gptel.
Каждый файл фиксируется при submission и не перечитывается в FIFO, tool
continuation, budget calculation, restore или inspection. System prompt
содержит сначала общий файл, затем специфичный, с явными заголовками путей.

Пустой общий override сохраняет прежний смысл (нет fallback к общему файлу
меньшего приоритета), но не отключает независимый EMACSAGENT.md. Ошибка чтения
одного файла даёт видимое предупреждение и не мешает доставке другого.

## Данные и отображение

Прежние `:status/:root/:path/:text/:warnings` snapshot описывают общий файл.
Необязательный `:emacsagent` содержит отдельный snapshot той же простой формы
для существующего EMACSAGENT.md (loaded или error); отсутствие не добавляет
пустую запись. Тексты не дублируются. Durable pending validation проверяет
оба snapshot, без произвольного рекурсивного вложения. Byte quota и context
budget учитывают полный frozen input/system prompt как прежде.

Журнал и instructions view показывают пути/предупреждения обоих файлов;
view показывает оба зафиксированных текста в порядке доставки. Прежние
snapshots без дополнительного ключа читаются без специальной миграции.

## Проверка

Регрессии: порядок в system prompt, standalone EMACSAGENT.md, отсутствие,
независимые ошибки/пустой override, root-only/opt-out, frozen FIFO и tool
continuation, durable pending restore и read-only view без перечитывания,
валидация повреждённого вложенного snapshot.

406 ERT проходят на исходниках и после компиляции; warnings-as-errors
compilation и diff-check проходят. Команда:
`nix-shell -p gnumake --run 'make clean test compile && make test'`.
Provider calls и live user-Emacs smoke не выполнялись.
