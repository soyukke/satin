extension RustCore {
    @discardableResult
    func applyThemePreference(_ theme: String) -> Bool {
        setDefaultTheme(theme)
        guard let activeTab = snapshot()?.active_tab else {
            return false
        }
        setTheme(theme, tab: activeTab)
        return true
    }

    static func runSelfTests() -> Bool {
        guard let core = RustCore(defaultTheme: "Graphite") else {
            return false
        }
        core.setTheme("Rose", tab: 0)
        core.newTab()
        guard core.applyThemePreference("Harbor"), let updated = core.snapshot() else {
            return false
        }
        core.newTab()
        guard let withNewTab = core.snapshot() else {
            return false
        }
        return updated.tabs.map(\.theme) == ["Rose", "Harbor"]
            && withNewTab.tabs.last?.theme == "Harbor"
    }
}
