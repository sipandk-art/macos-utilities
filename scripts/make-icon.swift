#!/usr/bin/env swift
//
// make-icon.swift — рисует иконку приложения и собирает AppIcon.icns.
// Запуск: swift scripts/make-icon.swift
//
// Иконка рисуется кодом, а не картинкой: так она чёткая на любом размере
// и её видно в диффе — правится параметрами, а не переэкспортом из редактора.

import AppKit

let size: CGFloat = 1024
let outDir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render() -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    // Скруглённый квадрат по пропорциям иконок macOS: поле ~10 %, радиус ~22 %.
    let inset = size * 0.098
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.24, green: 0.80, blue: 0.78, alpha: 1).cgColor,   // бирюза сверху
        NSColor(srgbRed: 0.04, green: 0.48, blue: 0.55, alpha: 1).cgColor,   // глубокая бирюза снизу
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
    // Блик по верхней кромке — материал ловит свет. Именно градиент, а не
    // залитый прямоугольник: заливка оставляла видимую горизонтальную границу.
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.16).cgColor,
                                    NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Символ инструмента поверх — из системного набора SF Symbols.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "wrench.adjustable.fill",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        // Символ раскрашивается заливкой поверх собственной формы: у шаблонного
        // изображения своего цвета нет, а set() на общий контекст не действует.
        let s = symbol.size
        let white = NSImage(size: s)
        white.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSColor.white.set()
        NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
        white.unlockFocus()
        white.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
                              width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()
    return image
}

let master = render()

// iconutil ждёт набор конкретных размеров, включая @2x.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in variants {
    let target = NSImage(size: NSSize(width: px, height: px))
    target.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                from: .zero, operation: .copy, fraction: 1.0)
    target.unlockFocus()

    guard let tiff = target.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("не удалось отрисовать \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent("\(name).png"))
}

print("iconset готов: \(outDir.path)")
