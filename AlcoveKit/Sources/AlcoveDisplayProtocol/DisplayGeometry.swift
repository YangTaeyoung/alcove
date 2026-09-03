import CoreGraphics
import Foundation

/// Pure geometry for presenting a guest surface inside a host view and for
/// translating host pointer positions into the guest's absolute coordinate
/// space (`ToQEMU.abs`, 0...32767 on both axes).
///
/// Every function works in whatever unit the caller passes (points or
/// pixels); only ratios matter, so results are independent of the backing
/// scale factor as long as `viewPoint` and `viewSize` share a unit.
public enum DisplayGeometry: Sendable {
    /// The last absolute coordinate on each axis (`ToQEMU.absoluteMax`).
    public static let absoluteMax = ToQEMU.absoluteMax

    /// The largest rectangle with `surface`'s aspect ratio that fits inside a
    /// `view`-sized area, centered (letterboxed or pillarboxed as needed).
    ///
    /// Returns `.zero` when either size has a non-positive dimension.
    public static func aspectFitRect(surface: CGSize, in view: CGSize) -> CGRect {
        guard surface.width > 0, surface.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let scale = min(view.width / surface.width, view.height / surface.height)
        let size = CGSize(width: surface.width * scale, height: surface.height * scale)
        let origin = CGPoint(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    /// Map a point in view coordinates to guest absolute coordinates.
    ///
    /// - Parameters:
    ///   - viewPoint: The pointer location in the view's coordinate system.
    ///   - viewSize: The view's size in the same unit as `viewPoint`.
    ///   - surface: The guest surface size (pixels); only its aspect ratio is used.
    ///   - flippedY: `true` when the view's origin is at the top-left (AppKit
    ///     `isFlipped`), `false` for the AppKit default (origin at bottom-left).
    ///   - clampToSurface: When `true`, points outside the fitted rectangle are
    ///     clamped to its nearest edge instead of yielding `nil` (used while a
    ///     button is held so drags that leave the view keep tracking).
    /// - Returns: Coordinates in `0...absoluteMax`, with the fitted rectangle's
    ///   corners mapping exactly to `0` and `absoluteMax`; `nil` when the point
    ///   lies outside the fitted rectangle (and clamping is off) or when the
    ///   geometry is degenerate.
    public static func guestPoint(from viewPoint: CGPoint, viewSize: CGSize, surface: CGSize,
                                  flippedY: Bool, clampToSurface: Bool = false) -> (x: Int, y: Int)? {
        let rect = aspectFitRect(surface: surface, in: viewSize)
        guard rect.width > 0, rect.height > 0 else { return nil }
        // Normalise to a top-left origin so the guest's y axis (downwards) matches.
        let px = viewPoint.x
        let py = flippedY ? viewPoint.y : (viewSize.height - viewPoint.y)
        let inside = px >= rect.minX && px <= rect.maxX && py >= rect.minY && py <= rect.maxY
        guard inside || clampToSurface else { return nil }
        let cx = min(max(px, rect.minX), rect.maxX)
        let cy = min(max(py, rect.minY), rect.maxY)
        let fx = (cx - rect.minX) / rect.width
        let fy = (cy - rect.minY) / rect.height
        let range = CGFloat(absoluteMax)
        let gx = Int((fx * range).rounded())
        let gy = Int((fy * range).rounded())
        return (min(max(gx, 0), absoluteMax), min(max(gy, 0), absoluteMax))
    }
}
