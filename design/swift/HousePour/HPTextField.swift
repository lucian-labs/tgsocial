// House Pour kit — HPTextField (COMPONENTS.md "Controls").
// Field label above, hairline input, focus ring in accentSoft (the one ring in the look).

import SwiftUI

public enum HPFieldKind: Equatable {
    case text, phone, number, secure, url
    case multiline(rows: Int)
}

public struct HPTextField: View {
    let label: String?
    let placeholder: String
    let kind: HPFieldKind
    @Binding var text: String
    let onSubmit: (() -> Void)?
    @FocusState private var focused: Bool
    @HPScaledFactor private var scale

    public init(_ label: String? = nil, text: Binding<String>, placeholder: String = "",
                kind: HPFieldKind = .text, onSubmit: (() -> Void)? = nil) {
        self.label = label; _text = text; self.placeholder = placeholder; self.kind = kind; self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label { HPFieldLabel(label) }
            field
                .padding(.vertical, HPTokens.Space.inputY)
                .padding(.horizontal, HPTokens.Space.inputX)
                .background(RoundedRectangle(cornerRadius: HPTokens.Radius.input, style: .continuous).fill(HPTokens.Colors.inputBg))
                .overlay(
                    RoundedRectangle(cornerRadius: HPTokens.Radius.input, style: .continuous)
                        .strokeBorder(focused ? HPTokens.Colors.accent : HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth)
                )
                .background(
                    RoundedRectangle(cornerRadius: HPTokens.Radius.input + HPMetric.focusRing, style: .continuous)
                        .fill(focused ? HPTokens.Colors.accentSoft : Color.clear)
                        .padding(-HPMetric.focusRing)
                )
                .animation(HPMotion.color, value: focused)
                .onTapGesture { focused = true }
                .padding(.bottom, HPTokens.Space.inputBottom)
        }
    }

    @ViewBuilder private var field: some View {
        let style = HPType.input
        let font = HPFont.font(style, scale: scale)
        let prompt = Text(placeholder).foregroundColor(HPTokens.Colors.faint).font(font)
        switch kind {
        case .secure:
            SecureField("", text: $text, prompt: prompt)
                .font(font).foregroundStyle(HPTokens.Colors.ink)
                .textContentType(.password)
                .focused($focused)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(label ?? placeholder)
        case .multiline(let rows):
            TextField("", text: $text, prompt: prompt, axis: .vertical)
                .font(font).foregroundStyle(HPTokens.Colors.ink)
                .lineLimit(rows...max(rows, 40))
                .lineSpacing(style.lineSpacing * scale)
                .focused($focused)
                .accessibilityLabel(label ?? placeholder)
        default:
            TextField("", text: $text, prompt: prompt)
                .font(font).foregroundStyle(HPTokens.Colors.ink)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(kind == .text ? .sentences : .never)
                .autocorrectionDisabled(kind != .text)
                .focused($focused)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(label ?? placeholder)
        }
    }

    private var keyboard: UIKeyboardType {
        switch kind {
        case .phone: return .phonePad
        case .number: return .numberPad
        case .url: return .URL
        default: return .default
        }
    }

    private var contentType: UITextContentType? {
        switch kind {
        case .phone: return .telephoneNumber
        case .number: return .oneTimeCode
        case .url: return .URL
        default: return nil
        }
    }
}
