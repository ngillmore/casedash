// casedash host -- Qt6/QML dashboard pinned to a specific Wayland output.
//
// WHY A C++ HOST AT ALL: qmlscene/qml6 refuse to instantiate Window types
// ("Type cannot be created in QML"), so a compiled host is mandatory.
//
// WHY LAYERSHELLQT IN C++: QWindow::setScreen() is silently ignored before
// show() on Qt's Wayland backend -- request DP-1, get the primary. Output
// pinning therefore has to go through LayerShellQt::Window::setScreen(), which
// sets it on the wlr-layer-shell surface rather than the xdg toplevel. That
// capability is the entire reason we are leaving Conky (upstream issue #2106:
// no output selection at all).
//
// The QML side talks to the collector's state.json through a file-watcher
// backend object exposed as the "Backend" context property.
#include <QGuiApplication>
#include <QQmlEngine>
#include <QQmlContext>
#include <QQmlComponent>
#include <QQuickWindow>
#include <QCommandLineParser>
#include <QScreen>
#include <QFileSystemWatcher>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QDateTime>
#include <QVariant>
#include <QDebug>
#include <QUrl>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <unistd.h>
#include <cstdio>

#include <LayerShellQt/Window>

// Qt's default message handler prints nothing when stderr is not a tty in this
// environment, which turned a QML load error into a silent exit code 1. Route
// every diagnostic through our own handler so failures are always visible --
// a black panel with no explanation is the exact failure mode we are replacing.
static void casedashMessageHandler(QtMsgType type, const QMessageLogContext &,
                                   const QString &msg)
{
    const char *tag = "info";
    switch (type) {
    case QtDebugMsg:    tag = "debug"; break;
    case QtInfoMsg:     tag = "info";  break;
    case QtWarningMsg:  tag = "WARN";  break;
    case QtCriticalMsg: tag = "CRIT";  break;
    case QtFatalMsg:    tag = "FATAL"; break;
    }
    fprintf(stderr, "casedash [%s] %s\n", tag, qUtf8Printable(msg));
    fflush(stderr);
}

// ---------------------------------------------------------------------------
// Backend: reads the collector's JSON blob and hands it to QML.
// Polled on a timer AND watched, so a fresh collector write lands immediately
// while a restarted collector is picked up within one tick regardless.
// ---------------------------------------------------------------------------
class Backend : public QObject
{
    Q_OBJECT
    // The whole decoded state, exposed to QML as `Backend.state.<field>`
    Q_PROPERTY(QVariantMap state READ state NOTIFY stateChanged)
    Q_PROPERTY(bool healthy READ healthy NOTIFY stateChanged)
    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QVariantMap theme READ theme NOTIFY themeChanged)
    Q_PROPERTY(QString clock READ clock NOTIFY clockChanged)
    Q_PROPERTY(QString datestr READ datestr NOTIFY clockChanged)

public:
    explicit Backend(const QString &path, QObject *parent = nullptr)
        : QObject(parent), m_path(path)
    {
        auto *t = new QTimer(this);
        t->setInterval(500);
        connect(t, &QTimer::timeout, this, &Backend::reload);
        t->start();

        // Second-granularity clock, owned here so QML does not spin its own
        // timer for text that only changes once a second.
        auto *ct = new QTimer(this);
        ct->setInterval(1000);
        connect(ct, &QTimer::timeout, this, &Backend::tickClock);
        ct->start();

        reload();
        tickClock();
    }

    QVariantMap state() const { return m_state; }
    bool healthy() const { return m_healthy; }
    QString status() const { return m_status; }
    QString clock() const { return m_clock; }
    QString datestr() const { return m_datestr; }

    // Theme palette, parsed from the generated Theme.qml. Exposed as a map so
    // main.qml can alias it into every child component -- QML ids do not cross
    // file boundaries, and a singleton would need qmldir/CMake machinery.
    QVariantMap theme() const { return m_theme; }

signals:
    void stateChanged();
    void clockChanged();
    void themeChanged();

