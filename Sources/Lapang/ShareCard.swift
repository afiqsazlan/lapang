import SwiftUI

// The share card itself: always light, monotone zinc with one orange accent, like the app and its
// "Level" icon. Laid out per aspect ratio; ShareRenderer turns it into a PNG.

enum Zinc {
    static let z900 = Color(hex: 0x18181B), z700 = Color(hex: 0x3F3F46), z600 = Color(hex: 0x52525B)
    static let z500 = Color(hex: 0x71717A), z400 = Color(hex: 0xA1A1AA), z300 = Color(hex: 0xD4D4D8)
    static let z200 = Color(hex: 0xE4E4E7), z100 = Color(hex: 0xF4F4F5), z800 = Color(hex: 0x27272A)
    static let accent = Color(hex: 0xF59E0B), red = Color(hex: 0xEF4444)
    static let ramp = [z700, z600, z500, z400, z300, z200, z100]
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Sizes for one aspect ratio, in points of a 1x card.
struct CardMetrics {
    let ratio: ShareRatio
    var size: CGSize { ratio.size }
    var wide: Bool { ratio == .wide }
    var story: Bool { ratio == .story }
    var u: CGFloat { wide ? 1200 / 1080 : 1 }
    var padH: CGFloat { wide ? 56 : (story ? 80 : 72) }
    var padTop: CGFloat { wide ? 46 : (story ? 150 : 64) }
    var padBottom: CGFloat { wide ? 34 : (story ? 110 : 52) }
    var h1: CGFloat { wide ? 46 : (story ? 82 : 64) }
    var eyebrow: CGFloat { wide ? 22 : 22 }
    var row: CGFloat { wide ? 21 : (story ? 30 : 25) }
    var rowPad: CGFloat { wide ? 6 : (story ? 17 : 11) }
    var caption: CGFloat { wide ? 17 : 20 }
    var gap: CGFloat { wide ? 22 : (story ? 60 : 34) }
}

struct ShareCardView: View {
    let content: ShareContent
    let m: CardMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch content {
            case .now(let d): NowCard(d: d, m: m)
            case .today(let d): TodayCard(d: d, m: m)
            case .week(let d): WeekCard(d: d, m: m)
            case .clean(let d): CleanCard(d: d, m: m)
            }
            CardFooter(m: m)
        }
        .padding(.horizontal, m.padH)
        .padding(.top, m.padTop)
        .padding(.bottom, m.padBottom)
        .frame(width: m.size.width, height: m.size.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Zinc.z900)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Pieces

struct Eyebrow: View {
    let text: String
    let m: CardMetrics
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Zinc.accent).frame(width: 10, height: 10)
            Text(text).font(.system(size: m.eyebrow)).foregroundStyle(Zinc.z500)
        }
    }
}

struct Headline: View {
    let text: String
    var muted: String? = nil
    let m: CardMetrics
    var body: some View {
        (Text(text) + Text(muted.map { "\n" + $0 } ?? "").foregroundColor(Zinc.z400))
            .font(.system(size: m.h1, weight: .bold))
            .kerning(-m.h1 * 0.025)
            .lineSpacing(-m.h1 * 0.08)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, m.wide ? 12 : 18)
    }
}

struct Receipt: View {
    let rows: [ReceiptRow]
    let m: CardMetrics
    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(r.label).foregroundStyle(Zinc.z700).lineLimit(1).layoutPriority(1)
                    DottedLeader().frame(height: 2).offset(y: -5)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(r.value).fontWeight(.semibold).foregroundStyle(r.accent ? Zinc.accent : Zinc.z900)
                        if let n = r.note, !n.isEmpty {
                            Text(n).font(.system(size: m.row * 0.85, design: .monospaced)).foregroundStyle(Zinc.z400)
                        }
                    }
                    .font(.system(size: m.row, design: .monospaced))
                    .lineLimit(1).layoutPriority(2)
                }
                .font(.system(size: m.row))
                .padding(.vertical, m.rowPad)
                .overlay(alignment: .bottom) { Rectangle().fill(Zinc.z100).frame(height: 1) }
            }
        }
    }
}

struct DottedLeader: View {
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: g.size.width, y: 1)) }
                .stroke(Zinc.z300, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 5]))
        }
    }
}

