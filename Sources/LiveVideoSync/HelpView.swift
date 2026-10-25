import AppKit
import SwiftUI

/// Окно «?»: вся настройка и решение проблем — чтобы справиться без разработчика.
/// Названия кнопок и меню — по-английски, как на экране (система на английском).
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Live Video Sync — инструкция").font(.largeTitle.weight(.bold))
                Text("Logic шлёт по сети таймкод и ноты-метки → этот Mac показывает нужное видео в нужном месте на экране сцены.")
                    .foregroundColor(.secondary)

                section("Как это работает") {
                    bullet("Сет-лист собирается в программе: **File** → **New Setlist**, перетащи видео в список. Файлы могут лежать где угодно. Порядок — перетаскиванием.")
                    bullet("Номер песни = её место в сет-листе, и от него — нота-метка: песня 1 — C1, 2 — C#1, 3 — D1 … (нота видна в колонке справа). Переставил песню — передвинь её ноту в Logic.")
                    bullet("В Logic на отдельной MIDI-дорожке в начале каждой песни стоит короткая нота-метка. Плеер сам запоминает, где в проекте начинается каждая песня — для этого один раз прогони каждую песню с её начала. Выученная нота-метка яркая, невыученная — бледная.")
                    bullet("Играет **активный** сет (метка **Active**). Открыть другой сет можно, не меняя шоу; **Make Active** — переключить шоу на него.")
                    bullet("Стоп или автостоп в Logic — на экране логотип. Пропала связь посреди песни — видео доиграет само, потом логотип.")
                    bullet("Вместо видео песни можно поставить картинку — она висит, пока не придёт следующая песня, Stop в Logic или кнопка.")
                }

                section("Extras — логотипы групп, реклама, интро") {
                    bullet("Плейлисты Extras общие для всех сетов: **File** → **New Playlist** или **+** внизу боковой панели, файлы — перетаскиванием.")
                    bullet("**▶ Play** — плейлист по порядку. **Repeat**: **Off** — один раз и логотип, **All** — по кругу, **One** — один файл по кругу. Картинки показываются одинаковое время — **Settings** → **General** → **Extras** → **Image duration**.")
                    bullet("**▶** у строки (или двойной щелчок) — один файл: видео до конца и логотип, картинка — пока не придёт другое.")
                    bullet("У видео Extras есть звук. Выход и громкость — **Settings** → **General** → **Extras**.")
                    bullet("Новая песня из Logic перебивает Extras. Песня, которая уже шла, когда запустили Extras, — нет.")
                }

                section("Screen Fit — подгонка под экран площадки") {
                    bullet("Переключатель **Show | Screen Fit** вверху окна (**Cmd+2**). Подгонка действует на всё: песни, Extras, логотип.")
                    bullet("**Test Pattern** (**Cmd+T**) — на экране сцены сетка с красной рамкой по краю. Видно, какая часть картинки реально попадает на экран.")
                    bullet("**Transform** — двигать, масштабировать (Shift — с пропорциями), поворачивать. **Crop** — отрезать края. **Distort** — тянуть углы, если проектор светит под углом. Справа — точные числа, стрелки двигают на 1 px (Shift — 10).")
                    bullet("Подгонку площадки сохрани пресетом: меню пресетов → **Save as Preset…**. Правки сразу сохраняются в выбранный пресет.")
                }

                section("Mac с Logic — настройка (один раз)") {
                    step(1, "Сетевой MIDI-сеанс: **Audio MIDI Setup** → **Window** → **Show MIDI Studio** → двойной клик по **Network** → под **My Sessions** нажми **+** → поставь галочку у **Session 1**.")
                    step(2, "Открой **MIDI Link** (в папке Applications) → выбери Mac с видео → **Connect**. Зелёная точка — готово. Закрой MIDI Link: связь останется, дальше её держит плеер на Mac с видео. **Во время шоу MIDI Link не открывай** — при запуске она меняет настройки сетевого MIDI, а Logic на это может выкинуть окно.")
                    step(3, "В Logic: **File** → **Project Settings** → **Synchronization**:\n• вкладка **General** → **Frame Rate**: **24** или **25** (не 23.976 и не 29.97);\n• вкладка **MIDI** → включи **Transmit MTC** и **Transmit MMC**, назначение — **Session 1**.")
                    step(4, "Дорожка меток: **Track** → **New Track** → **External MIDI**, **Port** — **Session 1**. В начале каждой песни — короткая нота (какая — видно в сет-листе). На **Session 1** не отправляй никакие другие дорожки.")
                }

                section("Mac с видео — настройка (один раз)") {
                    step(1, "Сетевой MIDI-сеанс — так же, как на Mac с Logic: **Audio MIDI Setup** → **Window** → **Show MIDI Studio** → **Network** → **+** → галочка у сеанса.")
                    step(2, "Первый запуск программы: правый клик по Live Video Sync → **Open** → **Open**. Если не открывается — **System Settings** → **Privacy & Security** → **Open Anyway**. На вопрос о локальной сети — **Allow**.")
                    step(3, "**Live Video Sync** → **Settings…** (**Cmd+,**):\n• **Sync** → **Source Mac** — выбери MacBook (Mac, с которого идут таймкод и ноты: Logic, Ableton …). Программа запомнит его и будет сама переподключаться;\n• **Output** → **Display** — экран сцены (обычно First external display), **Logo** — видео логотипа, **While the Player Restarts** — картинка на экране сцены на время перезапуска после сбоя.")
                    step(4, "Собери сет-лист и нажми **Go Live** справа вверху. При следующем запуске вывод включится сам.")
                }

                section("Перед концертом — чек-лист") {
                    bullet("Mac с видео на зарядке, проектор подключён. **System Settings** → **Displays** — расширенный рабочий стол, не **Mirror**.")
                    bullet("Включён **Focus** → **Do Not Disturb** (уведомления программа отключить не может).")
                    bullet("Оба Mac в одной Wi-Fi сети (5 ГГц). Внизу Now Playing — зелёная точка «Source: … · connected».")
                    bullet("MIDI Link и Audio MIDI Setup на Mac с Logic закрыты.")
                    bullet("В Logic все MIDI-устройства проекта подключены (пульт, педали). Иначе при любом сбое сети Logic покажет окно «MIDI port … no longer exists», и пока оно открыто, **автостоп не срабатывает**.")
                    bullet("Нужный сет — **Active**. В заголовке окна «LIVE · <экран>», на экране — логотип.")
                    bullet("**Screen Fit** → **Test Pattern**: красная рамка видна целиком? Выбран пресет этой площадки? Выключи Test Pattern.")
                    bullet("Прогон первой песни: видео идёт, «Locked to MTC», drift около 0.")
                    bullet("В сет-листе нет значков ⚠︎, все ноты-метки яркие (выучены).")
                }

                section("Если что-то не работает") {
                    problem("«Source: … connection lost» или «Waiting for timecode»",
                            "• Оба Mac в одной сети Wi-Fi?\n• **Settings** → **Sync** → **Source Mac** выбран? Можно нажать **Reconnect Now** в баннере. Или на Mac с Logic: **MIDI Link** → **Connect**.\n• В **Audio MIDI Setup** → **Network** у сеанса стоит галочка (на обоих Mac)?\n• На роутере должна быть выключена изоляция клиентов (**AP isolation / Client isolation**).\n• Программа сама пробует подключиться каждые 2 с — по имени и по запомненному IP.")
                    problem("Баннер «This Mac has no network MIDI session»",
                            "На этом Mac нет сетевого сеанса: **Open Audio MIDI Setup** в баннере → **Network** → **+** → галочка. Один раз.")
                    problem("Связь есть, но таймкод не идёт",
                            "• Logic должен играть — таймкод идёт только во время воспроизведения.\n• **File** → **Project Settings** → **Synchronization** → **MIDI**: **Transmit MTC** включён, назначение **Session 1**.")
                    problem("Logic играет, а на экране логотип",
                            "• Нота-метка песни бледная (не выучена) — прогони песню с начала.\n• Нота не та — сверь с нотой в сет-листе.\n• Активен другой сет — нажми **Make Active** на нужном.\n• Дорожка меток идёт не в **Session 1** или выключена (Mute).\n• Видео короче песни — после конца видео всегда логотип, это нормально.")
                    problem("Показывает не ту песню",
                            "Нота-метка в Logic не соответствует месту песни в сет-листе. Поправь ноту, прогони песню с начала — метка перезапишется. Или **•••** → **Reset Marker**.")
                    problem("Стоп в Logic, а видео продолжает играть",
                            "Включи **Transmit MMC** (**Project Settings** → **Synchronization** → **MIDI**), назначение **Session 1**. Без него стоп выглядит как обрыв связи, и видео доигрывает до конца.")
                    problem("Видео дёргается или долго стартует с середины",
                            "Наведи на значок ⚠︎ у песни. «A keyframe only every N s» — пережми видео: H.264, ключевой кадр раз в 1 с (keyframe interval = 24 для 24 к/с), разрешение не больше 1920×1080.")
                    problem("⚠︎ «The original file could not be found»",
                            "Файл переместили, переименовали или отключили диск. Щёлкни по ⚠︎ → **Locate…** и выбери файл — метка и имя песни останутся.")
                    problem("На проекторе ничего нет",
                            "• Баннер «Stage display not found» — Mac не видит экран: проверь кабель, **Display Settings…**.\n• Включён **Mirror** — выключи, нужен расширенный рабочий стол.\n• Выбери экран явно: **Settings** → **Output** → **Display**. Нажата ли **Go Live**?")
                    problem("Картинка не помещается на экран площадки",
                            "**Screen Fit** → **Test Pattern**, затем **Transform** / **Crop** / **Distort**. Если проектор сам выбрал странное разрешение — **Settings** → **Output** → **Resolution**.")
                    problem("Программа закрылась сама",
                            "Она перезапускается сама примерно за секунду и возвращает вывод. Пока перезапускается — на экране сцены картинка из **While the Player Restarts**. Если упала 5 раз за 2 минуты — перестаёт перезапускаться: открой её вручную и пришли лог.")
                    problem("В Logic окно «… sends to a MIDI port … which no longer exists»",
                            "Logic ругается на отсутствующее MIDI-устройство проекта (не на видео) — проверяет он их, когда что-то меняется в сети или MIDI. Воспроизведение продолжается — жми **Continue**. Но пока окно открыто, **автостоп пропускается**. Чтобы окна не было: все устройства проекта подключены (пульт лучше по USB), лишние контроллеры удалены (**Logic Pro X** → **Control Surfaces** → **Setup**, окно **Environment**). Отключить само окно в Logic нельзя.")
                    problem("Связь с Logic совсем пропала, а видео нужно",
                            "Наведи на песню в сет-листе и нажми **▶** (или двойной щелчок) — видео играет с начала до конца, потом логотип и остаётся. **Resume Sync** (**Cmd+R**) или новый Play в Logic вернут управление таймкоду.")
                    problem("Нужно срочно убрать картинку",
                            "**Cmd+B** — Blackout, **Cmd+G** — логотип. Держатся, пока не нажмёшь **Resume Sync** (**Cmd+R**), ту же кнопку ещё раз или пока из Logic не придёт новая песня.")
                }

                section("Клавиши") {
                    bullet("**Cmd+L** — Go Live / Stop Output (остановка — с подтверждением, только щелчком)")
                    bullet("**Cmd+G** — Logo,  **Cmd+B** — Blackout,  **Cmd+R** — Resume Sync")
                    bullet("**Cmd+T** — Test Pattern,  **Cmd+1** — Show,  **Cmd+2** — Screen Fit")
                    bullet("**Cmd+N** — новый сет,  **Shift+Cmd+N** — новый плейлист Extras,  **Cmd+O** — добавить файлы")
                    bullet("В сет-листе: **Return** — переименовать песню (файл не меняется), **Delete** — убрать из сета.")
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
