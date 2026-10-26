import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FrameKitCaptions

/// The reference fixtures, read in place: frames.json, the golden PNGs and their manifest. Nothing is
/// copied or written next to them.
enum Fixture {
    static let dir = Repo.url("captions/tests/fixtures/ep001")

    /// Frame items by frame index, read as the frozen renderer reads them (with JSONSerialization), so
    /// that both draw the same numbers: Foundation misreads some 17-digit numbers by an ulp or two.
    static func items() throws -> [Int: [[String: Any]]] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("frames.json"))) as? [String: Any])
        let frames = try #require(root["frames"] as? [[String: Any]])
        var items: [Int: [[String: Any]]] = [:]
        for frame in frames { items[frame["index"] as! Int] = (frame["items"] as! [[String: Any]]) }
        return items
    }

    static func golden(_ index: Int) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("golden").appendingPathComponent(String(format: "%04d.png", index)))
    }

    /// Fields of a reference item or run that the engine draws only at these values. Any other value is a
    /// reference feature the engine does not have.
    static let neutral: [String: Double] = ["scale": 1, "glow": 0, "dx": 0, "dy": 0]

    /// A reference item as an engine item, or the reference features it uses that the engine lacks. One
    /// horizontal offset shared by every run of an item moves the whole cue, which the engine expresses as
    /// its centre (`placement.x`).
    static func engineItem(_ it: [String: Any], canvasWidth: Int = 1080) -> (item: CaptionFrame.Item?, unsupported: [String]) {
        let runs = (it["lines"] as! [[[String: Any]]]).joined()
        var unsupported: [String] = []
        if (it["scale"] as? Double ?? 1) != 1 { unsupported.append("item scale") }
        let dxs = Set(runs.map { $0["dx"] as? Double ?? 0 })
        if dxs.count > 1 { unsupported.append("per-word horizontal offset") }
        let names = ["scale": "scale", "glow": "glow", "dy": "vertical offset"]
        for run in runs {
            for key in ["scale", "glow", "dy"] where (run[key] as? Double ?? neutral[key]!) != neutral[key]! {
                unsupported.append("\"\(run["text"] as! String)\": \(names[key]!)")
            }
            if let font = run["font"] as? String, !["AvenirNext-Medium", "Palatino-Italic"].contains(font) {
                unsupported.append("\"\(run["text"] as! String)\": font \(font), outside kinetic-minimal")
            }
        }
        guard unsupported.isEmpty else { return (nil, unsupported) }
        func rgb(_ v: Any?) -> RGBColor { let c = v as! [Double]; return RGBColor(red: c[0], green: c[1], blue: c[2]) }
        let font = it["font"] as! String, size = it["size"] as! Double
        let lines = (it["lines"] as! [[[String: Any]]]).map { line in
            line.map { CaptionFrame.Run(text: $0["text"] as! String, font: $0["font"] as? String ?? font,
                                        size: $0["size"] as? Double ?? size, color: rgb($0["color"])) }
        }
        let item = CaptionFrame.Item(
            cueID: "", font: font, size: size, tracking: it["tracking"] as? Double ?? 0, lineHeight: it["line_height"] as! Double,
            centerX: (it["cx"] as? Double ?? Double(canvasWidth) / 2) + (dxs.first ?? 0), baselineY: it["y_base"] as! Double,
            alpha: it["alpha"] as! Double, offsetY: it["dy"] as! Double,
            outlineWidth: it["stroke"] as! Double, outlineColor: rgb(it["outline"]), outlineAlpha: 0.92,
            shadowColor: RGBColor(red: 0, green: 0, blue: 0), shadowAlpha: it["shadow_alpha"] as! Double,
            shadowBlur: it["shadow_blur"] as! Double, shadowDX: 0, shadowDY: -(it["shadow_dy"] as! Double), lines: lines)
        return (item, [])
    }
}

/// Decoded PNG pixels, compared as stored (8-bit RGBA, not premultiplied).
struct Pixels: Equatable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(png: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.alphaInfo == .last, "not 8-bit RGBA")
        let data = try #require(image.dataProvider?.data) as Data
        width = image.width
        height = image.height
        var rgba: [UInt8] = []
        rgba.reserveCapacity(width * height * 4)
        for row in 0..<height {
            let start = row * image.bytesPerRow
            rgba += data[start..<start + width * 4]
        }
        self.rgba = rgba
    }

    /// Pixels whose stored RGBA differ.
    func differingPixels(_ other: Pixels) -> Int {
        guard width == other.width && height == other.height else { return width * height }
        return stride(from: 0, to: rgba.count, by: 4).filter { rgba[$0..<$0 + 4] != other.rgba[$0..<$0 + 4] }.count
    }

    /// Pixels with any opacity.
    var ink: Int { stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count }
}