struct CardCaption: View {
    let left: String
    let strong: String?
    let right: String
    let m: CardMetrics
    var body: some View {
        HStack {
            Text(left)
            Spacer()
            (Text(strong ?? "").fontWeight(.semibold).foregroundColor(Zinc.z900) + Text(right))
        }
        .font(.system(size: m.caption)).foregroundStyle(Zinc.z500)
        .padding(.bottom, 10)
    }
}

/// One bar per bucket of minutes: grey when normal, orange under pressure, red when critical.
struct CardPressureStrip: View {
    let bars: [Int]
    var body: some View {
        GeometryReader { g in
            let n = max(bars.count, 1)
            let step = g.size.width / CGFloat(n)
            let w = max(1, step * 0.72)
            ZStack(alignment: .topLeading) {
                ForEach(Array(bars.enumerated()), id: \.offset) { i, p in
                    RoundedRectangle(cornerRadius: min(2, w / 2))
                        .fill(p >= 4 ? Zinc.red : (p >= 2 ? Zinc.accent : Zinc.z300))
                        .frame(width: w, height: g.size.height)
                        .offset(x: CGFloat(i) * step)
                }
            }
        }
    }
}

struct CardFooter: View {
    let m: CardMetrics
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Zinc.z200).frame(height: 1)
            HStack(spacing: 12) {
                LevelIcon().frame(width: m.wide ? 32 : 40, height: m.wide ? 32 : 40)
                Text("Lapang").fontWeight(.semibold)
                Text("· menu bar app for dev Macs").foregroundStyle(Zinc.z400)
                Spacer()
                Text("github.com/afiqsazlan/lapang").font(.system(size: m.wide ? 18 : 21, design: .monospaced))
                    .foregroundStyle(Zinc.z500)
            }
            .font(.system(size: m.wide ? 18 : 21))
            .padding(.top, m.wide ? 16 : 24)
        }
        .padding(.top, m.wide ? 20 : 34)
    }
}

/// The app icon ("Level"), drawn so it stays sharp at any size.
struct LevelIcon: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous).fill(Zinc.z800)
                LevelGauge(fill: 0.42, line: 0.70, outline: Zinc.z400, fillColor: Zinc.z500, background: Zinc.z800,
                           lineWidth: s * 0.04, chevron: true)
                    .frame(width: s * 0.5, height: s * 0.54)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A container filled to `fill` (0…1) with an orange dashed line at `line`: the icon's motif.
struct LevelGauge: View {
    let fill: Double
    let line: Double?
    var outline = Zinc.z400
    var fillColor = Zinc.z400
    var background = Color.white
    var lineWidth: CGFloat = 7
    var chevron = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let inset = lineWidth * 1.5
            let innerH = h - inset * 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.16).fill(background)
                RoundedRectangle(cornerRadius: w * 0.16).strokeBorder(outline, lineWidth: lineWidth)
                RoundedRectangle(cornerRadius: w * 0.09)
                    .fill(fillColor)
                    .frame(width: w - inset * 2, height: max(0, innerH * min(1, fill)))
                    .offset(x: inset, y: inset + innerH * (1 - min(1, fill)))
                if let line {
                    let y = inset + innerH * (1 - min(1, line))
                    Path { p in p.move(to: CGPoint(x: inset * 1.2, y: y)); p.addLine(to: CGPoint(x: w - inset * 1.2, y: y)) }
                        .stroke(Zinc.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [lineWidth * 1.6, lineWidth * 1.3]))
                }
                if chevron {
                    let y = inset + innerH * 0.40
                    Path { p in
                        p.move(to: CGPoint(x: w * 0.38, y: y + w * 0.08))
                        p.addLine(to: CGPoint(x: w * 0.5, y: y - w * 0.03))
                        p.addLine(to: CGPoint(x: w * 0.62, y: y + w * 0.08))
                    }
                    .stroke(Zinc.z200, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var accent = false
    let m: CardMetrics
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: m.wide ? 32 : (m.story ? 48 : 40), weight: .bold, design: .monospaced))
                .foregroundStyle(accent ? Zinc.accent : Zinc.z900).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: m.wide ? 16 : 19)).foregroundStyle(Zinc.z500).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, m.wide ? 16 : 20).padding(.vertical, m.wide ? 12 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Zinc.z200, lineWidth: 1))
    }
}

func cardDate(_ d: Date) -> String { d.formatted(.dateTime.weekday(.wide).day().month(.wide)) }

// MARK: - Right now

struct NowCard: View {
    let d: ShareContent.Now
    let m: CardMetrics

