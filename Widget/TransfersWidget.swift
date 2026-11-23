import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TransfersWidgetBundle: WidgetBundle {
    var body: some Widget {
        TransfersLiveActivity()
    }
}

struct TransfersLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            LockScreenTransfers(state: context.state, accent: accent(context.attributes))
                .padding(16)
                .widgetURL(URL(string: "seekios://downloads"))
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let tint = accent(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state.isIdleSeeding ? state.compactText : state.percentText)
                            .font(.title3.weight(.semibold).monospacedDigit())
                        if !state.speedText.isEmpty {
                            Text(state.speedText).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.currentFile.isEmpty {
                            Text(state.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if state.isIdleSeeding {
                            Text("Sharing your library on Soulseek").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView(value: state.clampedFraction).tint(tint)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(tint)
            } compactTrailing: {
                Text(state.compactText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
            } minimal: {
                if state.isIdleSeeding {
                    Image(systemName: state.symbol).foregroundStyle(tint)
                } else {
                    Gauge(value: state.clampedFraction) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(tint)
                }
            }
            .widgetURL(URL(string: "seekios://downloads"))
            .keylineTint(tint)
        }
    }

    private func accent(_ attributes: TransferActivityAttributes) -> Color {
        var text = attributes.accentHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return Color(red: 1, green: 0.176, blue: 0.333)
        }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

struct LockScreenTransfers: View {
    let state: TransferActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbol)
                .font(.largeTitle)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Seekios · " + state.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(state.compactText).font(.headline.monospacedDigit())
                }
                if !state.currentFile.isEmpty {
                    Text(state.currentFile)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                if !state.isIdleSeeding {
                    ProgressView(value: state.clampedFraction).tint(accent)
                }
                if !state.speedText.isEmpty {
                    Text(state.speedText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .foregroundStyle(.white)
    }
}
