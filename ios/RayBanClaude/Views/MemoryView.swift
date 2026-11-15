import SwiftUI
import UIKit

/// View and manage memory: delete entries, add your own, import from the Claude app.
struct MemoryView: View {
    @ObservedObject var memory: MemoryStore
    @Binding var enabled: Bool

    @State private var newFact = ""
    @State private var showImport = false
    @State private var confirmClear = false

    var body: some View {
        List {
            Group {
                Section {
                    Toggle("Claude remembers things about you", isOn: $enabled)
                } footer: {
                    Text("Say something like \"Hey Claude, remember that my daughter's name is Mia\" – or Claude will note on its own what is important long-term. \"Forget about …\" removes it again. The list is stored only on this iPhone and is sent to Claude at the start of every conversation.")
                }

                if enabled {
                    Section {
                        Button {
                            showImport = true
                        } label: {
                            Label("Import from the Claude app", systemImage: "square.and.arrow.down.on.square")
                        }
                        HStack {
                            TextField("Add your own, e.g. \"Drinks espresso without sugar\"", text: $newFact)
                                .submitLabel(.done)
                                .onSubmit(addFact)
                            Button("Remember", action: addFact)
                                .disabled(MemoryStore.clean(newFact).isEmpty)
                        }
                    }

                    Section {
                        if memory.items.isEmpty {
                            Text("Nothing remembered yet.").foregroundStyle(Color.hudMuted)
                        }
                        ForEach(memory.items.reversed()) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                Text(item.created, format: .dateTime.day().month().year())
                                    .font(.hudMono(10)).foregroundStyle(Color.hudMuted)
                            }
                        }
                        .onDelete { offsets in
                            // Display is reversed (newest on top) → convert indices back
                            let count = memory.items.count
                            memory.remove(at: IndexSet(offsets.map { count - 1 - $0 }))
                        }
                    } header: {
                        HUDLabel("Remembered (\(memory.items.count))")
                    } footer: {
                        Text("Swipe left to delete.")
                    }

                    if !memory.items.isEmpty {
                        Section {
                            Button("Forget everything", role: .destructive) { confirmClear = true }
                        }
                    }
                }
            }
            .hudSection()
        }
        .navigationTitle("Memory")
        .hudList()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImport) { MemoryImportView(memory: memory) }
        .confirmationDialog("Really delete all \(memory.items.count) entries?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Forget everything", role: .destructive) { memory.clear() }
        }
    }

    private func addFact() {
        guard memory.add(newFact) != nil else { return }
        newFact = ""
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Import from the official Claude app: there you ask Claude for a summary
/// and paste it here. (There is no interface for reading the chats directly.)
struct MemoryImportView: View {
    @ObservedObject var memory: MemoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var copied = false

    static let prompt = "Summarize in short bullet points what you permanently know about me from our previous chats: names, family, job, preferences, plans, important appointments. One line per point, no introduction."

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    step(1, "Open the Claude app (or claude.ai) and send Claude this question:")
                    Text(Self.prompt)
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.hudBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: HUDMetrics.radius))
                        .overlay(RoundedRectangle(cornerRadius: HUDMetrics.radius)
                            .strokeBorder(Color.hudLineStrong, lineWidth: HUDMetrics.hairline))
                    Button {
                        UIPasteboard.general.string = Self.prompt
                        copied = true
                    } label: {
                        Label(copied ? "Copied ✓" : "Copy question", systemImage: "doc.on.doc")
                    }
                    step(2, "Copy Claude's answer and paste it below.")
                } header: {
                    HUDLabel("How it works")
                } footer: {
                    Text("Even easier on the PC: the Claude desktop app is linked with RayBan Claude. Just say \"Transfer what you know about me to the glasses\" there – Claude writes it straight here.")
                }
                .hudSection()

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                    // PasteButton pastes without the "Allow Paste?" prompt
                    PasteButton(payloadType: String.self) { strings in
                        if let pasted = strings.first { text = pasted }
                    }
                } header: {
                    HUDLabel("Claude's answer")
                } footer: {
                    Text("Each line becomes an entry. Skim through and delete anything Claude shouldn't know – everything stays only on this iPhone.")
                }
                .hudSection()
            }
            .hudList()
            .navigationTitle("From the Claude app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import") {
                        _ = memory.importLines(text)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HUDStepBadge(number: number)
            Text(text)
        }
    }
}
