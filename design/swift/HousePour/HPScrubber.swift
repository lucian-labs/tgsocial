// House Pour kit — playback primitives (PRODUCT.md §2.11 "Player rules").
// HPScrubber: 1pt line2 hairline, gold played segment, 12pt panel knob with the contact shadow.
// HPProgressRing: the determinate gold download ring over placeholders; tapping cancels.
// HPWaveform: voice-note bars from TDLib waveform samples, ink with gold played.
// HPPlayGlyph / HPPlayButton: the 40pt play/pause circle in the stepper style.
// No system transport controls anywhere.

import SwiftUI

public struct HPScrubber: View {
    let progress: Double
    let knob: Bool
    let onSeek: ((Double) -> Void)?
    @State private var dragging: Double?

    /// `progress` 0…1. `onSeek` receives the fraction on drag end; nil makes the bar display-only.
    public init(progress: Double, knob: Bool = true, onSeek: ((Double) -> Void)? = nil) {
        self.progress = progress; self.knob = knob; self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let p = min(max(dragging ?? progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(HPTokens.Colors.line2)
                    .frame(height: HPTokens.borderWidth)
                Capsule(style: .continuous)
                    .fill(HPTokens.Colors.accent)
                    .frame(width: width * p, height: HPTokens.borderWidth)
                if knob {
                    Circle()
                        .fill(HPTokens.Colors.panel)
                        .overlay(Circle().strokeBorder(HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth))
                        .frame(width: HPMetric.scrubberKnob, height: HPMetric.scrubberKnob)
                        .hpShadow(HPTokens.Shadow.contact, shape: Circle(), fill: HPTokens.Colors.panel)
                        .offset(x: min(max(width * p - HPMetric.scrubberKnob / 2, 0), width - HPMetric.scrubberKnob))
                }
            }
            .frame(height: HPTokens.Space.touchMin)
            .contentShape(Rectangle())
            .gesture(
                onSeek == nil ? nil :
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragging = min(max(v.location.x / width, 0), 1) }
                    .onEnded { v in
                        let f = min(max(v.location.x / width, 0), 1)
                        dragging = nil
                        onSeek?(f)
                    }
            )
        }
        .frame(height: HPTokens.Space.touchMin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(max(progress, 0), 1)) * 100)) percent")
    }
}

/// Determinate download progress: a hairline gold ring. The whole ring is a cancel target.
public struct HPProgressRing: View {
    let progress: Double
    let onCancel: (() -> Void)?

    public init(progress: Double, onCancel: (() -> Void)? = nil) {
        self.progress = progress; self.onCancel = onCancel
    }

    public var body: some View {
        Button { onCancel?() } label: {
            ZStack {
                Circle().fill(HPTokens.Colors.panel)
                Circle().strokeBorder(HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(HPTokens.Colors.accent, lineWidth: HPTokens.borderWidth)
                    .rotationEffect(.degrees(-90))
                    .padding(HPMetric.ringInset)
                Rectangle()
                    .fill(HPTokens.Colors.muted)
                    .frame(width: HPMetric.stopGlyph, height: HPMetric.stopGlyph)
            }
            .frame(width: HPTokens.Space.touchMin, height: HPTokens.Space.touchMin)
            .contentShape(Circle())
        }
        .buttonStyle(HPPressStyle())
        .disabled(onCancel == nil)
        .animation(HPMotion.color, value: progress)
        .accessibilityLabel("Downloading, \(Int(min(max(progress, 0), 1) * 100)) percent. Cancel")
    }
}

/// Voice-note waveform: ink bars, gold for the played fraction. Samples are 0…1.
public struct HPWaveform: View {
    let samples: [Double]
    let progress: Double
    let onSeek: ((Double) -> Void)?

    public init(samples: [Double], progress: Double, onSeek: ((Double) -> Void)? = nil) {
        self.samples = samples; self.progress = progress; self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            Canvas { context, size in
                let step = HPMetric.waveformBar + HPMetric.waveformGap
                let count = max(Int(size.width / step), 1)
                let played = Int(Double(count) * min(max(progress, 0), 1))
                for i in 0..<count {
                    let sample = samples.isEmpty ? HPMetric.waveformIdle
                        : samples[min(i * samples.count / count, samples.count - 1)]
                    let h = max(size.height * sample, HPMetric.waveformBar)
                    let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2,
                                      width: HPMetric.waveformBar, height: h)
                    let color = i < played ? HPTokens.Colors.accent : HPTokens.Colors.ink
                    context.fill(Path(roundedRect: rect, cornerRadius: HPMetric.waveformBar / 2), with: .color(color))
                }
            }
            .frame(height: HPMetric.waveformHeight)
            .frame(height: HPTokens.Space.touchMin)
            .contentShape(Rectangle())
            .gesture(
                onSeek == nil ? nil :
                DragGesture(minimumDistance: 0)
                    .onEnded { v in onSeek?(min(max(v.location.x / width, 0), 1)) }
            )
        }
        .frame(height: HPTokens.Space.touchMin)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice message progress")
    }
}

/// Play / pause glyphs drawn as shapes — no glyph font, no emoji.
public struct HPPlayGlyph: View {
    let playing: Bool
    let size: CGFloat
    let color: Color

    public init(playing: Bool, size: CGFloat = HPMetric.playGlyph, color: Color = HPTokens.Colors.ink) {
        self.playing = playing; self.size = size; self.color = color
    }

    public var body: some View {
        Group {
            if playing {
                HStack(spacing: size * 0.28) {
                    RoundedRectangle(cornerRadius: HPTokens.borderWidth, style: .continuous)
                        .fill(color).frame(width: size * 0.26, height: size)
                    RoundedRectangle(cornerRadius: HPTokens.borderWidth, style: .continuous)
                        .fill(color).frame(width: size * 0.26, height: size)
                }
            } else {
                HPTriangle().fill(color)
                    .frame(width: size * 0.9, height: size)
                    .offset(x: size * 0.08)
            }
        }
        .accessibilityHidden(true)
    }
}

public struct HPTriangle: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The 40pt play/pause circle (stepper style: panel fill, hairline ring).
/// `.loading(progress)` turns it into the cancel-able download ring.
public struct HPPlayButton: View {
    public enum PlayState: Equatable { case idle, playing, loading(Double) }
    let state: PlayState
    let label: String
    let action: () -> Void

    public init(state: PlayState, label: String, action: @escaping () -> Void) {
        self.state = state; self.label = label; self.action = action
    }

    public var body: some View {
        switch state {
        case .loading(let p):
            HPProgressRing(progress: p, onCancel: action)
        case .idle, .playing:
            Button(action: action) {
                ZStack {
                    Circle().fill(HPTokens.Colors.panel)
                    Circle().strokeBorder(HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth)
                    HPPlayGlyph(playing: state == .playing)
                }
                .frame(width: HPTokens.Space.touchMin, height: HPTokens.Space.touchMin)
                .contentShape(Circle())
            }
            .buttonStyle(HPPressStyle())
            .accessibilityLabel(label)
        }
    }
}
