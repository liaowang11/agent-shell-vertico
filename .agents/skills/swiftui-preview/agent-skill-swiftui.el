(require 'cl-lib)

(defvar agent-skill-swiftui--template "import SwiftUI

let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { timer in
  Task.detached { @MainActor in
    let renderer = ImageRenderer(content: ContentView())
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 1.0
    let data = renderer.cgImage?.pngData(compressionFactor: 1)
    do {
      let url = URL(fileURLWithPath: \"%s\")
      try data?.write(to: url)
      print(url.path)
      exit(0)
    } catch {
      print(\"Error: \\(error.localizedDescription)\")
      exit(1)
    }
  }
}

RunLoop.current.run()

extension CGImage {
  func pngData(compressionFactor: Float) -> Data? {
    NSBitmapImageRep(cgImage: self).representation(
      using: .png, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: compressionFactor])
  }
}

%s
"
  "Swift wrapper that renders ContentView via ImageRenderer.
First %s is the output PNG path. Second %s is the user-provided body.")

(defun agent-skill-swiftui--wrap (swift-source)
  "Return SWIFT-SOURCE either as-is or wrapped in a ContentView struct.
If SWIFT-SOURCE defines `ContentView', return it unchanged. If it defines
some other struct or class but no `ContentView', signal an error. Otherwise
wrap it as the body of a generated `ContentView'."
  (cond
   ((string-match-p "\\bContentView\\b" swift-source)
    swift-source)
   ((string-match-p "\\b\\(struct\\|class\\)\\b" swift-source)
    (user-error "Swift source defines structs/classes but no `ContentView'"))
   (t
    (format "struct ContentView: View {
  var body: some View {
    VStack {
      %s
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}" swift-source))))

(cl-defun agent-skill-swiftui-render (&key swift-source)
  "Render SWIFT-SOURCE SwiftUI code as a PNG image.

SWIFT-SOURCE is a string of Swift code that should define a
`ContentView: View' struct as the root view. If SWIFT-SOURCE contains
no struct or class definitions, it is wrapped as the body of a
generated `ContentView'.

Compiles a Swift program with `swiftc' that renders `ContentView' via
`ImageRenderer' and writes the result to a temp PNG. Returns the PNG
file path on success, or nil on failure."
  (unless (and (stringp swift-source)
               (not (string-empty-p (string-trim swift-source))))
    (user-error ":swift-source must be a non-empty string"))
  (let* ((basename (make-temp-file "agent-swiftui-"))
         (source-file (concat basename ".swift"))
         (binary basename)
         (png-path (concat basename ".png"))
         (body (agent-skill-swiftui--wrap swift-source))
         (program (format agent-skill-swiftui--template png-path body))
         (command (format "swiftc %s -o %s && %s"
                          (shell-quote-argument source-file)
                          (shell-quote-argument binary)
                          (shell-quote-argument binary)))
         output exit-code)
    (with-temp-file source-file
      (insert program))
    (with-temp-buffer
      (setq exit-code (call-process-shell-command command nil (current-buffer)))
      (setq output (string-trim (buffer-string))))
    (if (and (eq exit-code 0)
             (file-exists-p png-path)
             (> (or (file-attribute-size (file-attributes png-path)) 0) 0)
             (not (string-match-p "error:" output)))
        png-path
      nil)))

(provide 'agent-skill-swiftui)