    var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Right now, on my \(Int(d.ramGB.rounded())) GB Mac", m: m)
            Headline(text: "\(Int(d.appsGB.rounded())) GB of apps", muted: "on \(Int(d.ramGB.rounded())) GB of RAM.", m: m)
        }
    }

    var bar: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardCaption(left: "Memory by app · \(gbText(d.appsGB)) footprint", strong: nil, right: "", m: m)
            AppBar(apps: d.apps, total: max(d.appsGB, d.ramGB * 1.02), ram: d.ramGB)
                .frame(height: m.wide ? 64 : (m.story ? 120 : 90))
                .padding(.top, 24)
            Legend(apps: d.apps, m: m).padding(.top, 14)
        }
    }

    var tiles: [StatTile] {
        var t = [StatTile(value: gbText(d.peakSwapGB), label: "peak swap today", accent: true, m: m)]
        if let p = d.pressuredShare { t.append(StatTile(value: "\(Int((p * 100).rounded()))%", label: "of the time under pressure", m: m)) }
        if d.simProcesses > 0 { t.append(StatTile(value: "\(d.simProcesses)", label: "simulator processes", m: m)) }
        return t
    }

    var body: some View {
        if m.wide {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 0) { head; Spacer(minLength: 16); bar }
                    .frame(maxWidth: .infinity)
                VStack(spacing: 16) { Spacer(minLength: 0); ForEach(Array(tiles.enumerated()), id: \.offset) { $0.element }; Spacer(minLength: 0) }
                    .frame(width: 340)
            }
            .frame(maxHeight: .infinity)
        } else {
            head
            VStack(alignment: .leading, spacing: m.gap) {
                bar
                VStack(alignment: .leading, spacing: 0) {
                    CardCaption(left: "Swap today", strong: nil, right: "", m: m)
                    SwapChart(points: d.swap)
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 18) { ForEach(Array(tiles.enumerated()), id: \.offset) { $0.element } }
            }
            .padding(.top, 40)
            .frame(maxHeight: .infinity)
        }
    }
}

struct AppBar: View {
    let apps: [AppSlice]
    let total: Double
    let ram: Double
    var body: some View {
        GeometryReader { g in
            let sc = g.size.width / CGFloat(total)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Zinc.z100)
                    .frame(width: g.size.width, height: g.size.height - 16).offset(y: 8)
                ForEach(Array(apps.enumerated()), id: \.offset) { i, a in
                    let x = CGFloat(apps.prefix(i).reduce(0) { $0 + $1.gb }) * sc
                    RoundedRectangle(cornerRadius: 8).fill(Zinc.ramp[min(i, 6)])
                        .frame(width: max(2, CGFloat(a.gb) * sc - 3), height: g.size.height - 16)
                        .offset(x: x, y: 8)
                }
                let rx = CGFloat(ram) * sc
                Path { p in p.move(to: CGPoint(x: rx, y: 0)); p.addLine(to: CGPoint(x: rx, y: g.size.height)) }
                    .stroke(Zinc.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [10, 7]))
                Text("\(Int(ram.rounded())) GB RAM")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(Zinc.accent)
                    .fixedSize()
                    .offset(x: rx + 10 > g.size.width - 130 ? rx - 140 : rx + 10, y: -28)
            }
        }
    }
}

struct Legend: View {
    let apps: [AppSlice]
    let m: CardMetrics
    var body: some View {
        let items = apps.enumerated().map { i, a in
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Zinc.ramp[min(i, 6)]).frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Zinc.z200, lineWidth: i >= 5 ? 1 : 0))
                Text(a.name).foregroundStyle(Zinc.z500)
                Text(String(format: "%.1f", a.gb)).font(.system(size: m.wide ? 17 : 19, weight: .semibold, design: .monospaced))
            }
        }
        FlowLayout(spacing: 22, lineSpacing: 8) { ForEach(Array(items.enumerated()), id: \.offset) { $0.element } }
            .font(.system(size: m.wide ? 17 : 19))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0, x + z.width > width { x = 0; y += line + lineSpacing; line = 0 }
            x += z.width + spacing; line = max(line, z.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + z.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += z.width + spacing; line = max(line, z.height)
        }
    }
}

