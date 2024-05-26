import AVFoundation
import Cocoa
import Vision

private enum SessionSetupResult {
    case success
    case notAuthorized
    case configurationFailed
}

class ViewController: NSViewController {
    @IBOutlet var previewView: NSView!
    @IBOutlet var maskImageView: ImageAspectFillView!
    @IBOutlet var movementIndicator: NSView!
    @IBOutlet var fpsLabel: NSTextField!
    @IBOutlet var distanceLabel: NSTextField!
    @IBOutlet var coverageLabel: NSTextField!

    var session = AVCaptureSession()
    var previewLayer: AVCaptureVideoPreviewLayer?

    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!

    var videoDataOutput: AVCaptureVideoDataOutput?
    var videoDataOutputQueue: DispatchQueue?

    var captureDevice: AVCaptureDevice?
    var captureDeviceResolution: CGSize = CGSize()

    var rootLayer: CALayer?
    var detectionOverlayLayer: CALayer?
    var detectedFaceRectangleShapeLayer: CAShapeLayer?
    var detectedFaceLandmarksShapeLayer: CAShapeLayer?

    private let sessionQueue = DispatchQueue(label: "session queue")
    private var setupResult: SessionSetupResult = .success

    var lastFeaturePrint: VNFeaturePrintObservation?

    var lastMovement = Date.timeIntervalSinceReferenceDate
    var lastFrame = Date.timeIntervalSinceReferenceDate

    var audioPlayer: AVAudioPlayer?

    var displayPreview = true

    lazy var model: VNCoreMLModel? = {
        try? VNCoreMLModel(for: HandModel().model)
    }()

    var preferences = Preferences()

    var frameRate = 2.0

    var slowFrameRate = 5.0
    var fastFrameRate = 15.0

    var imageDistanceThreshold: Float = 7.5
    var handCoverageThreshold = 10.0 / 255.0

    var movementCoolOff = 3.0
    var touchCoolOff = 5.0

    override func viewDidLoad() {
        super.viewDidLoad()

        preferences.registerDefaults()
        preferences.sync()

        setupPermissions()
        setupAudioPlayer()

        movementIndicator.backgroundColor = #colorLiteral(red: 0.8549019694, green: 0.250980407, blue: 0.4784313738, alpha: 1)
        movementIndicator.layer?.cornerRadius = movementIndicator.frame.width / 2.0
        movementIndicator.alphaValue = 0.8
        maskImageView.wantsLayer = true
        maskImageView.alphaValue = 0.8

       
        sessionQueue.async {
            self.configureSession()

            if self.displayPreview {
                DispatchQueue.main.async {
                    self.setupVisionDrawingLayers()
                }
            }
            self.session.startRunning()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        slowFrameRate = preferences.slowFrameRate
        fastFrameRate = preferences.fastFrameRate

        imageDistanceThreshold = preferences.imageDistanceThreshold
        handCoverageThreshold = preferences.handCoverageThreshold

        movementCoolOff = preferences.movementCooloff
        touchCoolOff = preferences.touchCooloff
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()

        preferences.slowFrameRate = slowFrameRate
        preferences.fastFrameRate = fastFrameRate

        preferences.imageDistanceThreshold = imageDistanceThreshold
        preferences.handCoverageThreshold = handCoverageThreshold

        preferences.movementCooloff = movementCoolOff
        preferences.touchCooloff = touchCoolOff
    }

    private func setupPermissions() {
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break

        case .notDetermined:
           
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(
                for: .video,
                completionHandler: { granted in
                    if !granted {
                        self.setupResult = .notAuthorized
                    }
                    self.sessionQueue.resume()
                }
            )

        default:
            setupResult = .notAuthorized
        }
    }