private slots:
    void tickClock()
    {
        const QDateTime now = QDateTime::currentDateTime();
        const QString c = now.toString("h:mm:ss AP");
        const QString d = now.toString("dddd, MMMM d, yyyy");
        if (c != m_clock || d != m_datestr) {
            m_clock = c;
            m_datestr = d;
            emit clockChanged();
        }
    }

    void reload()
    {
        // Cheap guard: every tick re-reads a file whose mtime only moves once a
        // second from the collector. Skip the parse when nothing has been
        // written. This is most of the renderer's idle CPU on a static panel.
        QFileInfo fi(m_path);
        if (!fi.exists()) {
            if (m_healthy) { m_healthy = false; m_status = "collector: no state file"; emit stateChanged(); }
            return;
        }
        const qint64 mt = fi.lastModified().toMSecsSinceEpoch();
        if (mt == m_lastMtimeMs && m_healthy) {
            return;
        }

        QFile f(m_path);
        if (!f.open(QIODevice::ReadOnly)) {
            if (m_healthy) { m_healthy = false; m_status = "collector: unreadable"; emit stateChanged(); }
            return;
        }
        const QByteArray raw = f.readAll();
        f.close();
        m_lastMtimeMs = mt;

        QJsonParseError err{};
        const QJsonDocument doc = QJsonDocument::fromJson(raw, &err);
        if (err.error != QJsonParseError::NoError || !doc.isObject()) {
            if (m_healthy) { m_healthy = false; m_status = "collector: bad JSON"; emit stateChanged(); }
            return;
        }

        const QVariantMap fresh = doc.object().toVariantMap();
        // Only emit when something actually changed: a 500ms repaint of the
        // whole tree is wasted GPU work on a gaming box.
        if (fresh != m_state) {
            m_state = fresh;
            if (!m_healthy) m_status = "";
            m_healthy = true;
            emit stateChanged();
        }
    }

public:
    // Called by main() after the engine exists: watch the theme file too.
    void watchFile(QFileSystemWatcher *w)
    {
        connect(w, &QFileSystemWatcher::fileChanged, this, [this, w](const QString &p) {
            loadTheme(p);
            // Watchers drop the path when the file is replaced by rename, which
            // is exactly how matugen writes it. Re-add.
            if (!w->files().contains(p) && QFile::exists(p)) w->addPath(p);
        });
    }

    // Parse the generated Theme.qml without loading it as QML. Its contract is
    // one `readonly property color NAME: "#rrggbb"` per line, which is simpler
    // and far less fragile than an engine round-trip on every recolour.
    void loadTheme(const QString &path)
    {
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly)) {
            qWarning() << "casedash: cannot read theme" << path << "-- using fallback";
            return;
        }
        const QString text = QString::fromUtf8(f.readAll());
        f.close();

        QVariantMap next;
        for (const QString &line : text.split('\n')) {
            const QString s = line.trimmed();
            if (!s.startsWith("readonly property color")) continue;
            const int nameStart = s.indexOf("color") + 5;
            const int colon = s.indexOf(':', nameStart);
            if (colon < 0 || nameStart < 5) continue;
            const QString name = s.mid(nameStart, colon - nameStart).trimmed();
            QString val = s.mid(colon + 1).trimmed();
            val.remove(';');
            val.remove('"');
            if (!name.isEmpty() && val.startsWith('#')) next[name] = val;
        }
        if (next.isEmpty()) {
            qWarning() << "casedash: no colours parsed from" << path;
            return;
        }
        if (next != m_theme) {
            m_theme = next;
            qInfo() << "casedash: theme loaded," << m_theme.size() << "colours, accent"
                    << m_theme.value("accent").toString();
            emit themeChanged();
        }
    }

private:
    QString m_path;
    QVariantMap m_state;
    QVariantMap m_theme;
    bool m_healthy = false;
    qint64 m_lastMtimeMs = 0;
    QString m_status = "collector: starting";
    QString m_clock;
    QString m_datestr;
};

