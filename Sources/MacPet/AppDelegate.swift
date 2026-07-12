import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(service: LocalNetworkPetInteractionService())
    private var panelController: PetPanelController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PetPanelController { [weak self] frameName in
            Task { await self?.model.sendInteraction(kind: .poke, frameName: frameName) }
        } onSendAction: { [weak self] kind in
            Task { await self?.model.sendInteraction(kind: kind) }
        } onHide: { [weak self] in
            self?.panelController.hide()
        } onQuit: {
            NSApplication.shared.terminate(nil)
        }
        model.onStateChange = { [weak self] in self?.renderPet() }
        renderPet()
        panelController.show()
        model.startListening()
        configureMenuBar()
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "MacPet")
        let menu = NSMenu()
        menu.addItem(withTitle: "我的宠物", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let networkItem = NSMenuItem(title: "局域网模式：正在自动发现伙伴", action: nil, keyEquivalent: "")
        networkItem.isEnabled = false
        menu.addItem(networkItem)
        menu.addItem(withTitle: "拍一拍朋友", action: #selector(pokeFriend), keyEquivalent: "p")
        menu.addItem(withTitle: "显示宠物", action: #selector(showPet), keyEquivalent: "")
        menu.addItem(withTitle: "隐藏宠物", action: #selector(hidePet), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 MacPet", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func renderPet() {
        panelController.render(text: model.bubbleText, emotion: model.emotion, frameName: model.activeFrameName)
    }

    @objc private func pokeFriend() { Task { await model.sendInteraction(kind: .poke) } }
    @objc private func showPet() { panelController.show() }
    @objc private func hidePet() { panelController.hide() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
