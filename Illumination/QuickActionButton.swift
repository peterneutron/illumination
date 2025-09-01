//
//  QuickActionButton.swift
//  PowerGrid
//
//
//
// File: QuickActionButton.swift

import SwiftUI
import AppKit

// MARK: - Haptics (optional)
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - Common Style
struct CircleToggleStyle: ButtonStyle {
    var isOn: Bool
    var hovering: Bool
    var size: CGFloat
    var tintColor: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .scaleEffect(pressed ? 0.96 : (hovering ? 1.03 : 1.0))
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: pressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: hovering)

            .foregroundStyle(isOn ? tintColor : Color.primary.opacity(0.85))

            .background(
                ZStack {
                    Circle().fill(.thinMaterial)

                    if isOn {
                        Circle()
                            .fill(tintColor.opacity(0.22))
                            .transition(.opacity)
                    }

                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                        .blur(radius: 0.5)
                        .opacity(0.7)
                }
            )

            .overlay(
                Circle()
                    .strokeBorder(isOn ? tintColor : .secondary.opacity(0.35),
                                  lineWidth: isOn ? 1.6 : 1)
                    .opacity(hovering ? 1 : 0.8)
            )

            .shadow(color: .black.opacity(0.25),
                    radius: hovering ? 6 : 3, x: 0, y: hovering ? 2 : 1)
            .shadow(color: .black.opacity(0.001), radius: pressed ? 0 : 0.001)
            .contentShape(Circle())
    }
}

// MARK: - MultiStateActionButton
struct ActionState<Value: Equatable>: Equatable {
    var value: Value
    var imageName: String
    var tint: Color? = nil
    var help: String? = nil
    var accessibilityLabel: String? = nil
}

struct MultiStateActionButton<Value: Equatable>: View {
    var title: String?
    var states: [ActionState<Value>]
    @Binding var selection: Value
    var size: CGFloat = 48
    var enableHaptics: Bool = true
    var showsCaption: Bool = false
    var isActiveProvider: ((Value) -> Bool)? = nil
    var onChange: ((Value) -> Void)? = nil
    // Optional: skip certain values when cycling (e.g., disable a state)
    var shouldSkip: ((Value) -> Bool)? = nil

    @State private var hovering = false

    private func nextSelection() -> Value {
        guard let idx = states.firstIndex(where: { $0.value == selection }) else {
            return states.first?.value ?? selection
        }
        var nextIdx = idx
        for _ in 0..<states.count {
            nextIdx = (nextIdx + 1) % states.count
            let candidate = states[nextIdx].value
            if let skip = shouldSkip, skip(candidate) { continue }
            return candidate
        }
        return selection
    }

    private var currentState: ActionState<Value>? {
        states.first(where: { $0.value == selection }) ?? states.first
    }

    private var isOn: Bool {
        if let provider = isActiveProvider { return provider(selection) }
        // Default: first state is Off, others are On
        if let idx = states.firstIndex(where: { $0.value == selection }) {
            return idx != 0
        }
        return false
    }

    var body: some View {
        let image = currentState?.imageName ?? "questionmark"
        let tint = currentState?.tint ?? .accentColor

        VStack(spacing: showsCaption ? 8 : 0) {
            Button {
                let newValue = nextSelection()
                selection = newValue
                onChange?(newValue)
                if enableHaptics { Haptics.tap() }
            } label: {
                Image(systemName: image)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .help(currentState?.help ?? title ?? image)
            .accessibilityLabel(Text(currentState?.accessibilityLabel ?? title ?? image))
            .accessibilityValue(Text(isOn ? "On" : "Off"))
            .buttonStyle(
                CircleToggleStyle(
                    isOn: isOn,
                    hovering: hovering,
                    size: size,
                    tintColor: tint
                )
            )

            if showsCaption, let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size * 1.35)
            }
        }
        .onHover { hovering = $0 }
    }
}
