import Foundation
import Network
import BridgeCore

// Local integration harness, not an alternate production route.
let args = CommandLine.arguments
func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
guard let configFile = option("--config"), let port = option("--port").flatMap(UInt16.init), port > 0 else {
    fputs("Usage: RelayHarness --config PRIVATE_JSON --port PORT [--allow-loopback-upstream]\n", stderr); exit(2)
}
let config = try BridgeConfiguration.read(configFile)
let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
let listener = try NWListener(using: parameters)
var engines = [UUID: RelayEngine]()
listener.newConnectionHandler = { connection in
    let id = UUID()
    let transport = TCPTransport(connection)
    let engine = RelayEngine(transport: transport, token: config.pairingToken, allowLoopback: args.contains("--allow-loopback-upstream"))
    engines[id] = engine
    engine.onClose = { engines.removeValue(forKey: id) }
    transport.start()
}
listener.stateUpdateHandler = { state in
    if case .ready = state { print("RelayHarness ready on loopback:\(port)"); fflush(stdout) }
    if case .failed(let error) = state { fputs("Harness failed: \(error)\n", stderr); exit(1) }
}
listener.start(queue: .main)
RunLoop.main.run()
