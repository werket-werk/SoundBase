import SwiftUI
import WidgetKit

private struct NowPlayingEntry: TimelineEntry {
    let date: Date
}

private struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

private struct NowPlayingComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("SoundBase", systemImage: "waveform")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label("SoundBase", systemImage: "waveform")
                        .font(.headline)
                    Text("Now Playing")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryCorner:
                symbol
                    .widgetLabel { Text("SoundBase") }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    symbol
                }
            }
        }
        .widgetURL(URL(string: "soundbase-watch://now-playing"))
        .containerBackground(for: .widget) { Color.clear }
    }

    private var symbol: some View {
        Image(systemName: "waveform")
            .font(.title3)
            .accessibilityLabel("SoundBase Now Playing")
    }
}

@main
struct SoundBaseComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SoundBaseNowPlaying", provider: NowPlayingProvider()) { _ in
            NowPlayingComplicationView()
        }
        .configurationDisplayName("SoundBase")
        .description("Open Now Playing on your Apple Watch.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
