import Metal
import Testing
@testable import LSFGCore

@Test func kernelsFromHostBuiltPipelines() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let library = try device.makeLibrary(source: "kernel void lsfg_1(uint2 id [[thread_position_in_grid]]) {}", options: nil)
    let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "lsfg_1")))
    let size = MTLSize(width: 8, height: 8, depth: 1)

    let kernels = LSFGKernels(device: device, kernels: [1: .init(pipeline: pipeline, threadgroupSize: size)])

    #expect(kernels[1].pipeline === pipeline)
    #expect(kernels[1].threadgroupSize.width == 8)
}
