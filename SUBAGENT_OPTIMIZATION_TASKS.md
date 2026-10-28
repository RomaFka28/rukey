# Sub-agent optimization tasks

Цель: выполнить пакет улучшений по производительности, упрощению и надежности без изменения пользовательского поведения.

## Распределение задач

### Agent A — Release/Supply-chain hardening
1. **Высокий приоритет:** добавить checksum для Sparkle-загрузки в [release.yml](/Users/roman/Desktop/рукей/.github/workflows/release.yml).
2. Подготовить минимальные правки документации, если меняется порядок релиза.

### Agent B — Core engine refactor
1. **Средний приоритет:** убрать дублирование в [Detector.swift](/Users/roman/Desktop/рукей/Sources/RukeyCore/Detector.swift).
2. **Низкий приоритет:** оценить удаление locks из Trie. Не удалять их, если публичный
   `insert` сохраняет возможность конкурентной мутации: корректность и потокобезопасность
   важнее микроскопического выигрыша на lookup.

### Agent C — Persistence + measurements + UX polishing
1. **Средний приоритет:** объединить JSON persistence helper для [CustomDictionary.swift](/Users/roman/Desktop/рукей/Sources/RukeyCore/CustomDictionary.swift), [StrikeStore.swift](/Users/roman/Desktop/рукей/Sources/RukeyCore/StrikeStore.swift), [RukeyConfig.swift](/Users/roman/Desktop/рукей/Sources/RukeyCore/RukeyConfig.swift), [SettingsStore.swift](/Users/roman/Desktop/рукей/Sources/RukeyGUI/SettingsStore.swift).
2. **Средний приоритет:** добавить benchmark для памяти и отдельных компонентов.
3. **Низкий приоритет:** debounce для массовых изменений настроек в [SettingsStore.swift](/Users/roman/Desktop/рукей/Sources/RukeyGUI/SettingsStore.swift).

## Критерии приемки

- Проект собирается: `swift build --target RukeyGUI`.
- Бенчмарк запускается: `swift run -c release rukey-measure`.
- Все изменения локальные, точечные, без регресса поведения.
- Для каждого пункта есть явный результат в diff.