/// Runs a program and returns its standard output, or throws with its error output.
func runTool(_ arguments: [String], timeout: TimeInterval = 600) throws -> String {
    struct ToolFailed: Error, CustomStringConvertible { let description: String }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolFailed(description: "\(arguments.joined(separator: " ")) exited with \(process.terminationStatus): \(String(decoding: errors, as: UTF8.self))")
    }
    return String(decoding: output, as: UTF8.self)
}

/// The frozen reference renderer, built and run once per test process on this machine, and whether this
/// machine is the one the goldens were made on.
enum ReferenceRun {
    struct Output: Sendable {
        /// The frozen renderer, compiled into a temporary directory.
        let binary: String
        /// PNG per frame index, rendered by the frozen renderer from the fixture's frames.json.
        let pngs: [Int: Data]
        /// The goldens' environment (macOS build, arch, Swift, fonts) equals this one, as decided by the
        /// regression runner.
        let environmentMatches: Bool
    }

    static let output: Result<Output, ErrorDescription> = {
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("framekit-engine-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let binary = tmp.appendingPathComponent("render_caps").path
            _ = try runTool(["swiftc", "-O", Repo.url("captions/reference/render_caps.swift").path, "-o", binary])
            let pngs = try render(Fixture.dir.appendingPathComponent("frames.json"), with: binary)
            let current = try runTool(["python3", "-I", Repo.url("captions/tests/run_reference_regression.py").path, "--print-environment"])
            guard case .object(let m)? = JSONValue.parse(try Data(contentsOf: Fixture.dir.appendingPathComponent("manifest.json"))) else {
                throw ErrorDescription(description: "manifest.json is not a JSON object")
            }
            return .success(Output(binary: binary, pngs: pngs, environmentMatches: JSONValue.parse(Data(current.utf8)) == m["environment"]))
        } catch {
            return .failure(ErrorDescription(description: "\(error)"))
        }
    }()

    /// PNG per frame index, rendered by the frozen renderer from a frames file.
    static func render(_ framesJSON: URL, with binary: String) throws -> [Int: Data] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("framekit-reference-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try runTool([binary, framesJSON.path, out.path])
        var pngs: [Int: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: out.path) where name.hasSuffix(".png") {
            pngs[Int(name.dropLast(4))!] = try Data(contentsOf: out.appendingPathComponent(name))
        }
        return pngs
    }

    /// Engine frames drawn by the frozen renderer: each item written in its frames.json format. The
    /// reference hard-codes a black shadow and an outline alpha of 0.92, so frames must use those.
    static func render(_ frames: [CaptionFrame]) throws -> [Int: Data] {
        func rgb(_ c: RGBColor) -> [Double] { [c.red, c.green, c.blue] }
        let doc: [String: Any] = ["frames": try frames.map { frame -> [String: Any] in
            ["index": frame.index, "items": try frame.items.map { item -> [String: Any] in
                guard item.outlineAlpha == 0.92 && item.shadowColor == RGBColor(red: 0, green: 0, blue: 0) && item.shadowDX == 0 else {
                    throw ErrorDescription(description: "the frozen renderer cannot draw item \(item.cueID)")
                }
                return ["font": item.font, "size": item.size, "tracking": item.tracking, "stroke": item.outlineWidth,
                        "outline": rgb(item.outlineColor), "line_height": item.lineHeight, "y_base": item.baselineY,
                        "cx": item.centerX, "alpha": item.alpha, "dy": item.offsetY, "scale": 1.0,
                        "shadow_blur": item.shadowBlur, "shadow_alpha": item.shadowAlpha, "shadow_dy": -item.shadowDY,
                        "lines": item.lines.map { $0.map { run -> [String: Any] in
                            ["text": run.text, "color": rgb(run.color), "font": run.font, "size": run.size,
                             "scale": 1.0, "glow": 0.0, "dx": 0.0, "dy": 0.0]
                        } }]
            }]
        }]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("framekit-frames-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: doc).write(to: file)
        return try render(file, with: output.get().binary)
    }
}

struct ErrorDescription: Error, CustomStringConvertible {
    let description: String
}
