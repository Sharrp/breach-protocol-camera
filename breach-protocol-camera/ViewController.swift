/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 Main view controller: handles camera, preview.
 */

import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController {
  // MARK: - UI objects
  @IBOutlet weak var previewView: PreviewView!
  // Device orientation. Updated whenever the orientation changes to a
  // different supported orientation.
  var currentOrientation = UIDeviceOrientation.portrait
  
  // MARK: - Capture related objects
  private let captureSession = AVCaptureSession()
  let captureSessionQueue = DispatchQueue(label: "com.sharrp.breach-protocol.CaptureSessionQueue")
  
  var captureDevice: AVCaptureDevice?
  
  var videoDataOutput = AVCaptureVideoDataOutput()
  let videoDataOutputQueue = DispatchQueue(label: "com.sharrp.breach-protocol.VideoDataOutputQueue")
  
  // MARK: - Region of interest (ROI) and text orientation
  // Region of video data output buffer that recognition should be run on.
  // Gets recalculated once the bounds of the preview layer are known.
  var regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
  // Orientation of text to search for in the region of interest.
  var textOrientation = CGImagePropertyOrientation.up
  
  // MARK: - Coordinate transforms
  var bufferAspectRatio = 3840.0 / 2160.0 // 4k
  // Transform from UI orientation to buffer orientation.
  var uiRotationTransform = CGAffineTransform.identity
  // Transform bottom-left coordinates to top-left.
  var bottomToTopTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -1)
  // Transform coordinates in ROI to global coordinates (still normalized).
  var roiToGlobalTransform = CGAffineTransform.identity
  
  // Vision -> AVF coordinate transform.
  var visionToAVFTransform = CGAffineTransform.identity
  
  var taskDetectionRequest: VNRecognizeTextRequest!
  var taskBoxes: TaskBoxes = (CGRect(), CGRect(), CGRect())
  let textAnalyzer = TextAnalyzer()
  
  // Temporal string tracker
  var frameID: Int64 = 0
  var lastFrameTimestamp = Date()
  
  let taskTracker = TaskTracker()
  
  // MARK: - View controller methods
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    taskDetectionRequest = setupTaskDetectionRequest()
    
    previewView.session = captureSession
    captureSessionQueue.async {
      self.setupCamera()
      
      DispatchQueue.main.async {
        self.setupOrientationAndTransform()
      }
    }
  }
  
  @IBAction func handleTap(_ sender: UITapGestureRecognizer) {
    resumeCamera()
  }
  
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    
    // Only change the current orientation if the new one is landscape or
    // portrait. You can't really do anything about flat or unknown.
    let deviceOrientation = UIDevice.current.orientation
    if deviceOrientation.isPortrait || deviceOrientation.isLandscape {
      currentOrientation = deviceOrientation
    }
    
    // Handle device orientation in the preview layer.
    if let videoPreviewLayerConnection = previewView.videoPreviewLayer.connection {
      if let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation) {
        videoPreviewLayerConnection.videoOrientation = newVideoOrientation
      }
    }
    
    // Orientation changed: figure out new region of interest (ROI).
    setupOrientationAndTransform()
  }
  
  func setupOrientationAndTransform() {
    // Recalculate the affine transform between Vision coordinates and AVF coordinates.
    // Compensate for orientation (buffers always come in the same orientation).
    switch currentOrientation {
    case .landscapeLeft:
      textOrientation = CGImagePropertyOrientation.up
      uiRotationTransform = CGAffineTransform.identity
    case .landscapeRight:
      textOrientation = CGImagePropertyOrientation.down
      uiRotationTransform = CGAffineTransform(translationX: 1, y: 1).rotated(by: CGFloat.pi)
    case .portraitUpsideDown:
      textOrientation = CGImagePropertyOrientation.left
      uiRotationTransform = CGAffineTransform(translationX: 1, y: 0).rotated(by: CGFloat.pi / 2)
    default: // We default everything else to .portraitUp
      textOrientation = CGImagePropertyOrientation.right
      uiRotationTransform = CGAffineTransform(translationX: 0, y: 1).rotated(by: -CGFloat.pi / 2)
    }
    
    // Full Vision to AVF transform.
    visionToAVFTransform = bottomToTopTransform.concatenating(uiRotationTransform)
  }
  
  func setupCamera() {
    guard let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .back) else {
      print("Could not create capture device.")
      return
    }
    self.captureDevice = captureDevice
    
    // NOTE:
    // Requesting 4k buffers allows recognition of smaller text but will
    // consume more power. Use the smallest buffer size necessary to keep
    // down battery usage.
      captureSession.sessionPreset = AVCaptureSession.Preset.hd1920x1080
      bufferAspectRatio = 1920.0 / 1080.0
