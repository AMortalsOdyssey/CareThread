import SwiftUI

struct RootView: View {
    @AppStorage(DisplayMode.storageKey) private var storedMode = DisplayMode.standard.rawValue

    private var displayMode: DisplayMode {
        DisplayMode.launchOverride ?? DisplayMode(rawValue: storedMode) ?? .standard
    }

    var body: some View {
        Group {
            switch displayMode {
            case .standard:
                StandardRootTabView()
            case .elder:
                ElderRootTabView()
            }
        }
        .environment(\.displayMode, displayMode)
        .tint(CT.Color.primary)
    }
}

private struct StandardRootTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                PlaceholderPage(title: Copy.Tab.home, symbol: "house.fill")
            }
            .tabItem { Label(Copy.Tab.home, systemImage: "house") }

            NavigationStack {
                PlaceholderPage(title: Copy.Tab.timeline, symbol: "calendar.day.timeline.left")
            }
            .tabItem { Label(Copy.Tab.timeline, systemImage: "calendar.day.timeline.left") }

            NavigationStack {
                PlaceholderPage(title: Copy.Tab.capture, symbol: "plus")
            }
            .tabItem { Label(Copy.Tab.capture, systemImage: "plus.circle.fill") }

            NavigationStack {
                PlaceholderPage(title: Copy.Tab.records, symbol: "tray.full.fill")
            }
            .tabItem { Label(Copy.Tab.records, systemImage: "tray.full") }

            NavigationStack {
                PlaceholderPage(title: Copy.Tab.manage, symbol: "heart.text.square.fill")
            }
            .tabItem { Label(Copy.Tab.manage, systemImage: "heart.text.square") }
        }
        .accessibilityIdentifier("standardRoot")
    }
}

private struct ElderRootTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                PlaceholderPage(title: Copy.Elder.today, symbol: "sun.max.fill", elder: true)
            }
            .tabItem { Label(Copy.Elder.today, systemImage: "sun.max") }

            NavigationStack {
                PlaceholderPage(title: Copy.Elder.capture, symbol: "doc.viewfinder", elder: true)
            }
            .tabItem { Label(Copy.Elder.capture, systemImage: "doc.viewfinder") }

            NavigationStack {
                PlaceholderPage(title: Copy.Tab.records, symbol: "tray.full.fill", elder: true)
            }
            .tabItem { Label(Copy.Tab.records, systemImage: "tray.full") }
        }
        .accessibilityIdentifier("elderRoot")
    }
}

private struct PlaceholderPage: View {
    let title: String
    let symbol: String
    var elder = false

    var body: some View {
        VStack(spacing: CT.Space.s4) {
            Image(systemName: symbol)
                .font(.system(size: elder ? CT.Size.elderEmptySymbol : CT.Size.emptySymbol))
                .foregroundStyle(CT.Color.primary)
            Text(title)
                .font(elder ? CT.Font.elderTitle2 : CT.Font.title2)
                .foregroundStyle(CT.Color.inkPrimary)
            Text(Copy.disclaimer)
                .font(elder ? CT.Font.elderBody : CT.Font.footnote)
                .foregroundStyle(elder ? CT.Color.inkPrimary : CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(elder ? CT.Space.elderScreen : CT.Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CT.Color.bgBase)
        .navigationTitle(title)
    }
}

