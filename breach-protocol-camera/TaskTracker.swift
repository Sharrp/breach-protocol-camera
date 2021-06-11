//
//  TaskTracker.swift
//  breach-protocol-camera
//
//  Created by sharrp on 2020/12/25.
//

import Foundation

typealias MatrixMap = [MatrixIndex: String]

extension MatrixMap {
  func render(atSize size: Int) -> String {
    var output = ""
    for i in 0..<size {
      for j in 0..<size {
        if let hex = self[MatrixIndex(row: i, col: j)] {
          output += "\(hex) "
        } else {
          output += "-- "
        }
      }
      //      output += "\n"
    }
    return output
  }
}

struct MatrixIndex: Hashable {
  let row: Int
  let col: Int
  
  static func == (lhs: MatrixIndex, rhs: MatrixIndex) -> Bool {
    return lhs.row == rhs.row && lhs.col == rhs.col
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(row)
    hasher.combine(col)
  }
}

extension MatrixIndex: CustomDebugStringConvertible {
  var debugDescription: String {
    return "\(row),\(col)"
  }
}

class TaskTracker {
  private let digitConfidenceThreshold = 5
  private var candidates = [MatrixIndex: ModeDetector<String>]()
  private var sizeDetector = ModeDetector<Int>(stopTrackingReaching: 5)
  private var matrixSize: Int? {
    return sizeDetector.mode
  }
  private var detectedMatrix: Matrix?
  
  private var targetsDetector = ModeDetector<String>(stopTrackingReaching: 5)
  private let targetsSeparator = "|"
  private var detectedTargets: [String]?
  
  func log(matrixInfo: MatrixInfo) {
    sizeDetector.track(matrixInfo.size)
    
    for (index, hex) in matrixInfo.map {
      if candidates[index] == nil {
        candidates[index] = ModeDetector<String>(stopTrackingReaching: digitConfidenceThreshold)
      }
      candidates[index]!.track(hex)
    }
  }
  
  // Returns non-nil only if size determined and confidence for each digit is high
  var bestMatrixCandidate: Matrix? {
    guard let size = matrixSize else { return nil }
    if let matrix = detectedMatrix { return matrix }
    
    var matrix = Array(repeating: Array(repeating: "", count: size), count: size)
    for i in 0..<size {
      for j in 0..<size {
        guard let modeDetector = candidates[MatrixIndex(row: i, col: j)] else { return nil }
        guard let mode = modeDetector.mode else { return nil }
        matrix[i][j] = mode
      }
    }
    //    print("Size: \(size), from:", sizes)
    detectedMatrix = matrix
    return matrix
  }
  
  func log(targets: [String]) {
    guard targetsDetector.mode == nil else { return }
    guard !targets.isEmpty else { return }
    let joinedTargets = targets.joined(separator: targetsSeparator)
    targetsDetector.track(joinedTargets)
  }
  
  var bestTargestCandidates: [String]? {
    guard detectedTargets == nil else { return detectedTargets }
    guard let joinedTargets = targetsDetector.mode else { return nil }
    detectedTargets = joinedTargets.split(separator: Character(targetsSeparator)).map{ String($0) }
    return detectedTargets
  }
  
  func reset() {
    candidates.removeAll()
    sizeDetector.reset()
    detectedMatrix = nil
    
    targetsDetector.reset()
    detectedTargets = nil
  }
}