//    if captureDevice.supportsSessionPreset(.hd4K3840x2160) {
//      captureSession.sessionPreset = AVCaptureSession.Preset.hd4K3840x2160
//      bufferAspectRatio = 3840.0 / 2160.0
//    } else {
//      captureSession.sessionPreset = AVCaptureSession.Preset.hd1920x1080
//      bufferAspectRatio = 1920.0 / 1080.0
//    }
    
    guard let deviceInput = try? AVCaptureDeviceInput(device: captureDevice) else {
      print("Could not create device input.")
      return
    }
    if captureSession.canAddInput(deviceInput) {
      captureSession.addInput(deviceInput)
    }
    
    // Configure video data output.
    videoDataOutput.alwaysDiscardsLateVideoFrames = true
    videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
    videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    if captureSession.canAddOutput(videoDataOutput) {
      captureSession.addOutput(videoDataOutput)
      // NOTE:
      // There is a trade-off to be made here. Enabling stabilization will
      // give temporally more stable results and should help the recognizer
      // converge. But if it's enabled the VideoDataOutput buffers don't
      // match what's displayed on screen, which makes drawing bounding
      // boxes very hard. Disable it in this app to allow drawing detected
      // bounding boxes on screen.
      videoDataOutput.connection(with: AVMediaType.video)?.preferredVideoStabilizationMode = .off
    } else {
      print("Could not add VDO output")
      return
    }
    
    // Set zoom and autofocus to help focus on very small text.
    do {
      try captureDevice.lockForConfiguration()
      captureDevice.videoZoomFactor = 1.2
      captureDevice.autoFocusRangeRestriction = .near
      captureDevice.setExposureTargetBias(captureDevice.minExposureTargetBias * 0.5) // because usuall aiming at TV
      captureDevice.unlockForConfiguration()
    } catch {
      print("Could not set zoom level due to error: \(error)")
      return
    }
    
    captureSession.startRunning()
  }
  
  // MARK: - UI drawing and interaction
  
  func stopCamera() {
    // Stop the camera synchronously to ensure that no further buffers are
    // received. Then update the number view asynchronously.
    captureSessionQueue.sync {
      self.captureSession.stopRunning()
      DispatchQueue.main.async {
//        self.numberView.text = string
//        self.numberView.isHidden = false
      }
    }
  }
  
  func resumeCamera() {
    videoDataOutputQueue.sync {
      self.taskTracker.reset()
    }
    DispatchQueue.main.async {
      self.removeBoxes()
    }
    captureSessionQueue.async {
      if !self.captureSession.isRunning {
        self.captureSession.startRunning()
      }
    }
  }
  
  // MARK: - Bounding box drawing
  
  // Draw a box on screen. Must be called from main queue.
  var boxLayer = [CAShapeLayer]()
  func draw(rect: CGRect, color: CGColor) {
    let layer = CAShapeLayer()
    layer.opacity = 0.5
    layer.borderColor = color
    layer.borderWidth = 1
    layer.frame = rect
    boxLayer.append(layer)
    previewView.videoPreviewLayer.insertSublayer(layer, at: 1)
  }
  
  // Remove all drawn boxes. Must be called on main queue.
  func removeBoxes() {
    for layer in boxLayer {
      layer.removeFromSuperlayer()
    }
    boxLayer.removeAll()
  }
  
  typealias ColoredBoxGroup = (color: CGColor, boxes: [CGRect])
  
  // Draws groups of colored boxes.
  func show(boxGroups: [ColoredBoxGroup]) {
    DispatchQueue.main.async {
      let layer = self.previewView.videoPreviewLayer
      self.removeBoxes()
      for boxGroup in boxGroups {
        let color = boxGroup.color
        for box in boxGroup.boxes {
          let rect = layer.layerRectConverted(fromMetadataOutputRect: box.applying(self.visionToAVFTransform))
          self.draw(rect: rect, color: color)
        }
      }
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      taskDetectionRequest.regionOfInterest = regionOfInterest
      let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: textOrientation, options: [:])
      do {
        try requestHandler.perform([taskDetectionRequest])
      } catch {
        print(error)
      }
    }
  }
}

