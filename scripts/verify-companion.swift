import Foundation

private enum Failure: Error { case failed(String) }

@main
enum VerifyCompanion {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure.failed(message) }
            checks += 1
        }

        let secret = Data((0..<32).map(UInt8.init))
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let code = AuroraCompanionProtocol.pairingCode(secret: secret, at: fixedDate)
        try expect(code.count == 8, "pairing code was not eight digits")
        try expect(code.allSatisfy(\.isNumber), "pairing code was not numeric")
        try expect(
            AuroraCompanionProtocol.acceptsPairingCode(code, secret: secret, at: fixedDate),
            "current pairing code was rejected"
        )
        let priorCode = AuroraCompanionProtocol.pairingCode(
            secret: secret,
            at: fixedDate.addingTimeInterval(-AuroraCompanionProtocol.pairingWindowSeconds)
        )
        try expect(
            AuroraCompanionProtocol.acceptsPairingCode(priorCode, secret: secret, at: fixedDate),
            "grace-window pairing code was rejected"
        )
        try expect(
            !AuroraCompanionProtocol.acceptsPairingCode("0000000x", secret: secret, at: fixedDate),
            "malformed pairing code was accepted"
        )
        try expect(
            AuroraCompanionProtocol.interactiveAuthenticationTimeoutSeconds >= 120,
            "interactive pairing deadline is too short for a human"
        )

        let client = AuroraCompanionProtocol.clientProof(
            secret: secret,
            serverNonce: "server",
            clientNonce: "client",
            deviceID: "phone"
        )
        let server = AuroraCompanionProtocol.serverProof(
            secret: secret,
            serverNonce: "server",
            clientNonce: "client",
            deviceID: "phone"
        )
        try expect(client != server, "client and server proofs were interchangeable")
        try expect(
            AuroraCompanionProtocol.constantTimeEqual(client, client),
            "identical proof failed comparison"
        )
        try expect(
            !AuroraCompanionProtocol.constantTimeEqual(client, server),
            "different proof passed comparison"
        )

        var microphone = AuroraCompanionEnvelope(type: .microphone, sequence: 4)
        microphone.generation = "generation"
        microphone.audio = Data(repeating: 0x2a, count: 4_800)
        microphone.inputLevel = 0.42
        let framed = try AuroraCompanionProtocol.encode(microphone)
        try expect(framed.count > 4_800, "wire frame omitted its envelope")

        var decoder = AuroraCompanionFrameDecoder()
        let split = framed.count / 3
        let firstPartial = try decoder.append(framed.prefix(split))
        try expect(firstPartial.isEmpty, "partial frame decoded early")
        let secondPartial = try decoder.append(framed[split..<(split * 2)])
        try expect(secondPartial.isEmpty, "second partial frame decoded early")
        let decoded = try decoder.append(framed.suffix(from: split * 2))
        try expect(decoded == [microphone], "incremental frame round-trip changed the envelope")

        let ping = try AuroraCompanionProtocol.encode(
            AuroraCompanionEnvelope(type: .ping, sequence: 5)
        )
        let pong = try AuroraCompanionProtocol.encode(
            AuroraCompanionEnvelope(type: .pong, sequence: 6)
        )
        var combined = AuroraCompanionFrameDecoder()
        let coalesced = try combined.append(ping + pong)
        try expect(coalesced.map(\.type) == [.ping, .pong], "coalesced frames lost order")

        var state = AuroraCompanionEnvelope(type: .state, sequence: 7)
        state.phase = "listening"
        state.audioRoute = "remote"
        state.sessionOwner = "iphone"
        var stateDecoder = AuroraCompanionFrameDecoder()
        let decodedState = try stateDecoder.append(AuroraCompanionProtocol.encode(state))
        try expect(
            decodedState.first?.audioRoute == "remote",
            "state lost its explicit audio-route owner"
        )
        try expect(
            decodedState.first?.sessionOwner == "iphone",
            "state lost its explicit session owner"
        )

        var oversizedAudio = AuroraCompanionEnvelope(type: .microphone, sequence: 8)
        oversizedAudio.audio = Data(
            repeating: 0,
            count: AuroraCompanionProtocol.maximumAudioBytes + 1
        )
        let oversizedFrame = try AuroraCompanionProtocol.encode(oversizedAudio)
        var rejectingDecoder = AuroraCompanionFrameDecoder()
        do {
            _ = try rejectingDecoder.append(oversizedFrame)
            throw Failure.failed("oversized audio was accepted")
        } catch AuroraCompanionProtocolError.audioTooLarge {
            checks += 1
        }

        print("Aurora companion verification passed (\(checks) checks).")
    }
}
