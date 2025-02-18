//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import Accelerate
import CoreML
import Foundation

public protocol TokenSampling {
    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) -> SamplingResult
    func finalize(tokens: [Int], logProbs: [Float]) -> (tokens: [Int], sumLogProbs: Float)
}

public struct SamplingResult {
    public var tokens: [Int]
    public var logProbs: [Float]
    public var completed: Bool
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public class GreedyTokenSampler: TokenSampling {
    public var temperature: FloatType
    public var eotToken: Int
    public var decodingOptions: DecodingOptions

    public init(temperature: FloatType, eotToken: Int, decodingOptions: DecodingOptions) {
        self.temperature = temperature
        self.eotToken = eotToken
        self.decodingOptions = decodingOptions
    }

    public func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) -> SamplingResult {
        var softmaxOutput: BNNSNDArrayDescriptor?
        var argmaxOutput: BNNSNDArrayDescriptor?

        var nextToken: Int?

        do {
            let logitsRawPointer = UnsafeMutableRawBufferPointer(
                start: logits.dataPointer,
                count: logits.count * MemoryLayout<FloatType>.stride
            )

            let logitsDescriptor = BNNSNDArrayDescriptor(
                data: logitsRawPointer,
                scalarType: FloatType.self, // FIXME: Float16 here breaks in swift 6
                shape: .vector(logits.count, stride: 1)
            )!

            var softmaxInput = logitsDescriptor

            // Scale logits by temperature if > 0
            if temperature != 0.0 {
                let scaledLogits = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: FloatType.self,
                    shape: .vector(logits.count, stride: 1)
                )

                try! BNNS.applyActivation(
                    activation: BNNS.ActivationFunction.linear(alpha: Float(1 / temperature)),
                    input: logitsDescriptor,
                    output: scaledLogits,
                    batchSize: 1
                )

                softmaxInput = scaledLogits
            }

            // Always softmax once
            softmaxOutput = BNNSNDArrayDescriptor.allocateUninitialized(
                scalarType: Float.self,
                shape: .vector(logits.count, stride: 1)
            )

            try BNNS.applyActivation(
                activation: BNNS.ActivationFunction.softmax,
                input: softmaxInput,
                output: softmaxOutput!,
                batchSize: 1
            )

            if temperature != 0.0 {
                // top-k multinomial sampling
                let k = decodingOptions.topK

                let bestValues = BNNSNDArrayDescriptor.allocateUninitialized(scalarType: Float.self, shape: .vector(k, stride: 1))
                let bestIndices = BNNSNDArrayDescriptor.allocateUninitialized(scalarType: Int32.self, shape: .vector(k, stride: 1))

                try! BNNS.applyTopK(
                    k: k,
                    input: softmaxOutput!,
                    bestValues: bestValues,
                    bestIndices: bestIndices,
                    axis: 0,
                    batchSize: 1
                )

                let bestValuesResult = bestValues.makeArray(of: Float.self)!
                let bestIndicesResult = bestIndices.makeArray(of: Int32.self)!

                bestValues.deallocate()
                bestIndices.deallocate()

                // multinomial sample from top-k
                let sumOfbestIndicesResult = bestValuesResult.reduce(0, +)
                let rnd = Float.random(in: 0..<sumOfbestIndicesResult)
                var accumulator = Float(0.0)
                var chosenIndex = 0
                for i in 0..<bestValuesResult.count {
                    accumulator += bestValuesResult[i]
                    if rnd < accumulator {
                        chosenIndex = i
                        break
                    }
                }

                nextToken = Int(bestIndicesResult[chosenIndex])
            } else {
                // Argmax sampling
                argmaxOutput = BNNSNDArrayDescriptor.allocateUninitialized(
                    scalarType: Float.self,
                    shape: .vector(1, stride: 1)
                )

                try! BNNS.applyReduction(
                    BNNS.ReductionFunction.argMax,
                    input: logitsDescriptor,
                    output: argmaxOutput!,
                    weights: nil
                )

                let argmaxResult = argmaxOutput!.makeArray(of: Float.self)!

                nextToken = Int(argmaxResult[0])
            }
        } catch {
            Logging.error("Sampling error: \(error)")
        }

        // Log of softmax probability of chosen token
        let softmaxResult = softmaxOutput!.makeArray(of: Float.self)!
        let nextLogprob = log(Float(softmaxResult[nextToken!]))

        let nextTokens = tokens + [nextToken!]
        let nextLogprobs = logProbs + [nextLogprob]
        let completed = nextToken == eotToken

        // Deallocations
        softmaxOutput?.deallocate()
        argmaxOutput?.deallocate()

        return SamplingResult(tokens: nextTokens, logProbs: nextLogprobs, completed: completed)
    }

    public func finalize(tokens: [Int], logProbs: [Float]) -> (tokens: [Int], sumLogProbs: Float) {
        var finalTokens = tokens
        if tokens.last != eotToken {
            finalTokens.append(eotToken)
        }

        let sumLogProbs = logProbs.reduce(0, +)
        return (tokens: finalTokens, sumLogProbs: sumLogProbs)
    }
}

public class BeamSearchTokenSampler: TokenSampling {
    public var beamSize: Int
    public var eotToken: Int
    public var patience: Float
    var maxCandidates: Int
    var finishedSequences: [Float]

    public init(
        beamSize: Int,
        eotToken: Int,
        patience: Float = 1
    ) {
        self.beamSize = beamSize
        self.eotToken = eotToken
        self.patience = patience
        self.maxCandidates = Int(Float(beamSize) * patience)
        self.finishedSequences = []
        if self.maxCandidates <= 0 {
            self.maxCandidates = 1
            fatalError("Invalid beam size \(beamSize) or patience \(patience)")
        }
    }

    public func reset() {
        finishedSequences = []
    }

    public func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) -> SamplingResult {
        // TODO: Implement
        fatalError("Not implemented: \(#function)")
    }

    public func finalize(tokens: [Int], logProbs: [Float]) -> (tokens: [Int], sumLogProbs: Float) {
        // TODO: Implement
        fatalError("Not implemented: \(#function)")
    }
}