// MARK: - Text recognition
 
extension ViewController {
  func setupTaskDetectionRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest(completionHandler: recognizeTextTaskDetectionHandler)
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.02
    return request
  }
  
  func recognizeTextTaskDetectionHandler(request: VNRequest, error: Error?) {
    guard var results = request.results as? [VNRecognizedTextObservation] else { return }
    guard let (matrixBox, targetsBox, anchorBox) = detectTaskRegions(visionResults: results) else { return }
    
    show(boxGroups: [(color: UIColor.red.cgColor, boxes: [matrixBox, targetsBox, anchorBox])])
    results = results.filter{ $0.boundingBox.height > anchorBox.height * 0.5 }
    
    if taskTracker.bestMatrixCandidate == nil && VNNormalizedIdentityRect.contains(matrixBox) {
      let matrixResults = results.filter{ matrixBox.contains($0.boundingBox) }

      let digits = extractHexDigits(candidates: matrixResults)
      guard let matrixInfo = composeMatrixMap(fromDigits: digits) else { return }
      guard matrixInfo.size > 3 && matrixInfo.map.count > 12 else { return }
      taskTracker.log(matrixInfo: matrixInfo)
      print(matrixInfo.map.render(atSize: 6))
    }
    
    if taskTracker.bestTargestCandidates == nil && VNNormalizedIdentityRect.contains(targetsBox) {
      let targetsResults = results.filter{ targetsBox.contains($0.boundingBox) }
      let targets = targetsResults
        .sorted{ $0.boundingBox.origin.y > $1.boundingBox.origin.y }
        .map{ $0.topCandidates(1).first?.string ?? "" }
        .filter{ !$0.isEmpty }
        .map{ textAnalyzer.correctAllKnownMisdetections(inString: $0.uppercased()) }
      taskTracker.log(targets: targets)
    }

    if let matrix = taskTracker.bestMatrixCandidate,
       let targets = taskTracker.bestTargestCandidates {
      stopCamera()
      print("\nMatrix:")
      print(matrix.asText())
      print("\nTargets:")
      print(targets.joined(separator: ", "))
      
      let targetsAsArrays = targets.map{ $0.split(separator: " ").map{ String($0) } }
      let riddle = Riddle(matrix: matrix, targets: targetsAsArrays)
      guard let solutions = Solver(bufferSize: 8).solve(riddle: riddle) else { return }
      
      let output = solutions.map{ "\($0)" }.joined(separator: "\n")
      DispatchQueue.main.async {
        let alert = UIAlertController(title: "Solutions", message: output, preferredStyle: .alert)
        let dismissAction = UIAlertAction(title: "Done", style: .default) { _ in alert.dismiss(animated: true, completion: nil) }
        alert.addAction(dismissAction)
        self.present(alert, animated: true, completion: nil)
      }
    }
  }
}

// MARK: - Post-processing

struct MatrixInfo {
  let map: MatrixMap
  let size: Int
}

extension ViewController {
  struct TaskDetectionResult {
    let matrixTotalElements: Int
    let targetsLengths: [Int]
    let boxesToHighlight: [CGRect]
  }
  
  struct VisionString: CustomDebugStringConvertible {
    let value: String
    let bounds: CGRect
    
    var debugDescription: String {
      return value
    }
  }
  
  typealias TaskBoxes = (matrix: CGRect, targets: CGRect, anchor: CGRect)
  
  private func detectTaskRegions(visionResults: [VNRecognizedTextObservation]) -> TaskBoxes? {
    let anchorText = "REACH TIME REMAIN"
    
    for visionResult in visionResults {
      guard let visualText = visionResult.topCandidates(1).first else { continue }
      guard let anchorRange = visualText.string.range(of: anchorText) else { continue }
      guard let anchorBox = try? visualText.boundingBox(for: anchorRange)?.boundingBox else { continue }
      
      let matrixBox = matrixRegion(forAnchorBox: anchorBox)
      let targetsBox = targetsRegion(forAnchorBox: anchorBox)
      
      return (matrixBox, targetsBox, anchorBox)
    }
    return nil
  }
  
