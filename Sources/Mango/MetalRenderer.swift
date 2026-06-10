import MetalKit

final class MetalRenderer: NSObject, MTKViewDelegate {
  static let nesWidth = 256
  static let nesHeight = 240

  let device: MTLDevice

  private let emulator: Emulator
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private let texture: MTLTexture

  init?(emulator: Emulator, device: MTLDevice) {
    self.emulator = emulator
    self.device = device

    guard let queue = device.makeCommandQueue()
    else { return nil }

    commandQueue = queue

    do {
      let library = try device.makeLibrary(source: Self.shaderSource, options: nil)

      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "nes_vertex")
      descriptor.fragmentFunction = library.makeFunction(name: "nes_fragment")
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

    } catch { return nil }

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: Self.nesWidth,
      height: Self.nesHeight,
      mipmapped: false
    )
    textureDescriptor.usage = .shaderRead

    guard let texture = device.makeTexture(descriptor: textureDescriptor)
    else { return nil }

    self.texture = texture

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .nearest
    samplerDescriptor.magFilter = .nearest
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge

    guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
    else { return nil }

    self.sampler = sampler

    super.init()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {

    // MTKView invokes this on the main thread, where the @MainActor emulator lives.
    let produced = MainActor.assumeIsolated { () -> Bool in
      emulator.advanceFrame()

      return emulator.withFramebuffer { pixels in

        texture.replace(
          region: MTLRegionMake2D(0, 0, Self.nesWidth, Self.nesHeight),
          mipmapLevel: 0,
          withBytes: pixels,
          bytesPerRow: Self.nesWidth * 4,
        )

        return true

      } ?? false
    }

    guard
      let drawable = view.currentDrawable,
      let passDescriptor = view.currentRenderPassDescriptor,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
    else { return }

    // If no content, still just clear to black
    if produced {
      encoder.setRenderPipelineState(pipeline)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  /// One fullscreen triangle (no vertex buffer); the fragment shader samples
  /// the frame texture. UV flips Y so framebuffer row 0 (top scanline) lands
  /// at the top of the screen.
  private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
      float4 position [[position]];
      float2 uv;
    };

    vertex VertexOut nes_vertex(uint vertexID [[vertex_id]]) {
      float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
      float2 p = corners[vertexID];

      VertexOut out;
      out.position = float4(p, 0.0, 1.0);
      out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);

      return out;
    }

    fragment float4 nes_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> frame [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
      return frame.sample(smp, in.uv);
    }
    """
}
