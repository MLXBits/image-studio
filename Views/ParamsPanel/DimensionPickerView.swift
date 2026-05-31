import SwiftUI

private struct AspectPreset: Identifiable {
    let id = UUID()
    let label: String
    let width: Int
    let height: Int
}

private let presets: [AspectPreset] = [
    AspectPreset(label: "1:1",   width: 1024, height: 1024),
    AspectPreset(label: "3:2",   width: 1152, height: 768),
    AspectPreset(label: "2:3",   width: 768,  height: 1152),
    AspectPreset(label: "16:9",  width: 1360, height: 768),
    AspectPreset(label: "9:16",  width: 768,  height: 1360),
    AspectPreset(label: "4:3",   width: 1024, height: 768),
    AspectPreset(label: "3:4",   width: 768,  height: 1024),
    AspectPreset(label: "21:9",  width: 1680, height: 720),
]

struct DimensionPickerView: View {
    @Binding var width: Int
    @Binding var height: Int

    @State private var widthText: String = ""
    @State private var heightText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(presets) { p in
                        Button(p.label) {
                            width = p.width; height = p.height
                            widthText = "\(p.width)"; heightText = "\(p.height)"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundStyle(width == p.width && height == p.height ? .primary : .secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("W").font(.caption2).foregroundStyle(.secondary)
                    TextField("1024", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 64)
                        .onSubmit { applyWidthText() }
                        .onChange(of: widthText) { _, v in
                            if let n = Int(v), n > 0 { width = snapTo64(n) }
                        }
                }
                Text("×").foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("H").font(.caption2).foregroundStyle(.secondary)
                    TextField("1024", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 64)
                        .onSubmit { applyHeightText() }
                        .onChange(of: heightText) { _, v in
                            if let n = Int(v), n > 0 { height = snapTo64(n) }
                        }
                }
                Spacer()
            }
        }
        .onAppear {
            widthText = "\(width)"; heightText = "\(height)"
        }
        .onChange(of: width)  { _, v in widthText  = "\(v)" }
        .onChange(of: height) { _, v in heightText = "\(v)" }
    }

    private func applyWidthText()  { if let n = Int(widthText),  n > 0 { width  = snapTo64(n) } }
    private func applyHeightText() { if let n = Int(heightText), n > 0 { height = snapTo64(n) } }

    private func snapTo64(_ n: Int) -> Int { max(64, (n / 64) * 64) }
}
