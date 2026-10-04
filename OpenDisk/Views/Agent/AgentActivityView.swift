import SwiftUI

@MainActor
@Observable
final class AgentActivity {
    var events: [AgentEvent] = []
    /// Everything the AI has proposed so far; updated while it's still working.
    var aiSuggestions: [Suggestion] = []
}

/// Step-by-step log of what the agent is doing; each step expands to show the raw
/// arguments, tool results and model text.
struct ActivityLogView: View {
    let activity: AgentActivity

    var body: some View {
        ScrollViewReader { proxy in
            List(activity.events) { event in
                ActivityRow(event: event).id(event.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: activity.events.count) {
                if let last = activity.events.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActivityRow: View {
    let event: AgentEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
                Text(event.text).lineLimit(expanded ? nil : 1).truncationMode(.middle)
                Spacer()
                Text(event.date.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                if event.detail != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            if expanded, let detail = event.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if event.detail != nil { withAnimation(.snappy) { expanded.toggle() } } }
    }

    private var icon: String {
        switch event.kind {
        case .status: "info.circle"
        case .request: "arrow.up.circle"
        case .model: "text.bubble"
        case .tool: "wrench.and.screwdriver"
        case .done: "checkmark.circle"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .model: .purple
        case .tool: .blue
        case .done: .green
        default: .secondary
        }
    }
}
