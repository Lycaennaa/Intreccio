import AppKit

@MainActor
final class OpenApplicationMenuRenderer {
    final class ApplicationTarget: NSObject {
        let applicationURLs: [URL]

        init(applicationURLs: [URL]) {
            self.applicationURLs = applicationURLs
        }
    }

    struct MenuApplication {
        let applicationURL: URL
        let title: String
        let representedObject: Any
    }
    struct RemovalApplication {
        let applicationURL: URL
        let title: String
    }

    struct MenuActions {
        let open: Selector
        let choose: Selector
        let removeSelected: Selector
        let remove: Selector
    }

    enum MenuModel {
        case unavailable(title: String, message: String)
        case available(
            title: String,
            applications: [MenuApplication],
            removalApplications: [RemovalApplication],
            chooseRepresentedObject: Any
        )
    }

    static func addMenu(
        _ model: MenuModel,
        to menu: NSMenu,
        target: AnyObject,
        actions: MenuActions
    ) {
        let title: String
        let submenu: NSMenu
        switch model {
        case .unavailable(let unavailableTitle, let message):
            title = unavailableTitle
            submenu = NSMenu(title: title)
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        case .available(let availableTitle, let applications, let removalApplications, let chooseRepresentedObject):
            title = availableTitle
            submenu = NSMenu(title: title)
            for application in applications {
                let item = NSMenuItem(
                    title: application.title,
                    action: actions.open,
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = application.representedObject
                submenu.addItem(item)
            }
            if !applications.isEmpty {
                submenu.addItem(.separator())
            }

            let chooseItem = NSMenuItem(
                title: "Choose Application…",
                action: actions.choose,
                keyEquivalent: ""
            )
            chooseItem.target = target
            chooseItem.representedObject = chooseRepresentedObject
            submenu.addItem(chooseItem)

            if !removalApplications.isEmpty {
                addRemovalItems(
                    applications: removalApplications,
                    to: submenu,
                    target: target,
                    actions: actions
                )
            }
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private static func addRemovalItems(
        applications: [RemovalApplication],
        to menu: NSMenu,
        target: AnyObject,
        actions: MenuActions
    ) {
        menu.addItem(.separator())
        let targetURLs = ApplicationTarget(applicationURLs: applications.map(\.applicationURL))

        let removeSelectedItem = NSMenuItem(
            title: "Remove Selected…",
            action: actions.removeSelected,
            keyEquivalent: ""
        )
        removeSelectedItem.target = target
        removeSelectedItem.representedObject = targetURLs
        menu.addItem(removeSelectedItem)

        let removeAllItem = NSMenuItem(
            title: "Remove All from List",
            action: actions.remove,
            keyEquivalent: ""
        )
        removeAllItem.target = target
        removeAllItem.representedObject = targetURLs
        menu.addItem(removeAllItem)

        let removalMenu = NSMenu(title: "Remove from List")
        for application in applications {
            let item = NSMenuItem(
                title: application.title,
                action: actions.remove,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = ApplicationTarget(applicationURLs: [application.applicationURL])
            removalMenu.addItem(item)
        }
        let removalItem = NSMenuItem(title: "Remove from List", action: nil, keyEquivalent: "")
        removalItem.submenu = removalMenu
        menu.addItem(removalItem)
    }
}