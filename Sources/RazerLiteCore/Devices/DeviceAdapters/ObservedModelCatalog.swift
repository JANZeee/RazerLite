import Foundation

/// Small, passive identity records absent from the pinned upstream catalog.
/// Never referenced by transport, protocol selection or device-write authorization.
public enum ObservedModelCatalog {
    public static let entries: [RazerModelReference] = [
        .init(productID: 0x02F5, name: "Razer Reclusa Mini 65%", kind: .keyboard, source: .localObservation)
    ]

    public static func lookup(_ device: DeviceInfo) -> RazerModelReference? {
        guard !device.isVirtual, !device.interfaces.isEmpty,
              let entry = entries.first(where: { $0.productID == device.productID }),
              device.interfaces.allSatisfy({
                  $0.vendorID == 0x1532 && $0.productID == entry.productID && $0.transport == "USB"
                      && $0.product.trimmingCharacters(in: .whitespacesAndNewlines)
                          .caseInsensitiveCompare(entry.name) == .orderedSame
              }),
              device.interfaces.contains(where: {
                  ($0.primaryUsagePage == 1 && $0.primaryUsage == 6)
                      || $0.usages.contains(HIDUsage(page: 1, usage: 6))
              }) else { return nil }
        return entry
    }
}
