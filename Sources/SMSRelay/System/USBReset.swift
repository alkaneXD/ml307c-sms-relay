import Foundation
import IOKit
import IOKit.usb

/// Software equivalent of unplugging and re-plugging a USB device.
///
/// After a firmware reset (`AT+CFUN=1,1`) the ML307's CDC ports can stay enumerated while
/// the AT service behind them is dead. `USBDeviceReEnumerate` tears the device down and
/// brings it back — verified to recover exactly that state without touching the cable.
enum USBReset {
    enum Failure: Error, LocalizedError {
        case notFound
        case iokit(String, Int32)

        var errorDescription: String? {
            switch self {
            case .notFound: return "USB device not found"
            case .iokit(let step, let kr): return "\(step) failed (0x\(String(kr, radix: 16)))"
            }
        }
    }

    /// Re-enumerates every device matching the vendor ID (and product ID when given). Returns how many.
    @discardableResult
    static func reenumerate(vendorID: Int, productID: Int? = nil) throws -> Int {
        let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matching[kUSBVendorID] = vendorID
        if let productID { matching[kUSBProductID] = productID }

        var iterator: io_iterator_t = 0
        let mr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard mr == KERN_SUCCESS else { throw Failure.iokit("IOServiceGetMatchingServices", mr) }
        defer { IOObjectRelease(iterator) }

        var count = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            try reenumerate(service: service)
            count += 1
            service = IOIteratorNext(iterator)
        }
        guard count > 0 else { throw Failure.notFound }
        return count
    }

    /// Re-enumerates only the USB device that owns a given callout device
    /// (e.g. /dev/cu.usbmodem…123), so resetting one modem never disturbs another.
    @discardableResult
    static func reenumerateDevice(forCalloutPath path: String) throws -> Bool {
        // Find the IOSerialBSDClient whose callout device matches, then walk up to its USB device.
        let matching = IOServiceMatching("IOSerialBSDClient") as NSMutableDictionary
        matching["IOCalloutDevice"] = path
        let serial: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard serial != 0 else { throw Failure.notFound }
        defer { IOObjectRelease(serial) }

        var entry = serial
        IOObjectRetain(entry)  // balance the release in the loop for the first hop
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 || IOObjectConformsTo(entry, "IOUSBDevice") != 0 {
                defer { IOObjectRelease(entry) }
                try reenumerate(service: entry)
                return true
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS else { break }
            entry = parent
        }
        return false
    }

    private static func reenumerate(service: io_service_t) throws {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let pr = IOCreatePlugInInterfaceForService(service, deviceUserClientTypeID, cfPlugInInterfaceID, &plugin, &score)
        guard pr == KERN_SUCCESS, let plugin, let pluginVTable = plugin.pointee?.pointee else {
            throw Failure.iokit("IOCreatePlugInInterfaceForService", pr)
        }
        defer { _ = pluginVTable.Release(plugin) }

        var raw: UnsafeMutableRawPointer?
        let qr = pluginVTable.QueryInterface(plugin, CFUUIDGetUUIDBytes(deviceInterfaceID), &raw)
        guard qr == 0, let raw else { throw Failure.iokit("QueryInterface", Int32(qr)) }
        let device = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
        guard let vtable = device.pointee?.pointee else { throw Failure.iokit("device vtable", -1) }
        defer { _ = vtable.Release(device) }

        let or = vtable.USBDeviceOpen(device)
        guard or == KERN_SUCCESS else { throw Failure.iokit("USBDeviceOpen", or) }
        let rr = vtable.USBDeviceReEnumerate(device, 0)
        _ = vtable.USBDeviceClose(device)
        guard rr == KERN_SUCCESS else { throw Failure.iokit("USBDeviceReEnumerate", rr) }
    }

    // The IOKit UUID macros are not importable from Swift; these are their byte values.
    private static let cfPlugInInterfaceID = uuid(0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let deviceUserClientTypeID = uuid(0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xd4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    private static let deviceInterfaceID = uuid(0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xd4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

    private static func uuid(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, _ b4: UInt8, _ b5: UInt8, _ b6: UInt8, _ b7: UInt8,
                             _ b8: UInt8, _ b9: UInt8, _ b10: UInt8, _ b11: UInt8, _ b12: UInt8, _ b13: UInt8, _ b14: UInt8, _ b15: UInt8) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(kCFAllocatorSystemDefault, b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15)
    }
}
