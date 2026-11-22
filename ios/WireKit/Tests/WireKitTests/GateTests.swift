import Foundation
import Testing
@testable import WireKit

/// Made by tools/face-gate-vectors.ts from fmc_frontend's own assertFlashable.
private struct GateVectors: Decodable {
    struct Case: Decodable { let name, hex: String; let refuse: [String: Bool] }
    let faces: [Case]
}

@Test func gateFailsClosedAsTheSite() throws {
    let url = Bundle.module.url(forResource: "face-gate-vectors", withExtension: "json")!
    for f in try JSONDecoder().decode(GateVectors.self, from: Data(contentsOf: url)).faces {
        for (device, want) in f.refuse {
            let verdict = checkFace(hex(f.hex), watch3Pro: device == "watch_3_pro")
            var refused = false
            if case .refuse = verdict { refused = true }
            #expect(refused == want, "\(f.name) \(device): \(verdict)")
        }
    }
}
