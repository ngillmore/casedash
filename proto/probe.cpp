#include <QGuiApplication>
#include <QScreen>
#include <cstdio>
int main(int argc, char**argv){
    QGuiApplication a(argc,argv);
    auto screens = QGuiApplication::screens();
    printf("screen count: %d\n", (int)screens.size());
    for (auto *s : screens) {
        auto g = s->geometry();
        printf("SCREEN: %s geom=%dx%d+%d+%d dpr=%.2f\n",
               qPrintable(s->name()), g.width(), g.height(), g.x(), g.y(),
               s->devicePixelRatio());
    }
    fflush(stdout);
    return 0;
}
