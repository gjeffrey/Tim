import SwiftUI
import WebKit
import TimKit

typealias Tab = TimKit.Tab

@main
struct TimPadApp: App {
    @StateObject private var siteStore = SiteStore()
    @StateObject private var tab = Tab()

    var body: some Scene {
        WindowGroup {
            PadBrowser(tab: tab)
                .environmentObject(siteStore)
        }
    }
}

/// The browser, iPad-shaped: the same Tab, the same canvas engine, the
/// same editability rules as the Mac — with touch doing the dragging.
struct PadBrowser: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var siteStore: SiteStore

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    @State private var showPublishNote = false

    private var pageURL: URL? { URL(string: tab.urlString) }

    private var matchedSite: Site? {
        if let site = siteStore.match(pageURL) { return site }
        guard tab.isTimPage || tab.lastHTTPStatus == 404, let url = pageURL else { return nil }
        return siteStore.derivedSite(for: url)
    }

    private var isPageEditable: Bool {
        siteStore.isEditable(pageURL, timAuthored: tab.isTimPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            PadWebView(webView: tab.webView)
                .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            addressText = tab.urlString
            if tab.urlString.isEmpty {
                if let first = siteStore.sites.first {
                    tab.navigate(to: first.origin)
                } else {
                    tab.navigate(to: "https://gabrieljeffrey.com/tim/")
                }
            }
        }
        .onChange(of: tab.urlString) { _, value in
            if !addressFocused { addressText = value }
        }
        .alert("Publishing from iPad is next", isPresented: $showPublishNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The canvas is fully editable here, but Done needs the SSH engine that's still Mac-only. Edits preview live and aren't saved yet — the same page on your Mac publishes as always.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                tab.webView.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!tab.canGoBack)

            Button {
                tab.webView.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!tab.canGoForward)

            addressCapsule

            if tab.isEditing {
                Button {
                    tab.undoEdit()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                Button {
                    tab.redoEdit()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                Button("Done") {
                    tab.setEditing(false)
                    showPublishNote = true
                }
                .buttonStyle(.borderedProminent)
            } else if isPageEditable {
                Button("Edit") {
                    tab.setEditing(true)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var prettyAddress: (host: String, path: String)? {
        guard !addressFocused, !tab.isEditing,
              let url = URL(string: tab.urlString),
              let host = url.host()
        else { return nil }
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = url.path
        if path == "/" || path.isEmpty { path = "" }
        return (clean, path)
    }

    private var addressCapsule: some View {
        HStack(spacing: 7) {
            Image(systemName: isPageEditable ? "pencil.circle.fill" : "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPageEditable ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            ZStack {
                TextField("Search or enter address", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(addressFocused ? .leading : .center)
                    .foregroundStyle(prettyAddress == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                    .focused($addressFocused)
                    .onSubmit {
                        tab.navigate(to: addressText)
                        addressFocused = false
                    }
                if let pretty = prettyAddress {
                    HStack(spacing: 0) {
                        Text(pretty.host)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(pretty.path)
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            Button {
                if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 38)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(addressFocused ? 0.09 : 0.055)))
        .overlay(
            Capsule(style: .continuous)
                .stroke(isPageEditable ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: isPageEditable ? Color.accentColor.opacity(0.28) : .clear, radius: 7, y: 1)
        .animation(.easeOut(duration: 0.22), value: isPageEditable)
    }
}

struct PadWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
