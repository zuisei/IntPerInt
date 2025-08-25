import SwiftUI
import Foundation

struct RightSidebar: View {
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var maxTokens: Double
    @Binding var seedText: String
    @Binding var stopWords: String
    @Binding var frameCount: Double
    @Binding var useMotionLoRA: Bool
    @AppStorage("allowNSFW") private var allowNSFW: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Settings")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Temperature
                    ParameterSlider(
                        title: "Temperature",
                        value: $temperature,
                        range: 0...2,
                        step: 0.01,
                        description: "Controls randomness"
                    )
                    
                    // Top P
                    ParameterSlider(
                        title: "Top P",
                        value: $topP,
                        range: 0...1,
                        step: 0.01,
                        description: "Nucleus sampling"
                    )
                    
                    // Max Tokens
                    ParameterSlider(
                        title: "Max Tokens",
                        value: $maxTokens,
                        range: 1...2048,
                        step: 1,
                        description: "Response length limit"
                    )
                    
                    Divider()
                    
                    // Seed
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Seed (optional)")
                            .font(.caption.weight(.medium))
                        TextField("Random seed", text: $seedText)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    
                    // Stop Words
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stop Words")
                            .font(.caption.weight(.medium))
                        TextField("Comma separated", text: $stopWords)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    
                    Divider()

                    // Quick Presets
                    ParameterPresets(
                        temperature: $temperature,
                        topP: $topP,
                        maxTokens: $maxTokens
                    )

                    Divider()
                    Toggle(isOn: $allowNSFW) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow NSFW")
                                .font(.caption.weight(.medium))
                            Text("When enabled, filtering is relaxed for image/video generation.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    // Video generation parameters
                    ParameterSlider(
                        title: "Frames",
                        value: $frameCount,
                        range: 1...120,
                        step: 1,
                        description: "Number of frames"
                    )

                    Toggle(isOn: $useMotionLoRA) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Motion LoRA")
                                .font(.caption.weight(.medium))
                            Text("Enable AnimateDiff Motion LoRA modules")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(.horizontal)
            }
        }
        .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }
}

struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let description: String?
    
    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, description: String? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.description = description
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.medium))
                    if let description = description {
                        Text(description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Text(step >= 1 ? String(format: "%.0f", value) : String(format: "%.2f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct ParameterPresets: View {
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var maxTokens: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.caption.weight(.medium))
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 6) {
                presetButton("Creative", temp: 0.9, topP: 0.9, tokens: 1024)
                presetButton("Balanced", temp: 0.7, topP: 1.0, tokens: 512)
                presetButton("Precise", temp: 0.3, topP: 0.9, tokens: 512)
                presetButton("Code", temp: 0.1, topP: 0.95, tokens: 2048)
            }
        }
    }
    
    private func presetButton(_ name: String, temp: Double, topP: Double, tokens: Double) -> some View {
        Button(name) {
            temperature = temp
            self.topP = topP
            maxTokens = tokens
        }
        .buttonStyle(.bordered)
        .font(.caption)
        .controlSize(.small)
    }
}
