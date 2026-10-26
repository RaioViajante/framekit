// Reports whether each PostScript font name given on the command line resolves to that exact font.
// CoreText silently substitutes unknown names, so availability is judged by the name that comes back.
// Output: one JSON object per line. Exit status is 0 if all fonts resolve, 1 otherwise.
import CoreText
import Foundation

var missing = 0
for name in CommandLine.arguments.dropFirst() {
    let f = CTFontCreateWithName(name as CFString, 12, nil)
    let resolved = CTFontCopyPostScriptName(f) as String
    let ok = (resolved == name)
    let version = (CTFontCopyName(f, kCTFontVersionNameKey) as String?) ?? ""
    if !ok { missing += 1 }
    let obj: [String: Any] = ["requested": name, "resolved": resolved, "available": ok, "version": version]
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
exit(missing == 0 ? 0 : 1)
