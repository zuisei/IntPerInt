import SwiftUI

struct AdvancedParamsView: View {
    @Binding var temperature: Double
    @Binding var topP: Double
    @Binding var maxTokens: Double
    @Binding var seedText: String
    @Binding var stopWords: String
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("生成パラメータ")
                    .font(.headline)
                Spacer()
                Button("閉じる") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Temperature
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Temperature")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            Text(String(format: "%.2f", temperature))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $temperature, in: 0.0...2.0, step: 0.01)
                        Text("創造性を制御します。低い値ほど一貫性があり、高い値ほど創造的になります。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Top-P
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Top-P")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            Text(String(format: "%.2f", topP))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $topP, in: 0.0...1.0, step: 0.01)
                        Text("上位確率の単語のみを考慮します。1.0で無効、低い値ほど制限が厳しくなります。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Max Tokens
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Max Tokens")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(Int(maxTokens))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $maxTokens, in: 1...4096, step: 1)
                        Text("生成される最大トークン数を制限します。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Seed
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Seed (オプション)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("乱数シード (空白で自動)", text: $seedText)
                            .textFieldStyle(.roundedBorder)
                        Text("同じシードで同じプロンプトを入力すると、同じ結果が得られます。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Stop Words
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stop Words (オプション)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("停止単語をカンマ区切りで入力", text: $stopWords)
                            .textFieldStyle(.roundedBorder)
                        Text("これらの単語が現れると生成を停止します。例: Human:,Assistant:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Presets
                    VStack(alignment: .leading, spacing: 8) {
                        Text("プリセット")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        HStack(spacing: 12) {
                            Button("保守的") {
                                temperature = 0.3
                                topP = 0.9
                                maxTokens = 512
                            }
                            .buttonStyle(.bordered)
                            
                            Button("バランス") {
                                temperature = 0.7
                                topP = 1.0
                                maxTokens = 512
                            }
                            .buttonStyle(.bordered)
                            
                            Button("創造的") {
                                temperature = 1.2
                                topP = 0.95
                                maxTokens = 1024
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(20)
        .frame(width: 400, height: 600)
    }
}

#Preview {
    AdvancedParamsView(
        temperature: .constant(0.7),
        topP: .constant(1.0),
        maxTokens: .constant(512),
        seedText: .constant(""),
        stopWords: .constant("")
    )
}
