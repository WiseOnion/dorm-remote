import simd
import XCTest
@testable import DormRemote

/// The pure parts of the effects display, the bulb's effect match, and Find my lights' two-aim triangulation.
@MainActor
final class LiveTests: XCTestCase {
  func testBlendHitsEachColorAndMixesBetween() {
    let colors = [RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 0, b: 255)]
    XCTAssertEqual(RGB.blend(colors, 0), colors[0])
    XCTAssertEqual(RGB.blend(colors, 1), colors[1])
    XCTAssertEqual(RGB.blend(colors, 2), colors[0], "wraps around")
    XCTAssertEqual(RGB.blend(colors, 0.5), RGB(r: 127, g: 0, b: 127))
    XCTAssertEqual(RGB.blend([], 3), .white)
  }

  func testPatternPreviewUsesThePatternsColors() {
    for p in Effect.patterns {
      for t in stride(from: 0.0, to: 20, by: 0.37) {
        let c = Effect.preview(p.id, at: t, speed: 50)
        if Effect.group(of: p.id) != "Fade" {
          XCTAssertTrue(p.colors.contains(c), "\(p.name) showed \(c) at \(t) s")
        }
      }
    }
  }

  func testFasterPatternsChangeSooner() {
    // "Switch RGB" at speed 100 has moved on by 0.3 s; at speed 1 it hasn't.
    let first = Effect.preview(0x09, at: 0, speed: 1)
    XCTAssertEqual(Effect.preview(0x09, at: 0.3, speed: 1), first)
    XCTAssertNotEqual(Effect.preview(0x09, at: 0.3, speed: 100), first)
  }

  func testBulbJoinsWithItsClosestEffect() {
    XCTAssertEqual(Effect.hubEffect(for: 0x0C), "fade-7", "Fade slow, rainbow")
    XCTAssertEqual(Effect.hubEffect(for: 0x14), "fade-3", "Fade red & green")
    XCTAssertEqual(Effect.hubEffect(for: 0x0A), "jump-7", "Switch all colors")
    XCTAssertNil(Effect.hubEffect(for: 0x0D), "Blink red holds red instead")
    for p in Effect.patterns {
      if let e = Effect.hubEffect(for: p.id) {
        XCTAssertTrue(HubspaceClient.presetEffects.contains(e), "\(p.name) maps to \(e), which the bulb doesn't have")
      }
    }
  }

  func testEveryBulbEffectHasColors() {
    for (_, effects) in HubspaceClient.effectGroups {
      for e in effects {
        XCTAssertFalse(HubspaceClient.colors(ofEffect: e.id).isEmpty)
        _ = HubspaceClient.preview(e.id, at: 7.3, speed: 10)
        _ = HubspaceClient.preview(e.id, at: 7.3, speed: -10)
      }
    }
  }

  func testEffectsHaveColorsToDraw() {
    let all: [Effect] = Effect.patterns.map { .pattern($0.id) } + [.phoneMic, .synced, .candle, .fire]
    for e in all { XCTAssertFalse(e.colors.isEmpty, e.name) }
  }

  func testTwoAimsCrossAtTheLight() throws {
    // A light 2 m ahead and 1 m right of where you stand; the second aim is from half a meter to the left.
    let light = simd_float3(1, 0, -2)
    let a = simd_float3(0, 0, 0), b = simd_float3(-0.5, 0, 0)
    let hit = try XCTUnwrap(LightScanner.crossing((a, light - a), (b, light - b)))
    XCTAssertLessThan(simd_distance(hit, light), 0.01)
  }

  func testAimsFromTheSameSpotDontCross() {
    // No step aside: the rays are the same line, so distance can't be told.
    let dir = simd_float3(0, 0, -1)
    XCTAssertNil(LightScanner.crossing((.zero, dir), (simd_float3(0.01, 0, 0), dir)))
  }

  func testAimsMeetingBehindYouDontCount() {
    // Two rays pointing apart cross behind the phone, not at a light.
    XCTAssertNil(LightScanner.crossing((.zero, simd_float3(-1, 0, -1)), (simd_float3(1, 0, 0), simd_float3(1, 0, -1))))
  }
}
