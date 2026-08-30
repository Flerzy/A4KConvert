import XCTest
@testable import UpscaleCore

final class ShaderParserTests: XCTestCase {
    /// A hand-written shader exercising every directive the translator understands.
    static let fixture = """
    // Licence header that must be ignored.
    // Another comment line.

    //!DESC Fixture Stage One
    //!HOOK MAIN
    //!BIND HOOKED
    //!BIND NATIVE
    //!SAVE STATSMAX
    //!COMPONENTS 1
    //!WIDTH MAIN.w 2 *
    //!HEIGHT MAIN.h 2 /
    //!WHEN OUTPUT.w MAIN.w / 1.200 >

    float helper(vec4 rgba) {
        return dot(vec4(0.299, 0.587, 0.114, 0.0), rgba);
    }

    vec4 hook() {
        return vec4(helper(HOOKED_texOff(vec2(0, 0))));
    }

    //!DESC Fixture Stage Two
    //!HOOK PREKERNEL
    //!BIND HOOKED
    //!BIND STATSMAX

    vec4 hook() {
        return HOOKED_tex(HOOKED_pos) - STATSMAX_tex(HOOKED_pos).x;
    }
    """

    func testParsesEveryDirectiveType() throws {
        let stages = try MPVShaderParser.parse(ShaderParserTests.fixture, fileName: "Fixture.glsl")
        XCTAssertEqual(stages.count, 2)

        let first = stages[0]
        XCTAssertEqual(first.name, "Fixture Stage One")
        XCTAssertEqual(first.hook, .main)
        XCTAssertEqual(first.binds, ["HOOKED", "NATIVE"])
        XCTAssertEqual(first.save, "STATSMAX")
        XCTAssertEqual(first.destinationTexture, "STATSMAX")
        XCTAssertEqual(first.components, 1)
        XCTAssertEqual(first.width?.tokens, ["MAIN.w", "2", "*"])
        XCTAssertEqual(first.height?.tokens, ["MAIN.h", "2", "/"])
        XCTAssertEqual(first.when?.tokens, ["OUTPUT.w", "MAIN.w", "/", "1.200", ">"])
        XCTAssertEqual(first.sourceFile, "Fixture.glsl")
        XCTAssertEqual(first.indexInFile, 0)
        // Licence comments are dropped; the two function bodies are kept.
        XCTAssertTrue(first.body.contains("vec4 hook() {"))
        XCTAssertTrue(first.body.contains("float helper(vec4 rgba) {"))
        XCTAssertFalse(first.body.contains { $0.hasPrefix("// Licence") })
        // MAIN is added implicitly because the stage hooks it without binding it.
        XCTAssertEqual(first.inputTextures, ["HOOKED", "NATIVE", "MAIN"])

        let second = stages[1]
        XCTAssertEqual(second.hook, .prekernel)
        XCTAssertNil(second.save)
        // No SAVE means the result goes back into the hooked texture.
        XCTAssertEqual(second.destinationTexture, "MAIN")
        XCTAssertNil(second.when)
        XCTAssertEqual(second.indexInFile, 1)
        // PREKERNEL does not get the implicit MAIN bind that a MAIN hook does.
        XCTAssertEqual(second.inputTextures, ["HOOKED", "STATSMAX"])
    }

    func testFunctionNamesAreUniqueWithinAFile() throws {
        let source = """
        //!DESC Same Name
        //!HOOK MAIN
        //!BIND MAIN
        vec4 hook() { return vec4(0.0); }
        //!DESC Same Name
        //!HOOK MAIN
        //!BIND MAIN
        vec4 hook() { return vec4(1.0); }
        """
        let stages = try MPVShaderParser.parse(source, fileName: "Dup.glsl")
        XCTAssertEqual(stages.count, 2)
        XCTAssertNotEqual(stages[0].functionName, stages[1].functionName)
        XCTAssertEqual(stages[0].functionName, "Same_Name_0")
    }

