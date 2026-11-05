import Foundation
import Testing
@testable import LSFGCore

@Test func sentinelsRoundTripAndStayExactInHalf() {
    for j in 0...DXBCConstants.maxSentinels {
        let v = DXBCConstants.sentinel(j)
        #expect(Float(Float16(v)) == v)
        #expect(DXBCConstants.sentinelIndex(v) == j)
    }
    // compiler-made constants never read as sentinels
    for v: Float in [0, 0.5, 1, 2, -1, 255, 1024, 4095.5, 70000] { #expect(DXBCConstants.sentinelIndex(v) == nil) }
}

@Test func halfConversionMatchesDXBCSpirv() {
    // dxbc-spirv truncates (util::f32tof16): these round up to nearest but come out one step lower
    #expect(DXBCConstants.halfTowardZero(0.45454547) == Float16(0.45454547).bitPattern - 1)
    #expect(DXBCConstants.halfTowardZero(-0.299) == Float16(-0.299).bitPattern - 1)
    #expect(DXBCConstants.halfTowardZero(0.5) == Float16(0.5).bitPattern)
    #expect(DXBCConstants.halfTowardZero(1e6) == 0x7BFF)   // largest finite, not infinity
    #expect(DXBCConstants.halfTowardZero(1e-9) == 0)
    for h: UInt16 in [0, 1, 0x3C00, 0xBC00, 0x7BFF, 0x3555, 0x8001] {
        #expect(SPIRVConstants.Constant(kind: .half, bits: UInt32(h)).value == Float(Float16(bitPattern: h)))
    }
}
