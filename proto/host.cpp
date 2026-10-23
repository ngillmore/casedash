// Minimal Qt6 QML host for the case-screen dashboard.
//
// qmlscene refuses to instantiate Window types ("Type cannot be created in
// QML"), so a real C++ host is required -- which is the production path anyway.
//
// The LayerShellQt QML attached property did not take effect here, so the
// layer-shell surface is configured directly through the C++ API
// (LayerShellQt::Window::get(QWindow*)). This is what gives the dashboard
// EXPLICIT OUTPUT SELECTION -- the capability Conky lacks (upstream #2106) and
// the reason it repeatedly lands on the wrong monitor.
#include <QGuiApplication>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQuickWindow>
#include <QCommandLineParser>
#include <QScreen>
#include <QDebug>
#include <QUrl>

#include <LayerShellQt/Window>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName("casedash");

    QCommandLineParser parser;
    parser.addHelpOption();
    QCommandLineOption screenOpt({"s", "screen"},
        "Output name to pin to (e.g. DP-1)", "name", "DP-1");
    parser.addOption(screenOpt);
    parser.addPositionalArgument("qml", "Path to the root QML file");
    parser.process(app);

    const QStringList args = parser.positionalArguments();
    if (args.isEmpty()) {
        qWarning() << "usage: casedash [-s DP-1] <main.qml>";
        return 2;
    }
    const QString targetScreenName = parser.value(screenOpt);
    const QUrl url = QUrl::fromLocalFile(args.first());

    // 1. Build the QML object tree from the component.
    QQmlEngine engine;
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

    // 2. Configure the layer-shell surface BEFORE the window is shown.
    if (auto *ls = LayerShellQt::Window::get(win)) {
        ls->setAnchors(LayerShellQt::Window::Anchors(
            LayerShellQt::Window::AnchorTop | LayerShellQt::Window::AnchorBottom
            | LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight));
        ls->setLayer(LayerShellQt::Window::LayerBackground);
        ls->setKeyboardInteractivity(
            LayerShellQt::Window::KeyboardInteractivityNone);
        ls->setScope(QStringLiteral("casedash"));
        ls->setExclusiveZone(-1);        // don't reserve space
        ls->setActivateOnShow(false);    // background panel: never steal focus

        // 3. Explicit output selection.
        bool matched = false;
        const auto screens = QGuiApplication::screens();
        for (QScreen *s : screens) {
            if (s->name() == targetScreenName) {
                ls->setScreen(s);
                win->setScreen(s);
                matched = true;
                qInfo() << "casedash: pinned to output" << s->name()
                        << s->geometry();
                break;
            }
        }
        if (!matched) {
            qWarning() << "casedash: output" << targetScreenName
                       << "not found; using" << win->screen()->name();
        }
    } else {
        qWarning() << "casedash: LayerShellQt unavailable, running as a normal window";
    }

    win->show();

    // 4. Size to the target output's logical geometry (already rotation-applied).
    if (QScreen *sc = win->screen()) {
        win->setGeometry(sc->geometry());
        qInfo() << "casedash: window geometry" << win->geometry();
    }

    return app.exec();
}
