import DocumentModel

private let lower16 = 0xffff
private let factor16 = 65536 // 2^16

private func makeRecover(_ index: Int, _ offset: Int) -> Int { index + offset * factor16 }
private func recoverIndex(_ value: Int) -> Int { value & lower16 }
private func recoverOffset(_ value: Int) -> Int { (value - (value & lower16)) / factor16 }

private let DEL_BEFORE = 1, DEL_AFTER = 2, DEL_ACROSS = 4, DEL_SIDE = 8

/// The result of mapping a position through a step map / mapping. It can
/// report whether the content on either side of the position was deleted.
public struct MapResult {
    /// The mapped version of the position.
    public let pos: Int
    let delInfo: Int
    let recover: Int?

    init(_ pos: Int, _ delInfo: Int = 0, _ recover: Int? = nil) {
        self.pos = pos
        self.delInfo = delInfo
        self.recover = recover
    }

    /// Tells whether the side of the position that was at the position is gone.
    public var deleted: Bool { (delInfo & DEL_SIDE) > 0 }
    public var deletedBefore: Bool { (delInfo & (DEL_BEFORE | DEL_ACROSS)) > 0 }
    public var deletedAfter: Bool { (delInfo & (DEL_AFTER | DEL_ACROSS)) > 0 }
    public var deletedAcross: Bool { (delInfo & DEL_ACROSS) > 0 }
}

/// Something that can map a position, used as the abstraction for both
/// `StepMap` and `Mapping`.
public protocol Mappable {
    func map(_ pos: Int, _ assoc: Int) -> Int
    func mapResult(_ pos: Int, _ assoc: Int) -> MapResult
}

public extension Mappable {
    func map(_ pos: Int) -> Int { map(pos, 1) }
    func mapResult(_ pos: Int) -> MapResult { mapResult(pos, 1) }
}

/// A map describing the deletions and insertions made by a step, which can be
/// used to find the correspondence between positions in the pre-step version
/// of a document and the same position in the post-step version.
public final class StepMap: Mappable, @unchecked Sendable {
    let ranges: [Int]
    let inverted: Bool

    public init(_ ranges: [Int], inverted: Bool = false) {
        self.ranges = ranges
        self.inverted = inverted
    }

    /// A StepMap that contains no changed ranges.
    public static let empty = StepMap([])

    func recover(_ value: Int) -> Int {
        var diff = 0
        let index = recoverIndex(value)
        if !inverted {
            for i in 0..<index { diff += ranges[i * 3 + 2] - ranges[i * 3 + 1] }
        }
        return ranges[index * 3] + diff + recoverOffset(value)
    }

    public func mapResult(_ pos: Int, _ assoc: Int = 1) -> MapResult {
        let (p, info, rec) = _map(pos, assoc)
        return MapResult(p, info, rec)
    }

    public func map(_ pos: Int, _ assoc: Int = 1) -> Int {
        _map(pos, assoc).0
    }

    private func _map(_ pos: Int, _ assoc: Int) -> (Int, Int, Int?) {
        var diff = 0
        let oldIndex = inverted ? 2 : 1
        let newIndex = inverted ? 1 : 2
        var i = 0
        while i < ranges.count {
            let start = ranges[i] - (inverted ? diff : 0)
            if start > pos { break }
            let oldSize = ranges[i + oldIndex]
            let newSize = ranges[i + newIndex]
            let end = start + oldSize
            if pos <= end {
                let side = oldSize == 0 ? assoc : (pos == start ? -1 : (pos == end ? 1 : assoc))
                let result = start + diff + (side < 0 ? 0 : newSize)
                let recover = pos == (assoc < 0 ? start : end) ? nil : makeRecover(i / 3, pos - start)
                var del = pos == start ? DEL_AFTER : (pos == end ? DEL_BEFORE : DEL_ACROSS)
                if assoc < 0 ? pos != start : pos != end { del |= DEL_SIDE }
                return (result, del, recover)
            }
            diff += newSize - oldSize
            i += 3
        }
        return (pos + diff, 0, nil)
    }

