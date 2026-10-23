// The chat message box. Emotes appear as pictures as soon as they're typed (a name followed by a
// space, or picked from the picker or suggestions), while the message itself stays plain text.
// Deleting a picture deletes the whole emote; deleting the space after it turns it back into
// text to edit.

import SwiftUI
import UIKit

final class EmoteAttachment: NSTextAttachment {
  let name: String
  let url: URL

  init(name: String, url: URL) {
    self.name = name
    self.url = url
    super.init(data: nil, ofType: nil)
  }

  required init?(coder: NSCoder) { fatalError() }
}

struct EmoteTextField: UIViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  @Binding var height: CGFloat
  var placeholder: String
  var enabled: Bool
  var emoteURL: (String) -> URL?
  var onSubmit: () -> Void

  static let font = UIFont.systemFont(ofSize: 16)
  static let minHeight: CGFloat = 36
  static let maxHeight: CGFloat = 104

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> EmoteTextView {
    let view = EmoteTextView(usingTextLayoutManager: false)
    view.delegate = context.coordinator
    view.font = Self.font
    view.textColor = .white
    view.backgroundColor = .clear
    view.tintColor = UIColor(red: 0.16, green: 0.78, blue: 0.72, alpha: 1)
    view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    view.textContainer.lineFragmentPadding = 0
    view.autocorrectionType = .default
    view.autocapitalizationType = .sentences
    view.spellCheckingType = .default
    view.smartQuotesType = .no
    view.smartDashesType = .no
    view.returnKeyType = .send
    view.enablesReturnKeyAutomatically = true
    view.keyboardAppearance = .dark
    view.isScrollEnabled = false
    view.typingAttributes = Coordinator.attributes
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.placeholder = placeholder
    context.coordinator.render(view, text: text, cursor: (text as NSString).length)
    return view
  }

  func updateUIView(_ view: EmoteTextView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    view.placeholder = placeholder
    view.isEditable = enabled
    // Changed from outside (an emote picked, a name completed, sent and cleared).
    if coordinator.plain(of: view).text != text {
      coordinator.render(view, text: text, cursor: (text as NSString).length)
    }
    // Only act when the request changes: re-applying a stale "focused" brought the keyboard back
    // right after something else (a swipe, a tap outside) had put it away.
    if isFocused != coordinator.appliedFocus {
      coordinator.appliedFocus = isFocused
      if isFocused, enabled, !view.isFirstResponder {
        DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
      } else if !isFocused, view.isFirstResponder {
        DispatchQueue.main.async { view.resignFirstResponder() }
      }
    }
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: EmoteTextField
    /// The focus last asked for (from SwiftUI or by the text view itself).
    var appliedFocus = false
    private var updating = false

    static var attributes: [NSAttributedString.Key: Any] {
      [.font: EmoteTextField.font, .foregroundColor: UIColor.white]
    }

    init(_ parent: EmoteTextField) {
      self.parent = parent
    }

    // MARK: Plain text ↔ what's shown

    /// The message as plain text, where the cursor is in it, and where emote pictures are shown.
    func plain(of view: UITextView) -> (text: String, cursor: Int, emotes: [EmotePosition]) {
      let shown = view.attributedText ?? NSAttributedString()
      let string = shown.string as NSString
      let cursor = view.selectedRange.location
      let result = NSMutableString()
      var plainCursor: Int?
      var emotes: [EmotePosition] = []
      shown.enumerateAttribute(.attachment, in: NSRange(location: 0, length: shown.length)) { value, range, _ in
        for index in range.location..<NSMaxRange(range) {
          if index == cursor { plainCursor = result.length }
          if let emote = value as? EmoteAttachment {
            emotes.append(EmotePosition(offset: result.length, name: emote.name))
            result.append(emote.name)
          } else if value == nil {
            result.append(string.substring(with: NSRange(location: index, length: 1)))
          }
          // Any other attachment (a pasted picture) is dropped.
        }
      }
      return (result as String, plainCursor ?? result.length, emotes)
    }

    struct EmotePosition: Equatable {
      var offset: Int
      var name: String
    }

    /// Where pictures should be for `text`.
    private func wantedEmotes(_ text: String) -> [EmotePosition] {
      let emoteURL = parent.emoteURL
      var offset = 0
      var result: [EmotePosition] = []
      for piece in EmoteText.pieces(text, cursor: 0, isEmote: { emoteURL($0) != nil }).pieces {
        switch piece {
        case .text(let string): offset += (string as NSString).length
        case .emote(let name):
          result.append(EmotePosition(offset: offset, name: name))
          offset += (name as NSString).length
        }
      }
      return result
    }

    /// Shows `text` with completed emote names as pictures; `cursor` is a position in `text`.
    func render(_ view: EmoteTextView, text: String, cursor: Int) {
      let emoteURL = parent.emoteURL
      let layout = EmoteText.pieces(text, cursor: cursor) { emoteURL($0) != nil }
      let shown = NSMutableAttributedString()
      for piece in layout.pieces {
        switch piece {
        case .text(let string):
          shown.append(NSAttributedString(string: string, attributes: Self.attributes))
        case .emote(let name):
          if let url = emoteURL(name) {
            shown.append(NSAttributedString(attachment: attachment(name, url: url, in: view)))
          } else {
            shown.append(NSAttributedString(string: name, attributes: Self.attributes))
          }
        }
      }
      updating = true
      view.attributedText = shown
      view.selectedRange = NSRange(location: min(layout.cursor, shown.length), length: 0)
      view.typingAttributes = Self.attributes
      updating = false
      view.textChanged()
      reportHeight(view)
    }

    private func attachment(_ name: String, url: URL, in view: EmoteTextView) -> EmoteAttachment {
      let attachment = EmoteAttachment(name: name, url: url)
      let font = EmoteTextField.font
      let height = (font.lineHeight + 5).rounded()
      func apply(_ image: UIImage?) {
        let still = image?.images?.first ?? image
        attachment.image = still ?? UIImage()
        let ratio = still.map { $0.size.height > 0 ? min(4, $0.size.width / $0.size.height) : 1 } ?? 1
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: (height * ratio).rounded(), height: height)
      }
      if let cached = ImagePipeline.shared.cached(url, maxPixels: 112) {
        apply(cached)
      } else {
        apply(nil)
        ImagePipeline.shared.load(url, maxPixels: 112) { [weak view, weak attachment] image in
          guard let view, let attachment else { return }
          apply(image)
          // Redraw with the picture (and its real width).
          let all = NSRange(location: 0, length: view.textStorage.length)
          view.layoutManager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
          view.layoutManager.invalidateDisplay(forCharacterRange: all)
          _ = attachment
        }
      }
      return attachment
    }

    private func reportHeight(_ view: UITextView) {
      let width = view.bounds.width > 0 ? view.bounds.width : 200
      let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
      let height = min(EmoteTextField.maxHeight, max(EmoteTextField.minHeight, fitting.rounded()))
      view.isScrollEnabled = fitting > EmoteTextField.maxHeight
      if abs(height - parent.height) > 0.5 {
        DispatchQueue.main.async { [weak self] in self?.parent.height = height }
      }
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      if text == "\n" {
        parent.onSubmit()
        return false
      }
      return true
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !updating, let view = textView as? EmoteTextView else { return }
      let current = plain(of: view)
      // Only redraw when a picture appears or goes (redrawing on every key stopped autocorrect and
      // the suggestions working); never mid-composition.
      if view.markedTextRange == nil, wantedEmotes(current.text) != current.emotes {
        render(view, text: current.text, cursor: current.cursor)
      } else {
        view.textChanged()
        reportHeight(view)
      }
      if parent.text != current.text { parent.text = current.text }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      appliedFocus = true
      if !parent.isFocused { DispatchQueue.main.async { [weak self] in self?.parent.isFocused = true } }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      appliedFocus = false
      if parent.isFocused { DispatchQueue.main.async { [weak self] in self?.parent.isFocused = false } }
    }
  }
}

final class EmoteTextView: UITextView {
  private let placeholderLabel = UILabel()

  var placeholder: String = "" {
    didSet { placeholderLabel.text = placeholder }
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    setUpPlaceholder()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func setUpPlaceholder() {
    placeholderLabel.font = EmoteTextField.font
    placeholderLabel.textColor = UIColor(white: 1, alpha: 0.4)
    placeholderLabel.isUserInteractionEnabled = false
    addSubview(placeholderLabel)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    placeholderLabel.frame = CGRect(
      x: textContainerInset.left, y: textContainerInset.top,
      width: bounds.width - textContainerInset.left - textContainerInset.right, height: EmoteTextField.font.lineHeight)
  }

  func textChanged() {
    placeholderLabel.isHidden = textStorage.length > 0
  }
}
