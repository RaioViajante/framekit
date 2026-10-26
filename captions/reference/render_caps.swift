// Renderizador de legendas: lê frames.json e grava um PNG RGBA 1080x1916 por quadro (CoreText + CoreGraphics).
// Uso: render_caps frames.json out_dir
import AppKit
import CoreText
import Foundation

let W = 1080, H = 1916
let args = CommandLine.arguments
guard args.count >= 3 else { print("uso: render_caps frames.json out_dir"); exit(1) }
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let frames = root["frames"] as! [[String: Any]]
let outDir = args[2]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ c: [Double], _ a: Double) -> CGColor { CGColor(colorSpace: cs, components: [CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2]), CGFloat(a)])! }

struct Glyph { let path: CGPath; let x: CGFloat }
func runPath(_ text: String, font: CTFont, tracking: CGFloat) -> (paths: [Glyph], width: CGFloat) {
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attr)
    var out: [Glyph] = []; var x: CGFloat = 0
    for r in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(r)
        var g = [CGGlyph](repeating: 0, count: n); var p = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(r, CFRange(location: 0, length: n), &g); CTRunGetPositions(r, CFRange(location: 0, length: n), &p)
        for i in 0..<n {
            if let gp = CTFontCreatePathForGlyph(font, g[i], nil) { out.append(Glyph(path: gp, x: p[i].x + CGFloat(i) * tracking)) }
        }
    }
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + CGFloat(max(0, text.count - 1)) * tracking
    return (out, w)
}

var cache: [String: CTFont] = [:]
func font(_ name: String, _ size: CGFloat) -> CTFont {
    let k = "\(name)@\(size)"; if let f = cache[k] { return f }
    let f = CTFontCreateWithName(name as CFString, size, nil); cache[k] = f; return f
}

func render(_ items: [[String: Any]]) -> Data {
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)        // origem no canto superior esquerdo
    ctx.setLineJoin(.round); ctx.setLineCap(.round)
    for it in items {
        let alpha = it["alpha"] as! Double; if alpha <= 0.002 { continue }
        let fname = it["font"] as! String; let size = CGFloat(it["size"] as! Double)
        let f = font(fname, size); let tracking = CGFloat((it["tracking"] as? Double) ?? 0)
        let stroke = it["stroke"] as! Double; let outline = it["outline"] as! [Double]
        let dy = CGFloat(it["dy"] as! Double); let gscale = CGFloat((it["scale"] as? Double) ?? 1.0)
        let cx = CGFloat((it["cx"] as? Double) ?? Double(W) / 2)
        let lh = CGFloat(it["line_height"] as! Double); let yb = CGFloat(it["y_base"] as! Double) + dy
        let lines = it["lines"] as! [[[String: Any]]]
        for (li, runs) in lines.enumerated() {
            var parts: [(paths: [Glyph], width: CGFloat, run: [String: Any])] = []
            var total: CGFloat = 0
            let space = CTFontGetAdvancesForGlyphs(f, .horizontal, [CTFontGetGlyphWithName(f, "space" as CFString)], nil, 1)
            for (ri, run) in runs.enumerated() {
                let rfn = (run["font"] as? String) ?? fname; let rsz = CGFloat((run["size"] as? Double) ?? Double(size)); let rf = font(rfn, rsz)
                let rp = runPath(run["text"] as! String, font: rf, tracking: tracking)
                parts.append((rp.paths, rp.width, run)); total += rp.width
                if ri < runs.count - 1 { total += CGFloat(space) }
            }
            var x = cx - total * gscale / 2
            let base = yb + CGFloat(li) * lh
            for (ri, p) in parts.enumerated() {
                let rs = CGFloat((p.run["scale"] as? Double) ?? 1.0) * gscale
                let col = p.run["color"] as! [Double]; let glow = (p.run["glow"] as? Double) ?? 0
                // transformação: escala em torno do centro do trecho (linha de base) e flip do eixo y
                let cxr = x + p.width * gscale / 2
                let rdx = CGFloat((p.run["dx"] as? Double) ?? 0); let rdy = CGFloat((p.run["dy"] as? Double) ?? 0)
                var t = CGAffineTransform(translationX: cxr + rdx, y: base + rdy).scaledBy(x: rs, y: -rs).translatedBy(x: -p.width / 2, y: 0)
                let path = CGMutablePath()
                for g in p.paths { path.addPath(g.path, transform: CGAffineTransform(translationX: g.x, y: 0)) }
                let tp = path.copy(using: &t)!
                // 1) sombra suave + contorno
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: CGFloat((it["shadow_dy"] as? Double) ?? 5)), blur: CGFloat((it["shadow_blur"] as? Double) ?? 16), color: color([0, 0, 0], ((it["shadow_alpha"] as? Double) ?? 0.62) * alpha))
                ctx.setLineWidth(CGFloat(stroke) * rs); ctx.setStrokeColor(color(outline, 0.92 * alpha))
                ctx.addPath(tp); ctx.strokePath()
                ctx.restoreGState()
                // 2) brilho lilás opcional
                if glow > 0.01 {
                    ctx.saveGState()
                    ctx.setShadow(offset: .zero, blur: 18, color: color([0.765, 0.702, 0.878], 0.55 * glow * alpha))
                    ctx.setFillColor(color(col, alpha)); ctx.addPath(tp); ctx.fillPath()
                    ctx.restoreGState()
                }
                // 3) preenchimento
                ctx.setFillColor(color(col, alpha)); ctx.addPath(tp); ctx.fillPath()
                x += (p.width * gscale)
                if ri < parts.count - 1 { x += CGFloat(space) * gscale }
            }
        }
    }
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    return rep.representation(using: .png, properties: [:])!
}

var count = 0
for fr in frames {
    let idx = fr["index"] as! Int; let items = fr["items"] as! [[String: Any]]
    let png = render(items)
    try png.write(to: URL(fileURLWithPath: String(format: "%@/%04d.png", outDir, idx)))
    count += 1
}
print("PNGs gravados:", count)
