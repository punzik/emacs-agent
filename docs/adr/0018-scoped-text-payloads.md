# ADR-0018: Отдельный texts array у единственного eval_elisp

Статус: согласовано пользователем, реализовано; verification ниже.

## Причина и граница

Повторные пользовательские OCaml-диалоги показали, что модель тратит много вызовов
на построение строк Elisp, маркеры кавычек/обратных слешей и их исправление. Это не
доказательство поломки JSON-транспорта. Нужно убрать лишний уровень экранирования
вставляемого текста, не вводя новый tool, sandbox, универсальные bindings или
обход OLD/tick. Приватные диалоги не включаются в репозиторий и не переисполняются.

Согласован один необязательный параметр `texts`: JSON array of strings, доступный
как `emacs-agent-texts`. Массив позволяет передавать несколько OLD/NEW и пакетные
замены, не ограничивая канал конкретным хелпером.

```json
{
  "expression": "(emacs-agent-replace-region \"test.ml\" 1 4 (nth 0 emacs-agent-texts) (nth 1 emacs-agent-texts) :tick 210)",
  "texts": ["old", "let () = print_endline \"Привет\"\n"]
}
```

Числа/имена в примере надо адаптировать к свежему чтению. JSON escaping остаётся;
данные больше не нужно дополнительно превращать в строковый литерал Elisp.

## Исполнение и владение данными

`emacs-agent-eval(EXPRESSION &optional TEXTS)` принимает vector/proper list строк
от Lisp callers. Внутри вызова `emacs-agent-texts` динамически привязан к свежему
списку свежих строк без text properties. Символ по умолчанию nil, не buffer-local.
Привязка доступна при `with-current-buffer` и любым хелперам/native functions.
Последовательные формы одного вызова видят одну привязку; вложенный eval получает
свой payload, а отсутствие параметра маскирует внешний payload пустым списком.

Нет join, normalization, повторного JSON-unescape, read/eval текста, неявного
сохранения или изменения сигнатур текстовых хелперов. Кавычки, Unicode, LF/CR,
буквальные `\\n`, пустые строки и пробелы остаются данными. Read helpers по-прежнему
возвращают свои обычные результаты. Все OLD/tick/undo/narrowing/read-only проверки
сохраняются.

Мутации списка/строк через unrestricted eval не меняют переданные исходные args.
Внешняя привязка восстанавливается после успеха, error, quit и throw. Это не
обещание секретности/песочницы: код может явно сохранить значение в переменную,
файл или closure. Framework не сохраняет runtime binding за пределами вызова;
payload хранится как обычные явные tool arguments в audit/canonical history.

## Adapter, история и долговечность

В production tool schema expression обязателен, texts — optional array с items
string. Pinned gptel декодирует JSON arrays в vectors. Поэтому canonical/live
argument contract принимает expression и необязательный vector строк, в любом
порядке ключей, без unknown/duplicate keys. Omitted texts и `[]` поддерживаются;
явные null, scalar, mixed arrays не являются array of strings.

Malformed arguments отвергаются до eval и записи tool-call/canonical tool result;
run завершается с ошибкой обычным fail-closed путём adapter. Успевшие ранее эффекты
других вызовов не откатываются. Некорректный payload не отравляет последующее
replay неподдерживаемой canonical pair. Duplicate tool IDs по-прежнему не запускают
код повторно. Public Lisp invalid TEXTS сигнализирует до исполнения форм.

Новые поля не отбрасываются: gptel projection получает полный args, native JSON
сохраняет array shape, generic snapshot copier сохраняет vectors, clone/fork
копирует их как data. Schema 3/adapter marker не меняются; старые expression-only
записи/вызовы остаются валидными, restore не исполняет expressions или payload.

Snapshot reader теперь явно использует UTF-8-unix, как writer: тест NUL рядом с
Unicode обнаружил, что autodetection выбирает binary/unibyte и портит literal data.
Это исправление декодирования существующего формата, не migration или исполнение
данных. Проверены повторное сохранение/restore и отдельный offline child с NUL.

Существующие canonical/wire estimates считают все args/schema; summary transcript
включает аргументы с прежним UTF-8 bounded clipping. Нового исключённого из budget
канала данных нет. Сохранённые логи могут содержать полный исходный текст; прежние
0600 file/0700 directory правила и F3 output artifacts не меняются.

## Journal, инструкции и проверка

Expanded tool body показывает expression и отдельные `texts[0]`, `texts[1]` с
буквальным текстом. Folded header остаётся коротким; paired result updates сохраняют
читателя внутри payload, details содержит полные inert args. Старые тела без texts
не меняются. Render не делает read/eval payload или artifact access.

Prompt объясняет общий канал и содержит реальный JSON-пример с OLD/NEW; остальные
примеры остаются Elisp. Тестовый harness декодирует и исполняет оба вида actual
fences. Размер prompt 5392 символа, новый bounded test <5400 вместо <5037:
небольшое увеличение — документация нового API, не набор language-specific hints.
Изменение token usage/поведения модели ещё не измерено.

363 ERT, clean warnings-as-errors compilation и diff-check прошли.
Offline tests охватывают scope/copies/invalid data, nested/multi-form calls,
verbatim Unicode/quotes/backslashes/control characters, native helpers и guards,
actual parser/dispatch/replay, durability/fork/compaction и inert UI. Нет provider
calls, live user-Emacs/hot-load или исполнения исходных приватных диалогов.
