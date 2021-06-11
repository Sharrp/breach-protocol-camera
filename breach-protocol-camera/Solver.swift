typealias Matrix = Array<Array<String>>

extension Matrix {
  func transpose() -> Matrix {
    guard let firstRow = self.first else { return [] }
    return firstRow.indices.map { index in
      self.map{ $0[index] }
    }
  }
  
  func asText() -> String {
    var textLines = [String]()
    for line in self {
      textLines.append(line.joined(separator: " "))
    }
    return textLines.joined(separator: "\n")
  }
  
  static func fromText(text: String) -> Matrix {
    let lines = text.split(separator: "\n").map{ String($0) }
    let linesOfSubstrings = lines.map{ $0.split(separator: " ").map{ String($0) } }
    return linesOfSubstrings
  }
}

func makeTargets(fromText text: String) -> [[String]] {
  let lines = text.split(separator: "\n").map{ String($0) }
  return lines.map{ $0.split(separator: " ").map{ String($0)} }
}

struct Riddle {
  let matrix: Matrix
  let targets: [[String]]
}

struct Solution {
  let chain: Chain
  let matchedTargetIDs: Set<Int>
}

extension Solution: CustomDebugStringConvertible {
  var debugDescription: String {
    var output = "\(matchedTargetIDs.map{ String($0) }.joined(separator: ", ")):　\(chain.first!)"
    for i in 1..<chain.count {
      output += " \(chain[i]-chain[i-1])"
    }
    return output
  }
}

struct ChainNavigationStep {
  enum Direction: String {
    case up = "↑"
    case down = "↓"
    case left = "←"
    case right = "→"
  }
  
  let direction: Direction
  let width: Int
}

extension ChainNavigationStep: CustomDebugStringConvertible {
  var debugDescription: String {
    return "\(direction.rawValue)\(width)"
  }
}

struct Node: CustomDebugStringConvertible {
  var x: Int = 0
  var y: Int = 0
  
  var debugDescription: String {
    return "X=\(x)"
  }
  
  static func -(lhs: Node, rhs: Node) -> ChainNavigationStep {
    let step: ChainNavigationStep
    if lhs.x == rhs.x {
      let diff = lhs.y - rhs.y
      step = ChainNavigationStep(direction: diff > 0 ? .down : .up, width: abs(diff))
    } else {
      let diff = lhs.x - rhs.x
      step = ChainNavigationStep(direction: diff > 0 ? .right : .left , width: abs(diff))
    }
    return step
  }
}

extension Node: Equatable {
  static func == (lhs: Node, rhs: Node) -> Bool {
    return lhs.x == rhs.x && lhs.y == rhs.y
  }
}

typealias Chain = [Node]
extension Chain {
  var lastNodeAvailable: Bool {
    guard self.count > 1 else { return true }
    return !self.prefix(self.count-1).contains(self.last!)
  }
}

extension Array where Element: Equatable {
  func isSubarray(ofArray array: Array) -> Bool {
    guard array.count >= self.count else { return false }
    for i in 0...array.count-self.count {
      var found = true
      for j in 0..<self.count {
        if array[i+j] != self[j] {
          found = false
          break
        }
      }
      if found { return true }
    }
    return false
  }
}

struct ChainModifier {
  func addNode(chain: Chain) -> Chain {
    guard chain.count > 0 else { return [Node()] }
    let node: Node
    if chain.count % 2 == 0 {
      node = Node(x: 0, y: chain.last!.y)
    } else {
      node = Node(x: chain.last!.x, y: 0)
    }
    return chain + [node]
  }
  
  func propogateLast(chain: Chain, matrixSize: Int) -> (chain: Chain, success: Bool) {
    guard chain.count > 0 else { return (chain, false) }
    var chain = chain
    var overflow: Bool
    if chain.count % 2 == 0 {
      chain[chain.count-1].y += 1
      overflow = chain[chain.count-1].y >= matrixSize
    } else {
      chain[chain.count-1].x += 1
      overflow = chain[chain.count-1].x >= matrixSize
    }
    return (chain, !overflow)
  }
  
  func removeLast(chain: Chain) -> Chain {
    var chain = chain
    chain.removeLast()
    return chain
  }
  
  func buildChain(initialChain: Chain, matrixSize: Int, length: Int) -> Chain? {
    guard length <= matrixSize*matrixSize else { return nil }
    var chain = initialChain
    while chain.count < length {
      chain = addNode(chain: chain)
      while !chain.lastNodeAvailable {
        var result = propogateLast(chain: chain, matrixSize: matrixSize)
        chain = result.chain
        while !result.success {
          _ = removeLast(chain: chain)
          if chain.count == 1 { return nil }
          result = propogateLast(chain: chain, matrixSize: matrixSize)
          chain = result.chain
        }
      }
    }
    return chain
  }
  
  func nextChain(chain: Chain, matrixSize: Int) -> Chain? {
    let length = chain.count
    var success = false
    var chain = chain
    while !success {
      let result = propogateLast(chain: chain, matrixSize: matrixSize)
      chain = result.chain
      if !result.success {
        chain = removeLast(chain: chain)
        if chain.count == 1 { return nil }
        continue
      }
      success = chain.lastNodeAvailable
    }
    return buildChain(initialChain: chain, matrixSize: matrixSize, length: length)
  }
}

struct Solver {
  let bufferSize: Int
  let modifier = ChainModifier()
  
  func solve(riddle: Riddle) -> [Solution]? {
    let matrix = riddle.matrix.transpose()
    var solutions = [Solution]()
    
    for startX in 0..<matrix.count {
      guard let originalChain = modifier.buildChain(
              initialChain: [Node(x: startX, y: 0)],
              matrixSize: matrix.count,
              length: bufferSize) else { return nil }
      
      var chain: Chain? = originalChain
      while chain != nil {
        let buffer = render(chain: chain!, withMatrix: matrix)
        let matchedIndexes = matchedTargetsIndexes(buffer: buffer, targets: riddle.targets)
        if matchedIndexes.count > 0 {
          var solution: Solution? = Solution(chain: chain!, matchedTargetIDs: matchedIndexes)
          for i in 0..<solutions.count {
            if matchedIndexes.isSubset(of: solutions[i].matchedTargetIDs) {
              solution = nil
              break
            }
            
            let sameButShorter = matchedIndexes == solutions[i].matchedTargetIDs && chain!.count < solutions[i].chain.count
            let includesExisting = matchedIndexes.isSuperset(of: solutions[i].matchedTargetIDs) && matchedIndexes.count > solutions[i].matchedTargetIDs.count
            if sameButShorter || includesExisting {
              solutions.remove(at: i)
              for j in stride(from: solutions.count-1, to: i-1, by: -1) {
                if matchedIndexes.isSuperset(of: solutions[j].matchedTargetIDs) {
                  solutions.remove(at: j)
                }
              }
              break
            }
          }
          if solution != nil {
            solutions.append(solution!)
            if solution!.matchedTargetIDs.count == riddle.targets.count {
              break
            }
          }
        }
        chain = modifier.nextChain(chain: chain!, matrixSize: matrix.count)
      }
    }
    return solutions
  }
  
  private func matchedTargetsIndexes(buffer: [String], targets: [[String]]) -> Set<Int> {
    var matchedTargets = Set<Int>()
    for (i, target) in targets.enumerated() {
      if target.isSubarray(ofArray: buffer) {
        matchedTargets.insert(i)
      }
    }
    return matchedTargets
  }
  
  func render(chain: Chain, withMatrix matrix: Matrix) -> [String] {
    return chain.map{ matrix[$0.x][$0.y] }
  }
}