    public func invert() -> StepMap { StepMap(ranges, inverted: !inverted) }

    public func forEach(_ f: (_ oldStart: Int, _ oldEnd: Int, _ newStart: Int, _ newEnd: Int) -> Void) {
        let oldIndex = inverted ? 2 : 1
        let newIndex = inverted ? 1 : 2
        var i = 0
        var diff = 0
        while i < ranges.count {
            let start = ranges[i]
            let oldStart = start - (inverted ? diff : 0)
            let newStart = start + (inverted ? 0 : diff)
            let oldSize = ranges[i + oldIndex]
            let newSize = ranges[i + newIndex]
            f(oldStart, oldStart + oldSize, newStart, newStart + newSize)
            diff += newSize - oldSize
            i += 3
        }
    }
}

/// A mapping represents a pipeline of zero or more step maps. It has special
/// provisions for losslessly handling mapping positions through a series of
/// steps in which some steps are inverted versions of earlier steps.
public final class Mapping: Mappable, @unchecked Sendable {
    public private(set) var maps: [StepMap]
    public var from: Int
    public var to: Int
    private var mirror: [Int]?

    public init(maps: [StepMap] = [], mirror: [Int]? = nil, from: Int = 0, to: Int? = nil) {
        self.maps = maps
        self.mirror = mirror
        self.from = from
        self.to = to ?? maps.count
    }

    public func slice(_ from: Int = 0, _ to: Int? = nil) -> Mapping {
        Mapping(maps: maps, mirror: mirror, from: from, to: to ?? maps.count)
    }

    public func appendMap(_ map: StepMap, _ mirrors: Int? = nil) {
        maps.append(map)
        to = maps.count
        if let mirrors { setMirror(maps.count - 1, mirrors) }
    }

    public func appendMapping(_ mapping: Mapping) {
        let startSize = maps.count
        for i in 0..<mapping.maps.count {
            let mirr = mapping.getMirror(i)
            appendMap(mapping.maps[i], mirr != nil && mirr! < i ? startSize + mirr! : nil)
        }
    }

    public func getMirror(_ n: Int) -> Int? {
        guard let mirror else { return nil }
        var i = 0
        while i < mirror.count {
            if mirror[i] == n { return mirror[i + 1] }
            if mirror[i + 1] == n { return mirror[i] }
            i += 2
        }
        return nil
    }

    public func setMirror(_ n: Int, _ m: Int) {
        if mirror == nil { mirror = [] }
        mirror!.append(n)
        mirror!.append(m)
    }

    public func appendMappingInverted(_ mapping: Mapping) {
        var i = mapping.maps.count - 1
        let totalSize = maps.count + mapping.maps.count
        while i >= 0 {
            let mirr = mapping.getMirror(i)
            appendMap(mapping.maps[i].invert(), mirr != nil && mirr! > i ? totalSize - mirr! - 1 : nil)
            i -= 1
        }
    }

    public func invert() -> Mapping {
        let inverse = Mapping()
        inverse.appendMappingInverted(self)
        return inverse
    }

    public func map(_ pos: Int, _ assoc: Int = 1) -> Int {
        if mirror != nil { return _map(pos, assoc, true).0 }
        var pos = pos
        var i = from
        while i < to {
            pos = maps[i].map(pos, assoc)
            i += 1
        }
        return pos
    }

    public func mapResult(_ pos: Int, _ assoc: Int = 1) -> MapResult {
        let (p, info) = _map(pos, assoc, false)
        return MapResult(p, info, nil)
    }

    private func _map(_ pos: Int, _ assoc: Int, _ simple: Bool) -> (Int, Int) {
        var delInfo = 0
        var pos = pos
        var i = from
        while i < to {
            let map = maps[i]
            let result = map.mapResult(pos, assoc)
            if let rec = result.recover {
                if let corr = getMirror(i), corr > i, corr < to {
                    i = corr
                    pos = maps[corr].recover(rec)
                    i += 1
                    continue
                }
            }
            delInfo |= result.delInfo
            pos = result.pos
            i += 1
        }
        return (pos, delInfo)
    }
}
