import CoreImage
import Foundation
import UIKit

/// One offline branding hook shared by every CareThread PDF export.
///
/// The public product site is the single QR destination shared by every
/// exported PDF. Keeping the URL here prevents renderer-specific drift.
enum CareThreadPDFBranding {
    static let productName = "CareThread"
    static let tagline = "把家人的病程资料，安全地串成一条线。"
    static let officialWebsiteURL = URL(
        string: "https://carethread.8xd.io/"
    )!

    static let headerHeight: CGFloat = 30
    static let standardClosingHeight: CGFloat = 78

    /// UIKit renderer bridge for the same semantic token used by SwiftUI.
    private static let brandColor = UIColor(CT.Color.primary)

    static func drawHeader(in rect: CGRect) {
        guard rect.width > 0, rect.height >= headerHeight else { return }
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        defer { context?.restoreGState() }

        drawDivider(
            from: CGPoint(x: rect.minX, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.minY)
        )

        let logoSide: CGFloat = 18
        let logoRect = CGRect(
            x: rect.minX,
            y: rect.minY + 6,
            width: logoSide,
            height: logoSide
        )
        drawLogo(in: logoRect)
        drawText(
            productName,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: brandColor,
            rect: CGRect(
                x: logoRect.maxX + 7,
                y: rect.minY + 7,
                width: rect.width - logoSide - 7,
                height: 16
            )
        )
    }

    static func drawClosingBlock(in rect: CGRect) {
        guard rect.width > 0, rect.height >= 42 else { return }
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        defer { context?.restoreGState() }

        drawDivider(
            from: CGPoint(x: rect.minX, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.minY)
        )

        let isCompact = rect.height < standardClosingHeight
        let innerTop = rect.minY + (isCompact ? 6 : 9)
        // Keep even the one-page preparation card QR large enough to survive
        // PDF rasterisation, sharing-app recompression, and print scanning.
        let qrSide = min(isCompact ? 48 : 52, rect.height - 12)
        let qrRect = CGRect(
            x: rect.maxX - qrSide,
            y: innerTop,
            width: qrSide,
            height: qrSide
        )
        if let qrCode = makeQRCode(side: qrSide) {
            qrCode.draw(in: qrRect)
        }

        let logoSide = min(32, rect.height - 12)
        let logoRect = CGRect(
            x: rect.minX,
            y: innerTop,
            width: logoSide,
            height: logoSide
        )
        drawLogo(in: logoRect)

        let copyX = logoRect.maxX + 8
        let copyWidth = max(0, qrRect.minX - copyX - 10)
        drawText(
            productName,
            font: .systemFont(
                ofSize: isCompact ? 11 : 13,
                weight: .bold
            ),
            color: brandColor,
            rect: CGRect(
                x: copyX,
                y: innerTop,
                width: copyWidth,
                height: isCompact ? 15 : 18
            )
        )
        drawText(
            tagline,
            font: .systemFont(
                ofSize: isCompact ? 7 : 8.5,
                weight: .regular
            ),
            color: .darkGray,
            rect: CGRect(
                x: copyX,
                y: innerTop + (isCompact ? 15 : 18),
                width: copyWidth,
                height: isCompact ? 11 : 26
            )
        )
        drawText(
            "扫码访问官网",
            font: .systemFont(
                ofSize: isCompact ? 6.5 : 7.5,
                weight: .regular
            ),
            color: .darkGray,
            rect: CGRect(
                x: copyX,
                y: isCompact
                    ? innerTop + 28
                    : min(rect.maxY - 13, innerTop + 44),
                width: copyWidth,
                height: isCompact ? 10 : 12
            )
        )
    }

    static func makeQRCode(
        payload: String = officialWebsiteURL.absoluteString,
        side: CGFloat = 160
    ) -> UIImage? {
        guard side > 0,
              let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = max(1, floor(side / output.extent.width))
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let context = CIContext(options: [
            .useSoftwareRenderer: true
        ])
        guard let image = context.createCGImage(
            transformed,
            from: transformed.extent
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private static func drawLogo(in rect: CGRect) {
        if let logo = UIImage(named: "BrandLogo") {
            logo.draw(in: rect)
            return
        }
        let symbol = UIImage(
            systemName: "point.3.connected.trianglepath.dotted"
        )?.withTintColor(brandColor, renderingMode: .alwaysOriginal)
        symbol?.draw(in: rect)
    }

    private static func drawDivider(
        from start: CGPoint,
        to end: CGPoint
    ) {
        brandColor.setStroke()
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        path.lineWidth = 1
        path.stroke()
    }

    private static func drawText(
        _ text: String,
        font: UIFont,
        color: UIColor,
        rect: CGRect
    ) {
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .foregroundColor: color
            ],
            context: nil
        )
    }
}
