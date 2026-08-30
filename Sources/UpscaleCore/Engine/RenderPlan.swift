import Foundation

/// A pixel size, kept as integers once the shader expressions have been evaluated.
public struct PixelSize: Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
}

/// One enabled shader stage, with its textures resolved to plan slots.
public struct PlannedPass {
    public let stage: MPVShaderStage
    /// Slot ids for the stage's bound textures, in binding order.
    public let inputSlots: [Int]
    public let outputSlot: Int
    public let size: PixelSize
}

/// The full chain for one preset at one input/target size.
///
/// A "slot" is one produced texture value. Because a pass may write a name it also
/// reads (`//!BIND MAIN` with `//!SAVE MAIN`), names are rebound to fresh slots rather
/// than written in place, exactly as mpv allocates a new FBO per pass.
public struct RenderPlan {
    /// Slot 0 is the caller's input texture; every other slot comes from the pool.
    public static let inputSlot = 0

    public let passes: [PlannedPass]
    public let slotSizes: [PixelSize]
    /// For each slot, the index of the last pass that reads it. `passes.count` means
    /// "still live at the end", which is true of the input and the final image.
    public let lastUse: [Int]
    /// The slot holding MAIN once the chain has run.
    public let finalSlot: Int
    public let inputSize: PixelSize
    public let targetSize: PixelSize

    public var finalSize: PixelSize { slotSizes[finalSlot] }
    /// True when the chain already lands on the target and no resampling is needed.
    public var producesTargetSize: Bool { finalSize == targetSize }

    /// Builds the chain: evaluates `//!WHEN`, resolves sizes, and tracks liveness.
    ///
    /// Stages are visited in hook-point order — every MAIN pass, then every PREKERNEL
    /// pass — which is what makes Clamp_Highlights work: it measures highlights where
    /// it sits in the file and clamps at the very end, as mpv does.
    public static func build(
        stages: [MPVShaderStage],
        inputSize: PixelSize,
        targetSize: PixelSize
    ) throws -> RenderPlan {
        var environment = SizeEnvironment()
        environment.set("NATIVE", width: Float(inputSize.width), height: Float(inputSize.height))
        environment.set("MAIN", width: Float(inputSize.width), height: Float(inputSize.height))
        environment.set("OUTPUT", width: Float(targetSize.width), height: Float(targetSize.height))

        var slotSizes: [PixelSize] = [inputSize]
        var binding: [String: Int] = ["MAIN": inputSlot, "NATIVE": inputSlot]
        var passes: [PlannedPass] = []

        let ordered = stages.enumerated().sorted { left, right in
            if left.element.hook.executionOrder != right.element.hook.executionOrder {
                return left.element.hook.executionOrder < right.element.hook.executionOrder
            }
            return left.offset < right.offset
        }.map(\.element)

        for stage in ordered {
            environment.set("HOOKED", to: stage.hook.textureName)

            if let when = stage.when, try when.evaluate(in: environment) == 0 {
                continue
            }
            guard let hookedSize = environment["HOOKED"] else {
                throw ShaderError.unknownTexture(stage.hook.textureName, stage: stage.name)
            }

            let width = try stage.width.map { try $0.evaluate(in: environment) } ?? hookedSize.width
            let height = try stage.height.map { try $0.evaluate(in: environment) } ?? hookedSize.height
            let size = PixelSize(
                width: max(1, Int(width.rounded())),
                height: max(1, Int(height.rounded()))
            )

            let inputSlots = try stage.inputTextures.map { name -> Int in
                let resolved = name == "HOOKED" ? stage.hook.textureName : name
                guard let slot = binding[resolved] else {
                    throw ShaderError.unknownTexture(resolved, stage: stage.name)
                }
                return slot
            }

            let outputSlot = slotSizes.count
            slotSizes.append(size)
            passes.append(
                PlannedPass(stage: stage, inputSlots: inputSlots, outputSlot: outputSlot, size: size)
            )

            let destination = stage.destinationTexture
            binding[destination] = outputSlot
            environment.set(destination, width: Float(size.width), height: Float(size.height))
        }

        guard !passes.isEmpty else {
            throw EngineError.emptyChain(preset: stages.first?.sourceFile ?? "unknown")
        }

        var lastUse = [Int](repeating: -1, count: slotSizes.count)
        for (index, pass) in passes.enumerated() {
            for slot in pass.inputSlots {
                lastUse[slot] = index
            }
            lastUse[pass.outputSlot] = max(lastUse[pass.outputSlot], index)
        }
        let finalSlot = binding["MAIN"] ?? inputSlot
        // The input belongs to the caller and the final image is read after the last
        // pass, so neither may be recycled mid-chain.
        lastUse[inputSlot] = passes.count
        lastUse[finalSlot] = passes.count

        return RenderPlan(
            passes: passes,
            slotSizes: slotSizes,
            lastUse: lastUse,
            finalSlot: finalSlot,
            inputSize: inputSize,
            targetSize: targetSize
        )
    }
}