    func testUnknownDirectiveIsRejected() {
        let source = """
        //!DESC X
        //!HOOK MAIN
        //!NONSENSE 1
        vec4 hook() { return vec4(0.0); }
        """
        XCTAssertThrowsError(try MPVShaderParser.parse(source, fileName: "Bad.glsl")) { error in
            guard case let ShaderError.unknownDirective(directive, _) = error else {
                return XCTFail("expected unknownDirective, got \(error)")
            }
            XCTAssertEqual(directive, "NONSENSE")
        }
    }

    func testUnsupportedHookIsRejected() {
        let source = """
        //!DESC X
        //!HOOK LINEAR
        vec4 hook() { return vec4(0.0); }
        """
        XCTAssertThrowsError(try MPVShaderParser.parse(source, fileName: "Bad.glsl")) { error in
            guard case let ShaderError.unsupportedHook(hook, _) = error else {
                return XCTFail("expected unsupportedHook, got \(error)")
            }
            XCTAssertEqual(hook, "LINEAR")
        }
    }

    /// Metal has no variable-length arrays, so a SPATIAL_SIGMA-derived kernel size is
    /// folded into a literal while parsing.
    func testSpatialSigmaKernelSizeIsFoldedToALiteral() throws {
        let source = """
        //!DESC Sigma
        //!HOOK MAIN
        //!BIND MAIN
        #define SPATIAL_SIGMA 3.0 //Spatial sigma
        #define KERNELSIZE int(max(int(SPATIAL_SIGMA), 1) * 2 + 1)
        vec4 hook() { return vec4(0.0); }
        """
        let stages = try MPVShaderParser.parse(source, fileName: "Sigma.glsl")
        XCTAssertTrue(stages[0].body.contains("#define KERNELSIZE 7"), "\(stages[0].body)")
    }
}

final class RPNExpressionTests: XCTestCase {
    private func environment() -> SizeEnvironment {
        var environment = SizeEnvironment()
        environment.set("MAIN", width: 1920, height: 1080)
        environment.set("NATIVE", width: 1920, height: 1080)
        environment.set("OUTPUT", width: 3840, height: 2160)
        return environment
    }

    func testUpscaleGateIsTrueAtTwoTimes() throws {
        let when = RPNExpression("OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *")
        XCTAssertEqual(try when.evaluate(in: environment()), 1)
    }

    func testUpscaleGateIsFalseWhenAlreadyAtTarget() throws {
        var environment = self.environment()
        environment.set("MAIN", width: 3840, height: 2160)
        let when = RPNExpression("OUTPUT.w MAIN.w / 1.200 > OUTPUT.h MAIN.h / 1.200 > *")
        XCTAssertEqual(try when.evaluate(in: environment), 0)
    }

    /// AutoDownscalePre_x2 only fires between 1.2x and 2x of the native size.
    func testAutoDownscalePreX2Gate() throws {
        let when = RPNExpression(
            "OUTPUT.w NATIVE.w / 2.0 < OUTPUT.h NATIVE.h / 2.0 < * "
                + "OUTPUT.w NATIVE.w / 1.2 > OUTPUT.h NATIVE.h / 1.2 > * *"
        )
        // Exactly 2x: not less than 2, so the pass is skipped.
        XCTAssertEqual(try when.evaluate(in: environment()), 0)

        var oneAndAHalf = environment()
        oneAndAHalf.set("OUTPUT", width: 2880, height: 1620)
        XCTAssertEqual(try when.evaluate(in: oneAndAHalf), 1)
    }

    func testSizeExpressions() throws {
        XCTAssertEqual(try RPNExpression("MAIN.w 2 *").evaluate(in: environment()), 3840)
        XCTAssertEqual(try RPNExpression("OUTPUT.h 2 /").evaluate(in: environment()), 1080)
        XCTAssertEqual(try RPNExpression("MAIN.w").evaluate(in: environment()), 1920)
    }

    func testUnknownTextureIsReported() {
        XCTAssertThrowsError(try RPNExpression("GHOST.w").evaluate(in: environment())) { error in
            guard case ShaderError.badExpression = error else {
                return XCTFail("expected badExpression, got \(error)")
            }
        }
    }

    func testUnbalancedExpressionIsReported() {
        XCTAssertThrowsError(try RPNExpression("MAIN.w MAIN.h").evaluate(in: environment()))
        XCTAssertThrowsError(try RPNExpression("+").evaluate(in: environment()))
    }
}