    private func setupAudioPlayer() {
        let fileURL = URL(fileReferenceLiteralResourceName: "sound.wav")
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.prepareToPlay()
        } catch let error as NSError {
            print(error.localizedDescription)
        }
    }

    private func configureSession() {
        if setupResult != .success {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .low

        do {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front)

            let device = devices.devices.first!

//            try device.lockForConfiguration()
//            device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 1)
//            device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 1)
//            device.unlockForConfiguration()

            let videoDeviceInput = try AVCaptureDeviceInput(device: device)

            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
            }


            let videoDataOutput = AVCaptureVideoDataOutput()

            let videoDataOutputQueue = DispatchQueue(label: "uk.co.matthewspear.VisionFaceTrack")
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true

            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
            }

            videoDataOutput.connection(with: .video)?.isEnabled = true

            self.videoDataOutput = videoDataOutput
            self.videoDataOutputQueue = videoDataOutputQueue

            captureDevice = device

            let dimensions = device.activeFormat.formatDescription.dimensions


            captureDeviceResolution = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))

            print(captureDeviceResolution)


            if displayPreview {
                previewLayer = AVCaptureVideoPreviewLayer(session: session)

                previewLayer?.name = "CameraPreview"
                previewLayer?.backgroundColor = NSColor.black.cgColor
                previewLayer?.videoGravity = .resizeAspectFill

                if previewLayer?.connection?.isVideoMirroringSupported ?? false {
                    previewLayer?.connection?.automaticallyAdjustsVideoMirroring = false
                    previewLayer?.connection?.isVideoMirrored = true
                }

                DispatchQueue.main.async {
                    self.rootLayer = self.previewView.layer
                    self.previewView.layer?.addSublayer(self.previewLayer!)
                    self.previewLayer?.frame = self.previewView.frame
                }
            }

        } catch {
            print("Couldn't create video device input: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()
    }

    override var representedObject: Any? {
        didSet {
        }
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

    private func setupVisionDrawingLayers() {
        let captureDeviceResolution = self.captureDeviceResolution

        let captureDeviceBounds = CGRect(
            x: 0,
            y: 0,
            width: captureDeviceResolution.width,
            height: captureDeviceResolution.height
        )

        let captureDeviceBoundsCenterPoint = CGPoint(
            x: captureDeviceBounds.midX,
            y: captureDeviceBounds.midY
        )

        let normalizedCenterPoint = CGPoint(x: 0.5, y: 0.5)

        guard let rootLayer = self.rootLayer else {
            print("View was not properly initialised")
//                presentErrorAlert(message: "view was not property initialized")
            return
        }

        let overlayLayer = CALayer()
        overlayLayer.name = "DetectionOverlay"
        overlayLayer.masksToBounds = true
        overlayLayer.anchorPoint = normalizedCenterPoint
        overlayLayer.bounds = captureDeviceBounds
        overlayLayer.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)

        let faceRectangleShapeLayer = CAShapeLayer()
        faceRectangleShapeLayer.name = "RectangleOutlineLayer"
        faceRectangleShapeLayer.bounds = captureDeviceBounds
        faceRectangleShapeLayer.anchorPoint = normalizedCenterPoint
        faceRectangleShapeLayer.position = captureDeviceBoundsCenterPoint
        faceRectangleShapeLayer.fillColor = nil
        faceRectangleShapeLayer.strokeColor = NSColor.green.withAlphaComponent(0.7).cgColor
        faceRectangleShapeLayer.lineWidth = 5
        faceRectangleShapeLayer.shadowOpacity = 0.7
        faceRectangleShapeLayer.shadowRadius = 5

        let faceLandmarksShapeLayer = CAShapeLayer()
        faceLandmarksShapeLayer.name = "FaceLandmarksLayer"
        faceLandmarksShapeLayer.bounds = captureDeviceBounds
        faceLandmarksShapeLayer.anchorPoint = normalizedCenterPoint
        faceLandmarksShapeLayer.position = captureDeviceBoundsCenterPoint
        faceLandmarksShapeLayer.fillColor = nil
        faceLandmarksShapeLayer.strokeColor = NSColor.yellow.withAlphaComponent(0.7).cgColor
        faceLandmarksShapeLayer.lineWidth = 3
        faceLandmarksShapeLayer.shadowOpacity = 0.7
        faceLandmarksShapeLayer.shadowRadius = 5

        overlayLayer.addSublayer(faceRectangleShapeLayer)
        faceRectangleShapeLayer.addSublayer(faceLandmarksShapeLayer)
        rootLayer.addSublayer(overlayLayer)

        detectionOverlayLayer = overlayLayer
        detectedFaceRectangleShapeLayer = faceRectangleShapeLayer
        detectedFaceLandmarksShapeLayer = faceLandmarksShapeLayer

        updateLayerGeometry()
    }

    private func updateLayerGeometry() {
        guard let overlayLayer = detectionOverlayLayer,
            let rootLayer = self.rootLayer,
            let previewLayer = self.previewLayer
        else {
            return
        }

        CATransaction.setValue(NSNumber(value: true), forKey: kCATransactionDisableActions)

        let videoPreviewRect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))

        let rotation: CGFloat = 0.0
        let scaleX = videoPreviewRect.width / captureDeviceResolution.width
        let scaleY = videoPreviewRect.height / captureDeviceResolution.height

        // Scale and mirror the image to ensure upright presentation.
        let affineTransform = CGAffineTransform(rotationAngle: radiansForDegrees(rotation))
            .scaledBy(x: scaleX, y: -scaleY)
        overlayLayer.setAffineTransform(affineTransform)

        // Cover entire screen UI.
        let rootLayerBounds = rootLayer.bounds
        overlayLayer.position = CGPoint(x: rootLayerBounds.midX, y: rootLayerBounds.midY)
    }

    private func addPoints(in landmarkRegion: VNFaceLandmarkRegion2D, to path: CGMutablePath, applying affineTransform: CGAffineTransform, closingWhenComplete closePath: Bool) {
        let pointCount = landmarkRegion.pointCount
        if pointCount > 1 {
            let points: [CGPoint] = landmarkRegion.normalizedPoints
            path.move(to: points[0], transform: affineTransform)
            path.addLines(between: points, transform: affineTransform)
            if closePath {
                path.addLine(to: points[0], transform: affineTransform)
                path.closeSubpath()
            }
        }
    }

    private func radiansForDegrees(_ degrees: CGFloat) -> CGFloat {
        return CGFloat(Double(degrees) * Double.pi / 180.0)
    }

    private func addIndicators(to faceRectanglePath: CGMutablePath, faceLandmarksPath: CGMutablePath, for faceObservation: VNFaceObservation) {
        let displaySize = captureDeviceResolution

        let faceBounds = VNImageRectForNormalizedRect(faceObservation.boundingBox, Int(displaySize.width), Int(displaySize.height))
        faceRectanglePath.addRect(faceBounds)

        if let landmarks = faceObservation.landmarks {
            let affineTransform = CGAffineTransform(translationX: faceBounds.origin.x, y: faceBounds.origin.y)
                .scaledBy(x: faceBounds.size.width, y: faceBounds.size.height)

            let openLandmarkRegions: [VNFaceLandmarkRegion2D?] = [
                landmarks.leftEyebrow,
                landmarks.rightEyebrow,
                landmarks.faceContour,
                landmarks.noseCrest,
                landmarks.medianLine,
            ]
            for openLandmarkRegion in openLandmarkRegions where openLandmarkRegion != nil {
                self.addPoints(in: openLandmarkRegion!, to: faceLandmarksPath, applying: affineTransform, closingWhenComplete: false)
            }

            let closedLandmarkRegions: [VNFaceLandmarkRegion2D?] = [
                landmarks.leftEye,
                landmarks.rightEye,
                landmarks.outerLips,
                landmarks.innerLips,
                landmarks.nose,
            ]
            for closedLandmarkRegion in closedLandmarkRegions where closedLandmarkRegion != nil {
                self.addPoints(in: closedLandmarkRegion!, to: faceLandmarksPath, applying: affineTransform, closingWhenComplete: true)
            }
        }
    }

    private func drawFaceObservations(_ faceObservations: [VNFaceObservation]) {
        guard let faceRectangleShapeLayer = detectedFaceRectangleShapeLayer,
            let faceLandmarksShapeLayer = detectedFaceLandmarksShapeLayer
        else {
            return
        }

        CATransaction.begin()

        CATransaction.setValue(NSNumber(value: true), forKey: kCATransactionDisableActions)

        let faceRectanglePath = CGMutablePath()
        let faceLandmarksPath = CGMutablePath()

        for faceObservation in faceObservations {
            addIndicators(
                to: faceRectanglePath,
                faceLandmarksPath: faceLandmarksPath,
                for: faceObservation
            )
        }

        faceRectangleShapeLayer.path = faceRectanglePath
        faceLandmarksShapeLayer.path = faceLandmarksPath

        updateLayerGeometry()

        CATransaction.commit()
    }

    public func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        if (Date.timeIntervalSinceReferenceDate - lastFrame) < (1 / Double(frameRate)) { return }

        let fps = 1 / (Date.timeIntervalSinceReferenceDate - lastFrame)

        DispatchQueue.main.async {
            self.fpsLabel.stringValue = String(format: "%.2f fps", fps)
        }

        var requestHandlerOptions: [VNImageOption: AnyObject] = [:]

        let cameraIntrinsicData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
        if cameraIntrinsicData != nil {
            requestHandlerOptions[VNImageOption.cameraIntrinsics] = cameraIntrinsicData
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to obtain a CVPixelBuffer for the current output frame.")
            return
        }

        if Date.timeIntervalSinceReferenceDate > lastMovement {
            let startFeature = Date.timeIntervalSinceReferenceDate

            let imageRequestHandler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .down,
                options: requestHandlerOptions
            )

            var distance = Float(0)

            let request = VNGenerateImageFeaturePrintRequest()
            do {
                try imageRequestHandler.perform([request])
                let result = request.results?.first as? VNFeaturePrintObservation

                if let lastFeaturePrint = lastFeaturePrint {
                    try result?.computeDistance(&distance, to: lastFeaturePrint)
                }
                lastFeaturePrint = result
            } catch let error as NSError {
                NSLog("Failed to perform FaceLandmarkRequest: %@", error)
            }


            if distance < imageDistanceThreshold {
                // Ensure this is in the correct position for frame rate to work
                lastFrame = Date.timeIntervalSinceReferenceDate
                frameRate = slowFrameRate
                DispatchQueue.main.async {
                    self.movementIndicator.backgroundColor = #colorLiteral(red: 0.8549019694, green: 0.250980407, blue: 0.4784313738, alpha: 1)
                    self.distanceLabel.stringValue = String(format: "%.2f distance", distance)
                    self.coverageLabel.stringValue = "skip hand detect"
                }
                return
            }

            print("Movement!")
            audioPlayer?.prepareToPlay()
            lastMovement = Date.timeIntervalSinceReferenceDate + movementCoolOff
            frameRate = fastFrameRate
            lastFeaturePrint = nil

            DispatchQueue.main.async {
                self.movementIndicator.backgroundColor = #colorLiteral(red: 0.5843137503, green: 0.8235294223, blue: 0.4196078479, alpha: 1)
                self.distanceLabel.stringValue = "skip motion detect"
            }
        }


        let startCoreML = Date.timeIntervalSinceReferenceDate

        let visionRequestHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .upMirrored,
            options: requestHandlerOptions
        )

        var predictionRequest: VNCoreMLRequest?

        guard let model = model else { return }

        do {
            predictionRequest = VNCoreMLRequest(model: model)
            predictionRequest!.imageCropAndScaleOption = .centerCrop
            try visionRequestHandler.perform([predictionRequest!])

            guard let observation = predictionRequest!.results?.first as? VNPixelBufferObservation else {
                fatalError("Unexpected result type from VNCoreMLRequest")
            }

            func pixelFrom(x: Int, y: Int, movieFrame: CVPixelBuffer) -> Int {
                let baseAddress = CVPixelBufferGetBaseAddress(movieFrame)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(movieFrame)
                let buffer = baseAddress!.assumingMemoryBound(to: UInt8.self)
                let index = x * 4 + y * bytesPerRow
                return Int(buffer[index])
            }

            CVPixelBufferLockBaseAddress(observation.pixelBuffer, [])
            var sum: Int = 0
//            let threshold = Int(112 * 112 * 10)
            let threshold = Int(112 * 112 * 255 * handCoverageThreshold)
            var faceTouched = false

            for row in 0 ..< 112 {
                for col in 0 ..< 112 {
                    let pixelValue = pixelFrom(x: 112 - row, y: col, movieFrame: observation.pixelBuffer)
                    sum += pixelValue
                    if sum >= threshold {
                        faceTouched = true
                        break
                    }
                }
            }

            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            if faceTouched {
                print("Face!")
//                AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
                audioPlayer?.play()
                lastMovement = Date.timeIntervalSinceReferenceDate + touchCoolOff
                DispatchQueue.main.async {
                    self.coverageLabel.stringValue = "reached threshold"
                }
            } else {
                audioPlayer?.stop()
                let percentage = 100.0 * (Double(sum) / (255.0 * 112 * 112))
                DispatchQueue.main.async {
                    self.coverageLabel.stringValue = String(format: "%.2f%% hand", percentage)
                }
            }

            if displayPreview {
                let ciImage = CIImage(cvImageBuffer: observation.pixelBuffer)
                let context = CIContext(options: nil)
                if let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(observation.pixelBuffer), height: CVPixelBufferGetHeight(observation.pixelBuffer))) {
                    DispatchQueue.main.async {
                        self.maskImageView.image = NSImage(cgImage: cgImage, size: NSSize(width: 112.0, height: 112.0))
                    }
//                    print(1.0 / (Date.timeIntervalSinceReferenceDate - startCoreML))
                }
            }

        } catch let error as NSError {
            NSLog("Failed to perform FaceLandmarkRequest: %@", error)
        }

        lastFrame = Date.timeIntervalSinceReferenceDate
    }
}
