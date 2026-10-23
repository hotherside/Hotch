import Foundation
import Darwin

/// Activity Monitor style memory breakdown, pressure and swap. sysctl MIBs are
/// resolved once: a by-name lookup costs ~40 us from a cold wake, a MIB ~4 us.
final class MemoryReader {
    private let totalBytes: UInt64
    private let pageSize: UInt64
    private var pressureMib = SysCtl.Mib("kern.memorystatus_vm_pressure_level")
    private var levelMib = SysCtl.Mib("kern.memorystatus_level")
    private var swapMib = SysCtl.Mib("vm.swapusage")

    init() {
        totalBytes = SysCtl.uint64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory
        var size: vm_size_t = 0
        pageSize = host_page_size(mach_host_self(), &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : 16_384
    }

    func read() -> MemoryReading {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pg = pageSize
        func pages(_ n: UInt64) -> UInt64 { n.multipliedReportingOverflow(by: pg).partialValue }
        var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0, free: UInt64 = 0
        if kr == KERN_SUCCESS {
            let anon = UInt64(s.internal_page_count), purgeable = UInt64(s.purgeable_count)
            app = pages(anon > purgeable ? anon - purgeable : 0)
            wired = pages(UInt64(s.wire_count))
            compressed = pages(UInt64(s.compressor_page_count))
            cached = pages(UInt64(s.external_page_count) + purgeable)
            let fc = UInt64(s.free_count), sc = UInt64(s.speculative_count)
            free = pages(fc > sc ? fc - sc : 0)
        }
        let used = min(totalBytes, app + wired + compressed)

        var level: Int32 = 1
        if !pressureMib.read(&level) { level = 1 }
        let pressure: MemoryPressure = level >= 4 ? .critical : (level == 2 ? .warning : .normal)
        var availableLevel: Int32 = -1
        let available: Double? = levelMib.read(&availableLevel) && availableLevel >= 0 ? Double(min(100, availableLevel)) : nil
        let pressurePercent = available.map { 100 - $0 } ?? (totalBytes > 0 ? Double(used) / Double(totalBytes) * 100 : 0)

        var swap = xsw_usage()
        if !swapMib.read(&swap) { swap = xsw_usage() }

        return MemoryReading(totalBytes: totalBytes, usedBytes: used, appBytes: app, wiredBytes: wired,
                             compressedBytes: compressed, cachedBytes: cached, freeBytes: free,
                             pressure: pressure, pressurePercent: pressurePercent,
                             swapUsedBytes: swap.xsu_used, swapTotalBytes: swap.xsu_total)
    }
}
