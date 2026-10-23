import SwiftUI

/// The clipboard page: the last few things copied, as one-line previews.
///
/// The same interaction on both surfaces now that the panel takes clicks:
/// click a row and it is the clipboard again, hover it for the full text.
enum ClipboardDisplay {
    static let emptyText = "nothing copied yet \u{2014} the last "
        + "\(ClipboardStore.maxItems) text clipboards appear here"
    static let disabledText = "clipboard history is switched off in Settings"
    /// The privacy statement, one line, on the page it applies to. Short
    /// enough to clear the page dots; the full version is in Settings.
    static let footerText = "click to copy  \u{00B7}  text only  \u{00B7}  memory only"

    /// Tooltip body: the whole string, within reason. Tooltips are how a row
    /// answers "what is the rest of it" without a preview pane.
    static func tooltip(for item: ClipboardItem) -> String {
        item.text.count <= 1200 ? item.text : String(item.text.prefix(1200)) + "\u{2026}"
    }
}

// MARK: - Panel rows

struct ClipboardPageRows: View {
    let items: [ClipboardItem]
    let enabled: Bool
    let now: Date
    let active: Bool
    var onCopy: (ClipboardItem) -> Void

    @State private var copiedID: Int?

    var body: some View {
        VStack(spacing: NotchTheme.clipboardRowGap) {
            if !enabled || items.isEmpty {
                Text(enabled ? ClipboardDisplay.emptyText : ClipboardDisplay.disabledText)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.mutedText)
                    .frame(maxWidth: .infinity, minHeight: NotchTheme.sessionRowHeight)
                    .opacity(active ? 1 : 0)
                    .animation(PanelMotion.contentIn(after: active ? PanelMotion.brandLead : 0),
                               value: active)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, index: index)
            }
        }
    }

    private func row(_ item: ClipboardItem, index: Int) -> some View {
        Button {
            onCopy(item)
            copiedID = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedID == item.id { copiedID = nil }
            }
        } label: {
            HStack(spacing: 10) {
                // The newest entry is the one still on the clipboard; the marker
                // says "this is what paste gives you right now".
                Circle()
                    .fill(index == 0 ? NotchTheme.primaryText : Color.white.opacity(0.18))
                    .frame(width: 4, height: 4)

                Text(item.preview)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(index == 0 ? NotchTheme.primaryText : NotchTheme.unitText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 10)

                if copiedID == item.id {
                    Text("copied")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(NotchTheme.attention)
                        .fixedSize()
                } else if let age = Fmt.ago(item.copiedAt, now: now) {
                    Text(age)
                        .font(.system(size: 9.5))
                        .foregroundStyle(NotchTheme.mutedText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(height: NotchTheme.clipboardRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ClipboardDisplay.tooltip(for: item))
        .opacity(active ? 1 : 0)
        .offset(y: active ? 0 : -4)
        .animation(active ? PanelMotion.rowIn(index)
                          : PanelMotion.rowOut(index, of: items.count),
                   value: active)
    }
}

// MARK: - Popover section

/// Same list, but the rows are buttons: click one and it is the clipboard
/// again. The row flashes "copied" instead of reordering under the pointer —
/// the store moves it to the top, but the list stays put until reopen so the
/// thing just clicked cannot jump away from where it was clicked.
struct PopoverClipboardSection: View {
    let items: [ClipboardItem]
    let enabled: Bool
    let now: Date
    var onCopy: (ClipboardItem) -> Void

    @State private var copiedID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !enabled || items.isEmpty {
                Text(enabled ? ClipboardDisplay.emptyText : ClipboardDisplay.disabledText)
                    .font(.system(size: PopoverTheme.bodySize))
                    .foregroundStyle(PopoverTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(PopoverTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 9)
                }
                row(item).help(ClipboardDisplay.tooltip(for: item))
            }
            if !items.isEmpty {
                Text(ClipboardDisplay.footerText)
                    .font(.system(size: PopoverTheme.captionSize))
                    .foregroundStyle(PopoverTheme.mutedText)
                    .padding(.top, 10)
            }
        }
    }

    private func row(_ item: ClipboardItem) -> some View {
        Button {
            onCopy(item)
            copiedID = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedID == item.id { copiedID = nil }
            }
        } label: {
            HStack(spacing: 8) {
                Text(item.preview)
                    .font(.system(size: PopoverTheme.bodySize, design: .monospaced))
                    .foregroundStyle(PopoverTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if copiedID == item.id {
                    Text("copied")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchTheme.attention)
                        .fixedSize()
                } else if let age = Fmt.ago(item.copiedAt, now: now) {
                    Text(age)
                        .font(.system(size: 9))
                        .foregroundStyle(PopoverTheme.mutedText)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy again")
    }
}
