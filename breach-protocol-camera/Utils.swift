//
//  Utils.swift
//  RealtimeNumberReader
//
//  Created by sharrp on 2020/12/23.
//  Copyright © 2020 Apple. All rights reserved.
//

import AVFoundation
import UIKit

// MARK: - Utility extensions

extension AVCaptureVideoOrientation {
  init?(deviceOrientation: UIDeviceOrientation) {
    switch deviceOrientation {
    case .portrait: self = .portrait
    case .portraitUpsideDown: self = .portraitUpsideDown
    case .landscapeLeft: self = .landscapeRight
    case .landscapeRight: self = .landscapeLeft
    default: return nil
    }
  }
}

extension Array {
  mutating func partitionAndSplit(by criteria: (Element) -> Bool) -> (Array, Array) {
    let countInFirstHalf = partition(by: criteria)
    return (Array(self[0..<countInFirstHalf]), Array(self[countInFirstHalf..<count]))
  }
}

extension String {
  var fullRange: NSRange {
    return NSRange(location: 0, length: self.count)
  }
}

extension CGRect {
  var center: CGPoint {
    return CGPoint(x: origin.x + width/2, y: origin.y + height/2)
  }
  
  func overlapsByY(with point: CGPoint) -> Bool {
    return point.y >= minY && point.y <= maxY
  }
}

struct TextAnalyzer {
  private static let replacementTable = [
    "B0": "BD",
    "BO": "BD",
    "80": "BD",
    "8D": "BD",
    "EG": "E9",
    "EY": "E9",
    "IC": "1C",
    "65": "55",
    "66": "55",
    "56": "55"
  ]
  
  func applyCorrections(to hexDigit: String) -> String {
    if let replacement = Self.replacementTable[hexDigit] {
      return replacement
    }
    return hexDigit
  }
  
  func correctAllKnownMisdetections(inString string: String) -> String {
    var result = string
    for (wrong, corrected) in Self.replacementTable {
      result = result.replacingOccurrences(of: wrong, with: corrected)
    }
    return result
  }
}

struct ModeDetector<Element> where Element: Hashable {
  private let stopTrackingThreshold: Int
  private var candidates = [Element: Int]()
  private var mostFrequentItem: Element?
  private var mostFrequentItemCount = 0
  
  init(stopTrackingReaching stopThreshold: Int) {
    self.stopTrackingThreshold = stopThreshold
  }
  
  mutating func track(_ item: Element) {
    guard mostFrequentItemCount < stopTrackingThreshold else { return }
    if candidates[item] == nil {
      candidates[item] = 1
    } else {
      candidates[item]! += 1
    }
    if candidates[item]! > mostFrequentItemCount {
      mostFrequentItemCount = candidates[item]!
      mostFrequentItem = item
    }
  }
  
  var mode: Element? {
    guard mostFrequentItemCount >= stopTrackingThreshold else { return nil }
    return mostFrequentItem
  }
  
  mutating func reset() {
    candidates.removeAll()
    mostFrequentItem = nil
    mostFrequentItemCount = 0
  }
}
