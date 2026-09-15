import Foundation

public struct AudioLevelSmoother {
    public private(set) var currentValue: Float = 0

    private let attack: Float
    private let decay: Float

    public init(attack: Float = 0.7, decay: Float = 0.08) {
        self.attack = attack
        self.decay = decay
    }

    public mutating func update(with input: Float) -> Float {
        let target = max(0, min(input, 1))
        let factor = target > currentValue ? attack : decay
        currentValue += (target - currentValue) * factor
        return currentValue
    }

    public mutating func reset() {
        currentValue = 0
    }
}
