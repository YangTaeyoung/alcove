import Foundation
import IOKit
import Observation
import AlcoveEngine

/// Host USB devices, enumerated from the I/O Registry and kept current
/// through IOKit matching notifications. Feeds the passthrough menus.
///
/// Property keys are the IOUSBHostFamily registry keys
/// (`IOKit/usb/IOUSBHostFamilyDefinitions.h`).
@MainActor @Observable
final class USBDeviceList {
    struct Device: Identifiable, Hashable, Sendable {
        let vendorID: Int
        let productID: Int
        let vendorName: String?
        let productName: String?
        let serial: String?
        /// USB topology location (`locationID`); distinguishes identical devices.
        let locationID: Int?

        var id: String { String(format: "%04x:%04x@%08x", vendorID, productID, locationID ?? 0) }

        var displayName: String {
            if let productName, !productName.isEmpty { return productName }
            if let vendorName, !vendorName.isEmpty { return vendorName }
            return String(format: "USB device %04X:%04X", vendorID, productID)
        }

        var detail: String {
            var parts = [String(format: "%04X:%04X", vendorID, productID)]
            if let vendorName, !vendorName.isEmpty, vendorName != productName { parts.append(vendorName) }
            if let serial, !serial.isEmpty { parts.append("S/N \(serial)") }
            return parts.joined(separator: " · ")
        }

        var selector: VMConfig.USBSelector {
            VMConfig.USBSelector(vendorID: vendorID, productID: productID, name: displayName)
        }
    }

    private(set) var devices: [Device] = []
    /// Set when enumeration or notification setup fails.
    private(set) var lastError: String?

    @ObservationIgnored private var notifyPort: IONotificationPortRef?
    @ObservationIgnored private var addedIterator: io_iterator_t = 0
    @ObservationIgnored private var removedIterator: io_iterator_t = 0

    // IOUSBHostFamilyDefinitions.h
    private static let deviceClassName = "IOUSBHostDevice"          // kIOUSBHostDeviceClassName
    private static let vendorIDKey = "idVendor"                     // kUSBHostMatchingPropertyVendorID
    private static let productIDKey = "idProduct"                   // kUSBHostMatchingPropertyProductID
    private static let deviceClassKey = "bDeviceClass"              // kUSBHostMatchingPropertyDeviceClass
    private static let vendorStringKey = "kUSBVendorString"         // kUSBHostDevicePropertyVendorString
    private static let productStringKey = "kUSBProductString"       // kUSBHostDevicePropertyProductString
    private static let serialStringKey = "kUSBSerialNumberString"   // kUSBHostDevicePropertySerialNumberString
    private static let locationIDKey = "locationID"                 // kUSBHostPropertyLocationID
    private static let hubDeviceClass = 9

    init() {}

    /// Enumerate now. Hubs are skipped (they cannot be passed through).
    func refresh() {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(USBDeviceList.deviceClassName), &iterator)
        guard result == KERN_SUCCESS else {
            lastError = "IOServiceGetMatchingServices failed (\(result))"
            return
        }
        defer { IOObjectRelease(iterator) }
        var found: [Device] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let device = USBDeviceList.device(from: service) { found.append(device) }
        }
        devices = found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        lastError = nil
    }

    /// Install add/remove notifications (delivered on the main queue) and refresh.
    func startWatching() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            lastError = "IONotificationPortCreate failed"
            refresh()
            return
        }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(USBDeviceList.deviceClassName),
                                                     usbDeviceListNotification, refcon, &addedIterator)
        if added == KERN_SUCCESS { USBDeviceList.drain(addedIterator) } else { lastError = "USB add notification failed (\(added))" }
        let removed = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching(USBDeviceList.deviceClassName),
                                                       usbDeviceListNotification, refcon, &removedIterator)
        if removed == KERN_SUCCESS { USBDeviceList.drain(removedIterator) } else { lastError = "USB remove notification failed (\(removed))" }
        refresh()
    }

    /// Remove the notifications. The list keeps its last contents.
    func stopWatching() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    // MARK: - internals

    /// Consume every object in a notification iterator; this arms (or re-arms) it.
    nonisolated fileprivate static func drain(_ iterator: io_iterator_t) {
        while true {
            let object = IOIteratorNext(iterator)
            guard object != 0 else { return }
            IOObjectRelease(object)
        }
    }

    private static func property(_ key: String, of service: io_service_t) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func device(from service: io_service_t) -> Device? {
        guard let vendorID = property(vendorIDKey, of: service) as? Int,
              let productID = property(productIDKey, of: service) as? Int else { return nil }
        if let deviceClass = property(deviceClassKey, of: service) as? Int, deviceClass == hubDeviceClass { return nil }
        return Device(vendorID: vendorID, productID: productID,
                      vendorName: property(vendorStringKey, of: service) as? String,
                      productName: property(productStringKey, of: service) as? String,
                      serial: property(serialStringKey, of: service) as? String,
                      locationID: property(locationIDKey, of: service) as? Int)
    }
}

/// `IOServiceMatchingCallback`: runs on the main queue (see `startWatching`).
private func usbDeviceListNotification(refcon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    USBDeviceList.drain(iterator)
    guard let refcon else { return }
    let list = Unmanaged<USBDeviceList>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { list.refresh() }
}