  func matrixRegion(forAnchorBox anchorBox: CGRect) -> CGRect {
    let origin = CGPoint(x: anchorBox.origin.x, y: anchorBox.origin.y - 2.3 * anchorBox.width * CGFloat(bufferAspectRatio))
    let size = CGSize(width: 2.3 * anchorBox.width, height: 1.9 * anchorBox.width * CGFloat(bufferAspectRatio))
    return CGRect(origin: origin, size: size)
  }
  
  func targetsRegion(forAnchorBox anchorBox: CGRect) -> CGRect {
    let origin = CGPoint(x: anchorBox.origin.x + 2.5 * anchorBox.width,
                         y: anchorBox.origin.y - 2.2 * anchorBox.width * CGFloat(bufferAspectRatio))
    let size = CGSize(width: 1.3 * anchorBox.width,
                      height: 1.7 * anchorBox.width * CGFloat(bufferAspectRatio))
    return CGRect(origin: origin, size: size)
  }
  
  func extractHexDigits(candidates: [VNRecognizedTextObservation]) -> [VisionString] {
    var digits = [VisionString]()
    let regex = try! NSRegularExpression(pattern: "\\b\\w{2}\\b")
    
    for (_, observation) in candidates.enumerated() {
      guard let visionText = observation.topCandidates(1).first else { continue }
      let text = visionText.string
      let matches = regex.matches(in: text, options: [], range: text.fullRange)
      for m in matches {
        guard let range = Range(m.range, in: text) else { continue }
        guard let box = try? visionText.boundingBox(for: range)?.boundingBox else { continue }
        let hex = textAnalyzer.applyCorrections(to: String(text.uppercased()[range]))
        digits.append(VisionString(value: hex, bounds: box))
      }
    }
    return digits
  }
  
  func composeMatrixMap(fromDigits digits: [VisionString]) -> MatrixInfo? {
    guard digits.count > 0 else { return nil }
    
    // Count rows in matrix and figure out bounds (bottom-left & top-right) of the matrix
    var rowFormingDigits = [VisionString]()
    var itemsPerRow = [Int]()
    var leftBottom = CGPoint(x: digits.first!.bounds.minX, y: digits.first!.bounds.minY)
    var rightTop = CGPoint(x: digits.first!.bounds.maxX, y: digits.first!.bounds.maxY)
    
    for digit in digits {
      if digit.bounds.minX < leftBottom.x { leftBottom.x = digit.bounds.minX }
      if digit.bounds.minY < leftBottom.y { leftBottom.y = digit.bounds.minY }
      if digit.bounds.maxX > rightTop.x { rightTop.x = digit.bounds.maxX }
      if digit.bounds.maxY > rightTop.y { rightTop.y = digit.bounds.maxY }
      
      // If digit's center doesn't overlap by Y with known rows — make it a new row
      if let index = rowFormingDigits.firstIndex(where: { $0.bounds.overlapsByY(with: digit.bounds.center) }) {
        itemsPerRow[index] += 1
      } else {
        rowFormingDigits.append(digit)
        itemsPerRow.append(1)
      }
    }
    
    // It's crucial for the downstream analysis to set the correct matrix size.
    // We use max() because in the current approach Vision tends to miss digits, opposed to adding noise.
    let matrixSize = max(rowFormingDigits.count, itemsPerRow.max() ?? 0)
    
    var matrixMap = [MatrixIndex: String]()
    for digit in digits {
      let (row, column) = indexes(ofDigit: digit, inMatrixOfSize: matrixSize, boundedByLeftBottom: leftBottom, andRightTop: rightTop)
      matrixMap[MatrixIndex(row: row, col: column)] = digit.value
    }
    return MatrixInfo(map: matrixMap, size: matrixSize)
  }
  
  func indexes(ofDigit digit: VisionString, inMatrixOfSize matrixSize: Int,
               boundedByLeftBottom leftBottom: CGPoint, andRightTop rightTop: CGPoint) -> (Int, Int) {
    let center = digit.bounds.center
    let unitX = (rightTop.x - leftBottom.x) / CGFloat(matrixSize)
    let columnIndex = Int(floor((center.x - leftBottom.x) / unitX))
    
    let unitY = (rightTop.y - leftBottom.y) / CGFloat(matrixSize)
    let rowIndexOnImage = Int(floor((center.y - leftBottom.y) / unitY))
    return (matrixSize - rowIndexOnImage - 1, columnIndex)
  }
}