struct SwapChart: View {
    let points: [(t: Date, gb: Double)]
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, pad: CGFloat = 26
            if points.count >= 2, let t0 = points.first?.t, let t1 = points.last?.t {
                let span = max(1, t1.timeIntervalSince(t0))
                let mx = max(1, (points.map(\.gb).max() ?? 1) * 1.15)
                let X = { (t: Date) in CGFloat(t.timeIntervalSince(t0) / span) * w }
                let Y = { (v: Double) in pad + (1 - CGFloat(v / mx)) * (h - pad * 2) }
                let line = Path { p in
                    for (i, pt) in points.enumerated() {
                        let q = CGPoint(x: X(pt.t), y: Y(pt.gb))
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }
                let peak = points.max { $0.gb < $1.gb }!
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: w, y: h - pad)); p.addLine(to: CGPoint(x: 0, y: h - pad)); p.closeSubpath()
                    }.fill(Zinc.z100)
                    line.stroke(Zinc.z500, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                    Rectangle().fill(Zinc.z200).frame(width: w, height: 1).offset(y: h - pad)
                    Circle().fill(Zinc.accent).overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .frame(width: 16, height: 16).offset(x: X(peak.t) - 8, y: Y(peak.gb) - 8)
                    Text("peak \(gbText(peak.gb))").font(.system(size: 19, weight: .semibold)).fixedSize()
                        .offset(x: min(X(peak.t) + 14, w - 170), y: Y(peak.gb) - 30)
                    Text(clock(t0)).font(.system(size: 15, design: .monospaced)).foregroundStyle(Zinc.z400)
                        .offset(y: h - 18)
                    Text(clock(t1)).font(.system(size: 15, design: .monospaced)).foregroundStyle(Zinc.z400)
                        .frame(width: w, alignment: .trailing).offset(y: h - 18)
                }
            }
        }
    }
}

// MARK: - Today

struct TodayCard: View {
    let d: ShareContent.Today
    let m: CardMetrics

    var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "\(cardDate(d.date)), on my Mac", m: m)
            Headline(text: d.headline, m: m)
        }
    }

    var strip: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardCaption(left: m.wide ? "Memory pressure" : "Memory pressure, " + (d.minutesPerBar == 1 ? "one bar a minute" : "a bar per \(d.minutesPerBar) min"),
                    strong: d.pressuredShare.map { "\(Int(($0 * 100).rounded()))%" },
                    right: (m.wide ? "" : " under pressure") + " · \(durationShort(minutes: d.sampledMinutes))", m: m)
            if m.wide { CardPressureStrip(bars: d.strip).frame(height: 56) } else {
                CardPressureStrip(bars: d.strip).frame(minHeight: 70, maxHeight: m.story ? 420 : .infinity)
            }
        }
    }

    var body: some View {
        if m.wide {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 0) { head; Spacer(minLength: 16); strip }
                    .frame(maxWidth: .infinity)
                VStack { Spacer(minLength: 0); Receipt(rows: d.rows, m: m); Spacer(minLength: 0) }
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        } else {
            head
            VStack(alignment: .leading, spacing: m.gap) {
                Receipt(rows: d.rows, m: m)
                strip
            }
            .padding(.top, m.story ? 70 : 40)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - This week

struct WeekCard: View {
    let d: ShareContent.Week
    let m: CardMetrics

    var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "This week on my Mac · since \(d.since.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))", m: m)
            Headline(text: d.headline, m: m)
        }
    }

    var heat: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardCaption(left: "Memory pressure by hour", strong: nil, right: "", m: m)
            Heatmap(rows: d.heat, m: m, grow: !m.wide)
        }
    }

    var body: some View {
        if m.wide {
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 0) { head; Spacer(minLength: 16); heat }
                    .frame(maxWidth: .infinity)
                VStack { Spacer(minLength: 0); Receipt(rows: Array(d.rows.prefix(8)), m: m); Spacer(minLength: 0) }
                    .frame(width: 470)
            }
            .frame(maxHeight: .infinity)
        } else {
            head
            VStack(alignment: .leading, spacing: m.gap) {
                heat
                Receipt(rows: Array(d.rows.prefix(m.ratio == .square ? 6 : 9)), m: m)
            }
            .padding(.top, 40)
            .frame(maxHeight: .infinity)
        }
    }
}

