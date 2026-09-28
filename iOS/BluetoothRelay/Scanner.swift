import SwiftUI
import AVFoundation
import UIKit
import BridgeCore

struct ScannerView: UIViewControllerRepresentable {
    let completion: (Result<String?, Error>) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(completion: completion) }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bluetoothcodex.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var finished = false
    private let completion: (Result<String?, Error>) -> Void
    init(completion: @escaping (Result<String?, Error>) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let close = UIButton(type: .system)
        close.setTitle("取消扫码", for: .normal); close.tintColor = .white
        close.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if granted { self.configure() }
                else { self.finish(.failure(BridgeError.invalid("请在设置中允许相机权限，或手动输入配对码"))) }
            }
        }
    }
    private func configure() {
        do {
            guard let device = AVCaptureDevice.default(for: .video) else { throw BridgeError.invalid("相机不可用") }
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureMetadataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else { throw BridgeError.invalid("无法打开相机") }
            session.addInput(input); session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session); self.preview = preview
            preview.videoGravity = .resizeAspectFill; preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            let session = self.session; queue.async { session.startRunning() }
        } catch { finish(.failure(error)) }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); finished = true
        let session = self.session; queue.async { session.stopRunning() }
    }
    @objc private func cancel() { finish(.success(nil)) }
    private func finish(_ result: Result<String?, Error>) {
        guard !finished else { return }; finished = true
        let session = self.session; queue.async { session.stopRunning() }
        completion(result)
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = code.stringValue else { return }
        finish(.success(value))
    }
}
