import AppKit
import SwiftUI

/// Окно «?»: вся настройка и решение проблем — чтобы справиться без разработчика.
/// Названия кнопок и меню — по-английски, как на экране (система на английском).
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Live Video Sync — инструкция").font(.largeTitle.weight(.bold))
                Text("Logic шлёт по Wi-Fi таймкод и ноты-метки → этот Mac показывает нужное видео в нужном месте на экране сцены.")
                    .foregroundColor(.secondary)

                section("Как это работает") {
                    bullet("Видео лежат в одной папке. Песня — файл, имя которого начинается с номера: «01.mp4», «7 Intro.mp4», «12_Song.mp4». Логотип — файл со словом «logo» в имени.")
                    bullet("В Logic на отдельной MIDI-дорожке в начале каждой песни стоит короткая нота-метка. Какая нота нужна песне — смотри колонку Marker в таблице (песня 1 — C1, 2 — C#1, 3 — D1 …).")
                    bullet("Плеер сам запоминает, где в проекте начинается каждая песня (колонка Starts in Logic). Для этого один раз прогони каждую песню с её начала.")
                    bullet("Стоп или автостоп в Logic — на экране логотип. Пропала связь посреди песни — видео доиграет само, потом логотип.")
                    bullet("Порядок песен задаёт проект Logic, а не номера файлов. Новое интро — любой свободный номер и своя нота.")
                }

                section("Mac с Logic — настройка (один раз)") {
                    step(1, "Сетевой MIDI-сеанс: **Audio MIDI Setup** → **Window** → **Show MIDI Studio** → двойной клик по **Network** → под **My Sessions** нажми **+** → поставь галочку у **Session 1**.")
                    step(2, "Открой **MIDI Link** (в папке Applications) → выбери Mac с видео → **Connect**. Зелёная точка — готово. Закрой MIDI Link: связь останется, дальше её держит плеер на Mac с видео. **Во время шоу MIDI Link не открывай** — при запуске она меняет настройки сетевого MIDI, а Logic на это может выкинуть окно.")
                    step(3, "В Logic: **File** → **Project Settings** → **Synchronization**:\n• вкладка **General** → **Frame Rate**: **24** или **25** (не 23.976 и не 29.97);\n• вкладка **MIDI** → включи **Transmit MTC** и **Transmit MMC**, назначение — **Session 1**.")
                    step(4, "Дорожка меток: **Track** → **New Track** → **External MIDI**, **Port** — **Session 1**. В начале каждой песни — короткая нота (номер ноты — колонка Marker). На **Session 1** не отправляй никакие другие дорожки.")
                }

                section("Mac с видео — настройка (один раз)") {
                    step(1, "Сетевой MIDI-сеанс — так же, как на Mac с Logic: **Audio MIDI Setup** → **Window** → **Show MIDI Studio** → **Network** → **+** → галочка у сеанса.")
                    step(2, "Первый запуск программы: правый клик по Live Video Sync → **Open** → **Open**. Если не открывается — **System Settings** → **Privacy & Security** → **Open Anyway**. На вопрос о локальной сети — **Allow**.")
                    step(3, "В окне программы: **Videos** → **Choose…** — папка с видео; **Display** — экран сцены (обычно First external display); масштаб — **Fit / Fill / Fit height / Fit width**.")
                    step(4, "**Logic Mac** → выбери MacBook → **Connect**. Программа запомнит его и будет сама переподключаться.")
                    step(5, "**GO LIVE**. При следующем запуске трансляция включится сама.")
                }

                section("Перед концертом — чек-лист") {
                    bullet("Mac с видео на зарядке, проектор подключён. **System Settings** → **Displays** — расширенный рабочий стол, не **Mirror**.")
                    bullet("Включён **Focus** → **Do Not Disturb** (уведомления программа отключить не может).")
                    bullet("Оба Mac в одной Wi-Fi сети (5 ГГц). В окне программы — зелёная точка и «Network: …».")
                    bullet("MIDI Link и Audio MIDI Setup на Mac с Logic закрыты.")
                    bullet("В Logic все MIDI-устройства проекта подключены (пульт, педали). Иначе при любом сбое сети Logic покажет окно «MIDI port … no longer exists», и пока оно открыто, **автостоп не срабатывает**.")
                    bullet("Справа сверху «Live on <экран>», на экране — логотип.")
                    bullet("Прогон первой песни: видео идёт, внизу заголовка «locked to MTC», drift около 0.")
                    bullet("Под таблицей нет оранжевых предупреждений. У всех песен есть Starts in Logic.")
                }

                section("Если что-то не работает") {
                    problem("Красная точка, «Logic Mac not connected»",
                            "• Оба Mac в одной сети Wi-Fi?\n• На Mac с видео: **Logic Mac** → **Connect**. Или на Mac с Logic: **MIDI Link** → **Connect**.\n• В **Audio MIDI Setup** → **Network** у сеанса стоит галочка (на обоих Mac)?\n• На роутере должна быть выключена изоляция клиентов (**AP isolation / Client isolation**).\n• Программа сама пробует подключиться каждые 2 с — по имени и по запомненному IP.")
                    problem("«No network MIDI session»",
                            "На этом Mac нет сетевого сеанса: **Audio MIDI Setup** → **Window** → **Show MIDI Studio** → **Network** → **+** → галочка. Потом перезапусти программу.")
                    problem("Связь есть, но таймкод не идёт (серые цифры)",
                            "• Logic должен играть — таймкод идёт только во время воспроизведения.\n• **File** → **Project Settings** → **Synchronization** → **MIDI**: **Transmit MTC** включён, назначение **Session 1**.")
                    problem("Logic играет, а на экране логотип",
                            "• У песни нет Starts in Logic — прогони её с начала (через ноту-метку).\n• Нота не та — сверь с колонкой Marker.\n• Дорожка меток идёт не в **Session 1** или выключена (Mute).\n• Видео короче песни — после конца видео всегда логотип, это нормально.")
                    problem("Показывает не ту песню",
                            "Нота-метка в Logic не соответствует номеру файла (колонка Marker). Поправь ноту, прогони песню с начала — метка перезапишется. Или нажми **Reset** у песни.")
                    problem("Стоп в Logic, а видео продолжает играть",
                            "Включи **Transmit MMC** (**Project Settings** → **Synchronization** → **MIDI**), назначение **Session 1**. Без него стоп выглядит как обрыв связи, и видео доигрывает до конца.")
                    problem("Видео дёргается или долго стартует с середины",
                            "Посмотри оранжевые предупреждения под таблицей. «Ключевой кадр раз в N с» — пережми видео: H.264, ключевой кадр раз в 1 с (keyframe interval = 24 для 24 к/с), разрешение не больше 1920×1080.")
                    problem("На проекторе ничего нет",
                            "• Справа сверху «Waiting for display…» — Mac не видит экран: проверь кабель, **System Settings** → **Displays**.\n• Включён **Mirror** — выключи, нужен расширенный рабочий стол.\n• Выбери экран явно в **Display**. Нажата ли **GO LIVE**?")
                    problem("Программа закрылась сама",
                            "Она перезапускается сама примерно за секунду и возвращает трансляцию. Если упала 5 раз за 2 минуты — перестаёт перезапускаться: открой её вручную и пришли лог.")
                    problem("В Logic окно «… sends to a MIDI port … which no longer exists»",
                            "Logic ругается на отсутствующее MIDI-устройство проекта (не на видео) — проверяет он их, когда что-то меняется в сети или MIDI. Воспроизведение продолжается — жми **Continue**. Но пока окно открыто, **автостоп пропускается**. Чтобы окна не было: все устройства проекта подключены (пульт лучше по USB), лишние контроллеры удалены (**Logic Pro X** → **Control Surfaces** → **Setup**, окно **Environment**). Отключить само окно в Logic нельзя.")
                    problem("Связь с Logic совсем пропала, а видео нужно",
                            "В таблице у каждого видео кнопка **▶** — видео играет с начала до конца, потом логотип и остаётся. Как только в Logic снова нажмут Play — управление вернётся к таймкоду.")
                    problem("Нужно срочно убрать картинку",
                            "**Cmd+B** — затемнение, **Cmd+G** — логотип (снимется следующей песней). Повторное нажатие — вернуть.")
                }

                section("Клавиши") {
                    bullet("**Cmd+L** — GO LIVE / остановить трансляцию")
                    bullet("**Cmd+B** — затемнение,  **Cmd+G** — логотип вручную")
                    bullet("**Cmd+1…4** — масштаб: Fit / Fill / Fit height / Fit width")
                    bullet("**Cmd+Q** — выход (спросит). Закрыть окно можно — видео продолжит идти.")
                }

                section("Файлы") {
                    bullet("Лог: \(Log.url.path)")
                    bullet("Настройки и метки: \(Store.settingsURL.path)")
                    HStack {
                        Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                        Button("Show Settings in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Store.settingsURL]) }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 600)
    }

    /// Markdown (**жирный**) с сохранением переносов строк
    private func md(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundColor(.secondary)
            md(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.headline).frame(width: 22, height: 22).background(Circle().fill(Color.accentColor.opacity(0.35)))
            md(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func problem(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            md(text).fixedSize(horizontal: false, vertical: true).foregroundColor(.primary.opacity(0.9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// Окно инструкции — одно на программу
enum HelpWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Live Video Sync Help"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HelpView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