// ---------------------------------------------------------------------------
int main(int argc, char *argv[])
{
    qInstallMessageHandler(casedashMessageHandler);
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName("casedash");
    QGuiApplication::setApplicationVersion("1.0");

    QCommandLineParser parser;
    parser.setApplicationDescription("Case-screen telemetry dashboard");
    parser.addHelpOption();
    QCommandLineOption screenOpt({"s", "screen"},
        "Output name to pin to (e.g. DP-1)", "name", "DP-1");
    QCommandLineOption stateOpt({"f", "state"},
        "Collector state JSON", "path",
        QString("/run/user/%1/casedash/state.json").arg(getuid()));
    QCommandLineOption themeOpt({"t", "theme"},
        "Generated Theme.qml to read colours from", "path",
        QString::fromUtf8(qgetenv("HOME")) + "/projects/casedash/renderer/qml/Theme.qml");
    parser.addOption(screenOpt);
    parser.addOption(stateOpt);
    parser.addOption(themeOpt);
    parser.addPositionalArgument("qml", "Path to the root QML file");
    parser.process(app);

    const QStringList args = parser.positionalArguments();
    if (args.isEmpty()) {
        qWarning() << "usage: casedash [-s DP-1] [-f state.json] <main.qml>";
        return 2;
    }
    const QString target = parser.value(screenOpt);

    // 1. The backend object must exist before the component is created.
    QQmlEngine engine;
    Backend backend(parser.value(stateOpt));
    QFileSystemWatcher watcher;
    const QString themePath = parser.value(themeOpt);
    backend.loadTheme(themePath);          // before QML binds to it
    if (QFile::exists(themePath)) {
        watcher.addPath(themePath);
    }
    backend.watchFile(&watcher);
    engine.rootContext()->setContextProperty("Backend", &backend);

    // NOTE: layout/type metrics live in the QML singleton `Ui` (see qmldir +
    // Ui.qml), NOT in a context property. A context property is not visible
    // inside imported component files -- Card.qml/KeyValue.qml could not see it
    // and every binding silently evaluated to undefined. The singleton is the
    // only form that works across file boundaries without build machinery.
    // Edit Ui.qml's `scale` to resize the whole panel.

    // Let QML construct plain QObjects (Date formatting helpers etc.)
    engine.rootContext()->setContextProperty("appDir",
        QFileInfo(args.first()).absolutePath());

    // 2. Build the object tree.
    const QUrl url = QUrl::fromLocalFile(args.first());
    QQmlComponent component(&engine, url);
    if (component.isError()) {
        qWarning() << "QML load failed:" << component.errorString();
        return 1;
    }
    QObject *obj = component.create();
    if (!obj) {
        qWarning() << "QML create failed:" << component.errorString();
        return 1;
    }

    auto *win = qobject_cast<QQuickWindow *>(obj);
    if (!win) {
        qWarning() << "root QML object is not a Window; got"
                   << obj->metaObject()->className();
        return 1;
    }

    // 3. Configure the layer-shell surface BEFORE show().
    //
    //    CRITICAL ORDERING: a QML `Window` with visible:true creates its own
    //    xdg toplevel during component creation, and LayerShellQt then refuses
    //    to attach ("already has a shell integration"), leaving the window on
    //    the primary output. The QML root therefore declares visible:false;
    //    here we hide it defensively, attach layer-shell, THEN show. That is
    //    what makes output pinning actually take effect.
    win->setVisible(false);

    if (auto *ls = LayerShellQt::Window::get(win)) {
        bool matched = false;
        for (QScreen *s : QGuiApplication::screens()) {
            if (s->name() == target) {
                // The ONLY way to pin output on Wayland -- but the API moved
                // twice. build.sh feature-tests the installed headers and
                // defines exactly one of these (see its comment for the version
                // table); there is no version macro to test against here.
#if defined(CASEDASH_LS_SETSCREEN)
                ls->setScreen(s);
                const char *how = "setScreen()";
#elif defined(CASEDASH_LS_SCREENCONFIG)
                // The 6.0-6.6 shim reads QWindow::screen() at attach time, so
                // set that too. Harmless here: the layer surface does not exist
                // yet.
                win->setScreen(s);
                // Deprecated as of 6.6 -- the replacement is setScreen(), which
                // this branch exists precisely because we do not have.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
                ls->setScreenConfiguration(LayerShellQt::Window::ScreenFromQWindow);
#pragma GCC diagnostic pop
                const char *how = "setScreenConfiguration() shim";
#elif defined(CASEDASH_LS_DESIREDOUTPUT)
                // Plasma 5 API: the closest match to what we actually want,
                // since it takes the output directly.
                ls->setDesiredOutput(s);
                const char *how = "setDesiredOutput()";
#else
#error "no layer-shell-qt output-pinning API -- build.sh should have caught this"
#endif
                matched = true;
                qInfo() << "casedash: pinned to" << s->name() << s->geometry()
                        << "via" << how;
                break;
            }
        }
        if (!matched) {
            qWarning() << "casedash: output" << target << "not found;"
                       << "available:";
            for (QScreen *s : QGuiApplication::screens())
                qWarning() << "   " << s->name() << s->geometry();
            return 4;
        }

        ls->setAnchors(LayerShellQt::Window::Anchors(
            LayerShellQt::Window::AnchorTop | LayerShellQt::Window::AnchorBottom
            | LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight));
        ls->setLayer(LayerShellQt::Window::LayerBackground);
        ls->setKeyboardInteractivity(
            LayerShellQt::Window::KeyboardInteractivityNone);
        ls->setScope(QStringLiteral("casedash"));
        // -1 == do not reserve exclusive space; we want to sit UNDER windows.
        ls->setExclusiveZone(-1);
        // Never steal focus from a game. Independent of the pinning API above --
        // absent before layer-shell-qt 6.7. Defaults are already harmless for
        // our layer+interactivity combination, so skipping it is safe.
#if defined(CASEDASH_LS_SETSCREEN)
        ls->setActivateOnShow(false);
#endif
    } else {
        qWarning() << "casedash: LayerShellQt unavailable, running as a normal window";
    }

    win->show();

    // 4. Size to the pinned output, whose geometry already has the 90 degree
    //    rotation applied (so it is 1100x3840, not the raw panel mode).
    if (QScreen *sc = win->screen())
        win->setGeometry(sc->geometry());

    qInfo() << "casedash: up on" << win->screen()->name()
            << win->geometry() << win->size();

    // Surface a fatal error rather than sitting there as a black rectangle.
    if (!win->isVisible()) {
        qWarning() << "casedash: window never became visible";
        return 3;
    }

    return app.exec();
}

#include "host.moc"