struct Heatmap: View {
    let rows: [(day: Date, hours: [Double?])]
    let m: CardMetrics
    var grow = false
    var body: some View {
        let label: CGFloat = m.wide ? 40 : 52
        let cell: CGFloat = m.wide ? 15 : (m.story ? 30 : (m.ratio == .square ? 16 : 22))
        VStack(alignment: .leading, spacing: m.wide ? 4 : 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 0) {
                    Text(r.day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: m.wide ? 15 : 18)).foregroundStyle(Zinc.z500).frame(width: label, alignment: .leading)
                    HStack(spacing: m.wide ? 3 : 4) {
                        ForEach(0..<24, id: \.self) { h in
                            RoundedRectangle(cornerRadius: 3).fill(color(r.hours[h]))
                                .frame(maxWidth: .infinity).frame(minHeight: cell, maxHeight: grow ? cell * 2.4 : cell)
                        }
                    }
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: label, height: 1)
                ForEach(["00", "06", "12", "18"], id: \.self) { t in
                    Text(t).font(.system(size: 14, design: .monospaced)).foregroundStyle(Zinc.z400)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func color(_ v: Double?) -> Color {
        guard let v else { return Zinc.z100 }
        if v >= 0.5 { return Zinc.accent }
        if v > 0 { return Zinc.accent.opacity(0.4) }
        return Zinc.z300
    }
}

// MARK: - After clean

struct CleanCard: View {
    let d: ShareContent.Clean?
    let m: CardMetrics

    var body: some View {
        if let d { content(d) } else { empty }
    }

    var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "lapang clean", m: m)
            Headline(text: "Nothing big cleaned yet.", m: m)
            Text("Run Clean all in Lapang, then share what it freed.")
                .font(.system(size: m.wide ? 22 : 26)).foregroundStyle(Zinc.z500).padding(.top, 14)
            LevelGauge(fill: 0.35, line: 0.7, fillColor: Zinc.z200, lineWidth: m.wide ? 6 : 7)
                .aspectRatio(0.62, contentMode: .fit)
                .frame(maxWidth: m.wide ? 120 : 190, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
                .padding(.vertical, m.wide ? 16 : 40)
        }
        .frame(maxHeight: .infinity)
    }

    func head(_ d: ShareContent.Clean) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "lapang clean · \(d.time.formatted(.dateTime.weekday(.wide))) \(clock(d.time))", m: m)
            Headline(text: d.headline, m: m)
            Text(d.sub).font(.system(size: m.wide ? 22 : 26)).foregroundStyle(Zinc.z500).padding(.top, 14)
        }
    }

    @ViewBuilder func gauges(_ d: ShareContent.Clean) -> some View {
        if let before = d.ramBeforeGB, let after = d.ramAfterGB {
            let scale = max(before, d.ramGB) * 1.02
            HStack(alignment: .bottom, spacing: m.wide ? 24 : 40) {
                gauge(before, scale: scale, line: d.ramGB / scale, label: "before", fill: Zinc.z400)
                Text("→").font(.system(size: 46)).foregroundStyle(Zinc.z400).padding(.bottom, 70)
                gauge(after, scale: scale, line: d.ramGB / scale, label: "after", fill: Zinc.z300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func gauge(_ v: Double, scale: Double, line: Double, label: String, fill: Color) -> some View {
        VStack(spacing: 14) {
            LevelGauge(fill: v / scale, line: line, fillColor: fill, lineWidth: m.wide ? 6 : 7)
                .aspectRatio(0.62, contentMode: .fit)
                .frame(maxWidth: m.wide ? 150 : 210)
            VStack(spacing: 0) {
                Text(gbText(v)).font(.system(size: 34, weight: .bold, design: .monospaced))
                Text(label).font(.system(size: 20)).foregroundStyle(Zinc.z500)
            }
            .fixedSize()
        }
    }

    func note(_ d: ShareContent.Clean) -> some View {
        Text(d.ramBeforeGB != nil ? "Memory used by apps. Dashed line: \(Int(d.ramGB.rounded())) GB of physical RAM." : "")
            .font(.system(size: 17)).foregroundStyle(Zinc.z400)
    }

    @ViewBuilder func content(_ d: ShareContent.Clean) -> some View {
        if m.wide {
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 22) { head(d); Receipt(rows: d.rows, m: m); note(d); Spacer(minLength: 0) }
                    .frame(maxWidth: .infinity)
                if d.ramBeforeGB != nil { gauges(d).frame(width: 400) }
            }
            .frame(maxHeight: .infinity)
        } else {
            head(d)
            VStack(alignment: .leading, spacing: m.gap) {
                if d.ramBeforeGB != nil { gauges(d) }
                Receipt(rows: d.rows, m: m)
                note(d)
                if d.ramBeforeGB == nil { Spacer(minLength: 0) }
            }
            .padding(.top, 40)
            .frame(maxHeight: .infinity)
        }
    }
}
