import Foundation

/// Admission only: never cancels an accepted turn or blocks confirmed-file recovery.
struct CloudMemoryAdmission {
    let testAvailableMiB: Int?
    let testCurrentMiB: Int?
    func rejection() -> CloudError? {
        let available=testAvailableMiB.map {Int64($0)*1_048_576} ?? Self.availableBytes()
        let current=testCurrentMiB.map {Int64($0)*1_048_576} ?? Self.cgroupBytes()
        if let available,available < 350*1_048_576 {return Self.pressure}
        if let current,current >= 280*1_048_576 {return Self.pressure}
        return nil
    }
    private static var pressure: CloudError {CloudError(503,"memory_pressure","云服务器当前可用内存不足，暂未开始新模型回合。已有文件与草案仍可查看和确认，请稍后重试。")}
    private static func availableBytes() -> Int64? {
        #if os(Linux)
        guard let text=try? String(contentsOfFile:"/proc/meminfo",encoding:.utf8),let line=text.split(separator:"\n").first(where:{$0.hasPrefix("MemAvailable:")}) else {return nil}
        let fields=line.split(whereSeparator:{$0 == " " || $0 == "\t"})
        return fields.count >= 2 ? Int64(fields[1]).map {$0*1024}:nil
        #else
        return nil
        #endif
    }
    private static func cgroupBytes() -> Int64? {
        #if os(Linux)
        guard let membership=try? String(contentsOfFile:"/proc/self/cgroup",encoding:.utf8),let entry=membership.split(separator:"\n").first(where:{$0.hasPrefix("0::")}) else {return nil}
        let relative=String(entry.dropFirst(3)).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        let path=URL(fileURLWithPath:"/sys/fs/cgroup",isDirectory:true).appendingPathComponent(relative).appendingPathComponent("memory.current").path
        guard let text=try? String(contentsOfFile:path,encoding:.utf8) else {return nil}
        return Int64(text.trimmingCharacters(in:.whitespacesAndNewlines))
        #else
        return nil
        #endif
    }
}
