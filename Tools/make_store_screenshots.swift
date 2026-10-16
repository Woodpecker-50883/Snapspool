// App Store用のスクリーンショットを規定サイズに整える。
//
// 仕様: 16:10（2880×1800）、PNG、透過なし。
// 撮った生のスクショは比率もサイズもまちまちなので、縦横比を保ったまま縮小し、
// 背景色の上に中央配置して規定サイズに収める。透過は背景で潰れる。
//
// 使い方:
//   swift Tools/make_store_screenshots.swift <入力フォルダ> <出力フォルダ>
//
// 入力フォルダのPNG/JPEGを順に処理し、出力フォルダへ `01.png` から連番で書き出す。

import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("使い方: swift make_store_screenshots.swift <入力フォルダ> <出力フォルダ>")
    exit(1)
}
let inputDir = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2])
let target = NSSize(width: 2880, height: 1800)
// 余白の色。暗めの紫でアイコンと揃える
let background = NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.34, alpha: 1)

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let files = (try? FileManager.default.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil))?
    .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

guard !files.isEmpty else {
    print("入力フォルダに画像がありません: \(inputDir.path)")
    exit(1)
}

for (index, file) in files.enumerated() {
    guard let source = NSImage(contentsOf: file),
          let sourceRep = NSBitmapImageRep(data: source.tiffRepresentation ?? Data()) else {
        print("読み込めませんでした: \(file.lastPathComponent)")
        continue
    }
    let sourceSize = NSSize(width: sourceRep.pixelsWide, height: sourceRep.pixelsHigh)

    // 余白を少し残して収める（縮小のみ。拡大すると粗くなるため等倍を上限にする）
    let margin: CGFloat = 0.92
    let scale = min(target.width * margin / sourceSize.width,
                    target.height * margin / sourceSize.height,
                    1.0)
    let drawSize = NSSize(width: (sourceSize.width * scale).rounded(),
                          height: (sourceSize.height * scale).rounded())
    let origin = NSPoint(x: ((target.width - drawSize.width) / 2).rounded(),
                         y: ((target.height - drawSize.height) / 2).rounded())

    guard let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
        bitsPerSample: 8, samplesPerPixel: 3,          // アルファ無し = 透過なし
        hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    background.setFill()
    NSRect(origin: .zero, size: target).fill()
    sourceRep.draw(in: NSRect(origin: origin, size: drawSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = canvas.representation(using: .png, properties: [:]) else { continue }
    let out = outputDir.appendingPathComponent(String(format: "%02d.png", index + 1))
    try? png.write(to: out)
    print("\(file.lastPathComponent) → \(out.lastPathComponent) "
          + "(元 \(Int(sourceSize.width))×\(Int(sourceSize.height)) → 2880×1800)")
}

print("\n完了: \(outputDir.path)")
