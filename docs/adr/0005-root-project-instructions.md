# ADR-0005: Инструкции только из корня проекта

Статус: scope, приоритет файлов и доставка через system prompt согласованы
пользователем; ограниченный F1 реализован и проверен offline.

## Контекст

После F0c пользователь сузил F1: глобальных инструкций пока нет, проектные
искать только в корне. Prompt templates оказались необязательным удобством;
без конкретных повторяющихся сценариев их реализация преждевременна.

## Принятые решения

- Глобальные инструкции нигде не искать.
- Project discovery ограничен одним корнем проекта, без обхода родителей и
  вложенных каталогов рабочего буфера.
- Один файл по приоритету: `AGENTS.override.md` → `AGENTS.md` → `AGENTS.MD` →
  `CLAUDE.md` → `CLAUDE.MD`. Файлы не конкатенируются между собой.
- Templates отложены: в F1 нет их discovery, выбора, параметров и escaping.
- Остальной базовый контракт F1 сохраняется: snapshot для submitted input,
  неизменность в FIFO/run, opt-out и видимость загруженных путей/предупреждений.
  Instructions независимы от diagnostic editor context/history policy.
- Содержимое инструкции — данные, не исполняемый Lisp; оно не перенастраивает
  endpoint, credentials или полномочия единственного `eval_elisp`.

## Принятая доставка

Добавлять зафиксированное содержимое выбранного файла отдельным блоком в
system prompt текущего run. Один снимок используется во всех HTTP итерациях
этого run; запуск ожидающего запроса не перечитывает файл. Пользовательский
текст не переписывается. Старые снимки остаются в durable audit, но не
добавляются повторно в последующие run. Отключение editor context не влияет
на отправку project instructions.

Это небольшой загрузчик и интеграция с подготовкой run, не общий resource
framework под отложенные global/hierarchy/templates. Проверить
snapshot/persistence, opt-out и фактический wire dry-run.

## Детали реализации

Чтение выполняется с диска без visiting buffer/major mode/local variables,
после ввода непустого текста перед enqueue. Исходный buffer/root/point
захватываются как прежде до минибуфера; источник buffer-local opt-out —
исходный буфер, не выбранный после ввода. Несохранённые edits instruction
buffer не подмешиваются молча: действует последнее сохранённое содержимое.

Первый существующий кандидат выбран окончательно, включая пустой файл.
Directory/broken symlink/unreadable candidate даёт warning и пустую доставку,
не скрытый fallback к инструкции с меньшим приоритетом. Обычное отсутствие
всех кандидатов или project root — не ошибка. Чтение не ограничивает eval_elisp;
symlink в корне следует обычной файловой семантике, это не sandbox boundary.

Snapshot хранится в run audit и отдельном instructions event, не в canonical
model messages. Journal показывает статус/путь/warnings; отдельная команда
показывает захваченное содержимое, не перечитывая файл. Новый run получает
новый снимок; прежние snapshots остаются только в audit. Opt-out — boolean
настройка `emacs-agent-project-instructions`, которую при необходимости можно
сделать buffer-local. Просмотр — `emacs-agent-show-instructions`.

## Проверка

148 ERT и warnings-as-errors compilation прошли. Настоящий gptel dry-run
подтверждает system block текущего snapshot и unchanged user text при
отключённом editor context; FIFO, tool continuation и restart не перечитывают
старый input и не добавляют прежние snapshots в новые run. Реальный
TOOL→TRET→WAIT вызван с подменой только HTTP, проверено сохранение system
message после file/opt-out change. Проверены все filename priorities, empty
override, invalid/unreadable/broken-link warnings без fallback, отсутствие
parent/global/child search, saved vs unsaved text, отсутствие local Lisp eval,
source opt-out при смене buffer в minibuffer, capture timing, blank/aborted
input без I/O, immutable pending audit и read-only view, включая warnings
после restore. Независимый review подтверждённых багов не нашёл; предложенные
им граничные регрессии добавлены. Нового real-provider F1 smoke не было.
