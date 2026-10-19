import Foundation

do {
    switch CommandLine.arguments.dropFirst().first {
    case "install":
        try ServiceInstaller.install()
    case "uninstall":
        try ServiceInstaller.uninstall()
    case "status":
        try MouseMonitor().printStatus()
    case nil:
        try MouseMonitor().run()
    default:
        fputs(
            """
            用法:
              mouseDetect           监听鼠标插拔，并切换「自然滚动」
              mouseDetect status    查看当前外接鼠标和自然滚动状态
              mouseDetect install   安装为登录后常驻的后台服务
              mouseDetect uninstall 移除后台服务

            """,
            stderr
        )
        exit(2)
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
