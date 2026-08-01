# Running CoreML Models on macOS (Tahoe 26 → 27)

A practical, code-grounded dossier on getting machine-learning models to run — and run *well* — on Apple Silicon Macs. Most code is quoted verbatim from a real shipping stack: the **mako** TTS project (`../mac-tts-experiment`) and its `FluidAudio` dependency (the actual CoreML layer it rides on), plus the canonical Apple/`coremltools` APIs you convert and optimize with.

> **Status / scope note.** Everything in §1–§13 is verified against shipping code and Apple's published Core ML / Core ML Tools docs, and applies to **macOS 15 (Sequoia), 26 (Tahoe), and 27**. §14 covers **Core AI** — the Core ML successor announced at WWDC 2026 for macOS 27 / iOS 27 — which is in **developer beta** at time of writing; those details are drawn from Apple's developer pages, the `coreai-torch` docs, and WWDC 2026 coverage, and may change before public release. Where a fact is OS-specific it is called out inline. **Crucially, Core AI has two runtimes with different OS floors:** the **Python `coreai.runtime`** (the `coreai-core` pip wheel, tagged `macosx_26_0`) runs static-shape `.aimodel` files on **Tahoe 26 today**, while the **Swift `CoreAI.framework`** path — on-device iOS, the `llm-runner` CLI, and the pipelined LLM-decode engine — requires **macOS 27** (see [§14b](#14b-core-ai-on-macos-26)). The blunt summary: **on macOS 27 you still ship Core ML for everything that runs today; Core AI is the new path for large neural / LLM-class models — and you can already run *static* Core AI models on Tahoe 26 from Python — and even LLM/MoE decoders, if you build them in a static-S=1 form (§14c); only the *pre-built pipelined* LLM bundles strictly need macOS 27.**

---

## Table of contents

1. [The execution model: CPU, GPU, and the ANE](#1-the-execution-model)
2. [Model formats and compilation](#2-model-formats-and-compilation)
3. [Loading and configuring a model](#3-loading-and-configuring-a-model)
4. [Compute units and the Neural Engine](#4-compute-units-and-the-neural-engine)
5. [Input shapes: fixed, enumerated, range](#5-input-shapes)
6. [Running predictions: sync, async, batch](#6-running-predictions)
7. [Warmup and the compilation cache](#7-warmup-and-the-compilation-cache)
8. [Stateful models and the KV cache](#8-stateful-models-and-the-kv-cache)
9. [MLTensor: glue compute in Swift](#9-mltensor)
10. [Converting models with coremltools](#10-converting-models-with-coremltools)
11. [Optimization: quantization and palettization](#11-optimization)
12. [Profiling and measuring](#12-profiling-and-measuring)
13. [Case study: how mako runs Kokoro end to end](#13-case-study)
14. [macOS 27 and Core AI: the successor](#14-macos-27-and-core-ai)
    - [Worked example: running Qwen3.6-35B-A3B-CoreAI (MoE LLM)](#14a-worked-example-qwen3-moe)
    - [Running Core AI on macOS 26 (Tahoe) without macOS 27 — the Python path](#14b-core-ai-on-macos-26)
    - [Running an actual LLM on Tahoe 26 — the static-S=1 Python decode loop](#14c-llm-on-macos-26)
15. [Pitfalls and a pre-ship checklist](#15-pitfalls-and-checklist)
16. [Sources](#16-sources)

---

<a name="1-the-execution-model"></a>
## 1. The execution model: CPU, GPU, and the ANE

Core ML is both a model *format* and a *runtime*. The runtime schedules a model across three compute engines on Apple Silicon and will split a single model across them, op by op:

- **CPU** — always available, most flexible, lowest setup overhead, slowest for big tensor math.
- **GPU** — high FLOPS and memory bandwidth; best for decode-heavy / memory-bound transformer work; contends with anything else drawing the GPU (UI compositing, Metal).
- **ANE (Apple Neural Engine)** — a fixed-function tensor accelerator (16 cores on M-series). Lowest power, smallest memory footprint, *does not thermally throttle* under sustained load. Its op set is restricted, undocumented, and you cannot program it directly — Core ML decides what lands there.

Three consequences drive everything below:

1. **You influence placement; you don't command it.** You set a *preference* (`MLComputeUnits`); the runtime places each op on the first engine that supports it, and because switching engines mid-graph costs latency it will sometimes keep a run of ops *off* the ANE to avoid a hop. Selecting `.cpuAndNeuralEngine` does **not** guarantee ANE execution.
2. **The ANE trades throughput for footprint and power.** Benchmarks consistently show ANE winning on memory (often ~5× leaner than GPU) and energy (≈half the watts, no throttle), while the GPU wins raw decode tok/s. Pick per workload.
3. **The first load is expensive.** Core ML performs device- and OS-specific specialization (and possibly recompilation) the first time a given model+config is loaded; subsequent loads hit a cache. This is the single biggest latency surprise for newcomers (§7).

---

<a name="2-model-formats-and-compilation"></a>
## 2. Model formats and compilation

| Extension | What it is | Notes |
|---|---|---|
| `.mlmodel` | Legacy single-file protobuf (NeuralNetwork) | Editable source; can be `.mlpackage`-wrapped |
| `.mlpackage` | ML Program package (weights + spec separated) | The modern source format; required for ML Programs |
| `.mlmodelc` | **Compiled** model *directory* | What the runtime actually loads; contains `coremldata.bin` |

**Loading an `.mlpackage`/`.mlmodel` triggers a compile-on-load every time. Loading a pre-compiled `.mlmodelc` skips that.** Production stacks therefore ship `.mlmodelc` directories. You can compile manually:

```sh
xcrun coremlcompiler compile MyModel.mlpackage /path/to/output/   # → MyModel.mlmodelc
```

Here is how a real stack loads compiled models. `FluidAudio` downloads `.mlmodelc` *directories* from Hugging Face, validates the `coremldata.bin` marker, then constructs `MLModel(contentsOf:configuration:)` — the call that performs device specialization. Note the timing log labelled "Compiled model …": even for a pre-compiled `.mlmodelc`, the `MLModel(contentsOf:)` call is where the cost lands.

```swift
// FluidAudio 0.13.6 — Sources/FluidAudio/DownloadUtils.swift  (loadModelsOnce)
let config = MLModelConfiguration()
config.computeUnits = computeUnits
config.allowLowPrecisionAccumulationOnGPU = true

var models: [String: MLModel] = [:]
for (index, name) in modelNames.enumerated() {
    let modelPath = repoPath.appendingPathComponent(name)
    // ... existence + isDirectory checks ...

    let coremlDataPath = modelPath.appendingPathComponent("coremldata.bin")
    guard FileManager.default.fileExists(atPath: coremlDataPath.path) else {
        logger.error("Missing coremldata.bin in \(name)")
        throw CocoaError(.fileReadCorruptFile, userInfo: [ /* ... */ ])
    }

    let start = Date()
    let model = try MLModel(contentsOf: modelPath, configuration: config)   // ← specialization happens here
    let elapsed = Date().timeIntervalSince(start)
    models[name] = model
    logger.info("Compiled model \(name) in \(String(format: "%.2f", elapsed * 1000)) ms")
}
```

**Takeaway:** distribute `.mlmodelc`; load it from a stable, non-purgeable path; expect the first `MLModel(contentsOf:)` to be slow (§7).

---

<a name="3-loading-and-configuring-a-model"></a>
## 3. Loading and configuring a model

Everything funnels through `MLModelConfiguration`. The two settings that matter most:

```swift
import CoreML

let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine          // §4
config.allowLowPrecisionAccumulationOnGPU = true   // fp16 accumulation on GPU — faster, tiny precision cost
// Optional, iOS17.4+/macOS14.4+: optimization hints
// config.optimizationHints.reshapeFrequency = .infrequent   // keep flexible-shape models ANE-eligible (§5)
// config.optimizationHints.specializationStrategy = .fastPrediction
let model = try MLModel(contentsOf: compiledURL, configuration: config)
```

A reusable factory, from the same stack:

```swift
// FluidAudio 0.13.6 — Sources/FluidAudio/Shared/MLModelConfigurationUtils.swift
public enum MLModelConfigurationUtils {
    public static func defaultConfiguration(
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) -> MLModelConfiguration {
        let config = MLModelConfiguration()
        config.allowLowPrecisionAccumulationOnGPU = true
        config.computeUnits = computeUnits
        return config
    }
}
```

### The macOS 26/27 ANE-compiler landmine

This is not theoretical and it is OS-version-specific. `FluidAudio`'s `KokoroTtsManager` exposes `computeUnits` (default `.all`) and carries this warning in three separate files:

```swift
// FluidAudio 0.13.6 — Sources/FluidAudio/TTS/Kokoro/KokoroTtsManager.swift
/// On iOS 26+, use `.cpuAndGPU` to work around ANE compiler regressions:
/// ```swift
/// let manager = KokoroTtsManager(computeUnits: .cpuAndGPU)
/// try await manager.initialize()
/// ```
public final class KokoroTtsManager {
    // ...
    ///   - computeUnits: CoreML compute units for model compilation. Defaults to `.all`.
    ///     Use `.cpuAndGPU` on iOS 26+ to work around ANE compiler regressions
    ///     ("Cannot retrieve vector from IRValue format int32").
    public init(
        defaultVoice: String = TtsConstants.recommendedVoice,
        defaultSpeakerId: Int = 0,
        directory: URL? = nil,
        computeUnits: MLComputeUnits = .all,
        modelCache: KokoroModelCache? = nil,
        customLexicon: TtsCustomLexicon? = nil
    ) { /* ... */ }
}
```

iOS 26 and macOS 26 share the same CoreML compiler; macOS 27 inherits the lineage. If you target the ANE on these OSes and hit `"Cannot retrieve vector from IRValue format int32"` (or an `MLModel(contentsOf:)` hang seen on some 26.x point releases), the field-tested escape hatch is `.cpuAndGPU`. **Always make compute units configurable** so you can flip it per OS without a rebuild.

---

<a name="4-compute-units-and-the-neural-engine"></a>
## 4. Compute units and the Neural Engine

`MLComputeUnits` cases:

| Case | Engines | Use when |
|---|---|---|
| `.all` (default) | CPU + GPU + ANE | General; let Core ML optimize for latency |
| `.cpuAndNeuralEngine` | CPU + ANE | GPU is busy (camera/UI), or you want ANE + low power; iOS SDK default on iOS16+ |
| `.cpuAndGPU` | CPU + GPU | Decode-heavy transformers; **macOS/iOS 26+ ANE-regression workaround** |
| `.cpuOnly` | CPU | Determinism, debugging, tiny control-flow models |

Mature stacks **place per model**, not globally. In `FluidAudio`:

- G2P encoder/decoder → `.cpuOnly` (`G2PModel.swift`, `MultilingualG2PModel.swift`) — small, control-flow-heavy.
- Acoustic Kokoro models → `.all` (default).
- PocketTTS (streaming, KV-cached) → `.cpuAndGPU` (`PocketTtsModelStore.swift`).
- Diarizer / Sortformer → `.all` in production, `.cpuAndNeuralEngine` in CI for determinism.

The Python equivalents during conversion/loading map 1:1: `ct.ComputeUnit.ALL`, `.CPU_AND_NE`, `.CPU_AND_GPU`, `.CPU_ONLY`.

**Why an op isn't on the ANE:** a preceding op may be ANE-incompatible, and Core ML avoids the cost of hopping back. Verify with Xcode's Core ML performance report (§12): filled checkmark = ran there, hollow = supported-but-not-chosen, diamond = unsupported. To deliberately *force the ANE path* for an architecture, follow Apple's transformer principles — `(B, C, 1, S)` channels-first layout, linear layers as 1×1 convolutions, and split-softmax attention — see [ml-ane-transformers](https://github.com/apple/ml-ane-transformers).

---

<a name="5-input-shapes"></a>
## 5. Input shapes: fixed, enumerated, range

Shape flexibility is the most common reason a model silently falls off the ANE and gets 10× slower. The rules:

- **Fixed shapes** → fully ANE-eligible, fastest, preallocated.
- **`EnumeratedShapes`** (a finite set, up to 128) → each shape can run on the ANE; the model is specialized for the set at compile time. **Preferred** when you need a few sizes.
- **`RangeDim`** (a continuous range) → only the *default* shape is ANE-eligible; other shapes fall to GPU/CPU. (`reshapeFrequency = .infrequent` can keep some range models on the ANE on iOS 17.4+, with caveats.)

Conversion API (`coremltools`):

```python
import coremltools as ct

# Enumerated — preferred for ANE
input_shape = ct.EnumeratedShapes(
    shapes=[[1, 3, 25, 25], [1, 3, 50, 50], [1, 3, 67, 67]],
    default=[1, 3, 67, 67],          # preallocated → first prediction is fast
)
model = ct.convert(
    traced_model,
    inputs=[ct.TensorType(shape=input_shape, name="input")],
    convert_to="mlprogram",
)

# Range — flexible but ANE only on the default shape
input_shape = ct.Shape(shape=(1, 3,
    ct.RangeDim(lower_bound=25, upper_bound=100, default=45),
    ct.RangeDim(lower_bound=25, upper_bound=100, default=45)))
```

### The "bucket" pattern in production

mako's Kokoro does not use flexible shapes at all. The model ships as **two fixed-shape variants** — a 5-second and a 15-second decoder — and the pipeline picks the smallest bucket that fits the predicted duration, zero-pads the input, and trims the output. This keeps every variant fully ANE-eligible. The variant enum and the runtime token-length probe:

```swift
// FluidAudio 0.13.6 — KokoroModelCache.swift  (variant set)
private func variantDescription(_ variant: ModelNames.TTS.Variant) -> String {
    switch variant {
    case .fiveSecond:    return "5s"
    case .fifteenSecond: return "15s"
    }
}

// FluidAudio 0.13.6 — KokoroSynthesizer+ModelUtils.swift
// Read the fixed token window straight off the compiled model's input description.
internal static func inferTokenLength(from model: MLModel) -> Int {
    let inputs = model.modelDescription.inputDescriptionsByName
    if let inputDesc = inputs["input_ids"], let constraint = inputDesc.multiArrayConstraint {
        let shape = constraint.shape
        if shape.count >= 2 {
            let n = shape.last!.intValue
            if n > 0 { return n }
        }
    }
    return 124
}
```

This mirrors the upstream conversion ([laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml)): split the network into stages, fp16, fixed-shape decoder buckets, per-stage compute units — because a single merged graph with two `RangeDim` streams produced "141+ GPU ops" and a 6× slowdown.

---

<a name="6-running-predictions"></a>
## 6. Running predictions: sync, async, batch

You feed a model an `MLFeatureProvider` (typically `MLDictionaryFeatureProvider` wrapping `MLMultiArray`s) and read named outputs back. Here is a complete real inference call — input assembly, the prediction, and output extraction by feature name — from Kokoro:

```swift
// FluidAudio 0.13.6 — KokoroSynthesizer.swift  (synthesis inner loop, abridged)

// 1. Fill fixed-shape input buffers via raw pointers (fast, no per-element NSNumber boxing).
let inputPointer = inputArray.dataPointer.bindMemory(to: Int32.self, capacity: targetTokens)
inputPointer.initialize(repeating: 0, count: targetTokens)
trimmedIds.withUnsafeBufferPointer { buffer in
    inputPointer.update(from: buffer.baseAddress!, count: buffer.count)
}
let maskPointer = attentionMask.dataPointer.bindMemory(to: Int32.self, capacity: targetTokens)
maskPointer.initialize(repeating: 0, count: targetTokens)
for idx in 0..<min(inputIds.count, targetTokens) { maskPointer[idx] = 1 }

// 2. Bundle named inputs into a feature provider.
var inputDict: [String: Any] = [
    "input_ids":      inputArray,
    "attention_mask": attentionMask,
    "ref_s":          refStyle,
    "random_phases":  phasesArray,
]
if let sourceNoise = sourceNoise { inputDict["source_noise"] = sourceNoise }   // v2 (macOS) models only
let modelInput = try MLDictionaryFeatureProvider(dictionary: inputDict)

// 3. Predict (async wrapper, see below).
let output = try await kokoro.compatPrediction(from: modelInput, options: MLPredictionOptions())

// 4. Read outputs by name.
guard let audio = output.featureValue(for: "audio")?.multiArrayValue, audio.count > 0 else {
    throw TTSError.processingFailed("Failed to extract 'audio' output. Features: \(Array(output.featureNames))")
}
if let predDur = output.featureValue(for: "pred_dur")?.multiArrayValue { /* compute true length */ }
```

### Sync vs async

The async prediction API (macOS 14+/iOS 17+) integrates with Swift concurrency and lets multiple predictions overlap on the ANE/GPU. The thin wrapper used above:

```swift
// FluidAudio 0.13.6 — Sources/FluidAudio/Shared/MLModel+Prediction.swift
extension MLModel {
    public func compatPrediction(
        from input: MLFeatureProvider,
        options: MLPredictionOptions
    ) async throws -> MLFeatureProvider {
        try await prediction(from: input, options: options)
    }
}
```

### Prediction options / output backings

Reusing output buffers across calls avoids reallocation; batching improves GPU utilization:

```swift
// FluidAudio 0.13.6 — TtsModels.swift
public static func optimizedPredictionOptions() -> MLPredictionOptions {
    let options = MLPredictionOptions()
    options.outputBackings = [:]   // reuse output buffers
    return options
}
```

For true batch inference use `MLBatchProvider` + `predictions(from:options:)`; the runtime can run instances in parallel. (CLIP-Finder-style pipelines preprocess whole galleries with batch sizes in the hundreds on the ANE.)

---

<a name="7-warmup-and-the-compilation-cache"></a>
## 7. Warmup and the compilation cache

**The problem:** the first `MLModel(contentsOf:)` for a given (model, config, device, OS) tuple runs device-specialized compilation — seconds for big models. Subsequent loads hit a cache **keyed by the compiled model's filesystem path and the configuration**. Two different `computeUnits` = two cache entries. On-device-compiled models are treated as a *new* model on every compilation, so keep `.mlmodelc` at a stable, non-purgeable path (e.g. Application Support, not a temp dir).

**The fix is two-fold: cache the loaded `MLModel`, and warm it.**

Cache loaded models in an actor so they're loaded once and reused:

```swift
// FluidAudio 0.13.6 — KokoroModelCache.swift  (abridged)
public actor KokoroModelCache {
    private var kokoroModels: [ModelNames.TTS.Variant: MLModel] = [:]
    private let computeUnits: MLComputeUnits

    public func model(for variant: ModelNames.TTS.Variant) async throws -> MLModel {
        if let existing = kokoroModels[variant] { return existing }   // ← reuse
        try await loadModelsIfNeeded(variants: Set([variant]))
        guard let model = kokoroModels[variant] else {
            throw TTSError.modelNotFound(ModelNames.TTS.bundle(for: variant))
        }
        return model
    }
}
```

Warm it with a representative zero-valued prediction so Core ML allocates and parks its buffers on the right engines *before* the first real request:

```swift
// FluidAudio 0.13.6 — TtsModels.swift  (warmUpModel, abridged)
private static func warmUpModel(_ model: MLModel, variant: ModelNames.TTS.Variant) async {
    do {
        let tokenLength = max(1, KokoroSynthesizer.inferTokenLength(from: model))
        let inputIds = try MLMultiArray(shape: [1, NSNumber(value: tokenLength)], dataType: .int32)
        let attentionMask = try MLMultiArray(shape: [1, NSNumber(value: tokenLength)], dataType: .int32)
        for index in 0..<tokenLength { inputIds[index] = 0; attentionMask[index] = 1 }
        // ... fill ref_s, random_phases, and (v2/macOS) source_noise at the exact inference shapes ...
        let features = try MLDictionaryFeatureProvider(dictionary: inputDict)
        _ = try await model.compatPrediction(from: features, options: optimizedPredictionOptions())
    } catch {
        logger.warning("Warm-up prediction failed for \(variantDescription(variant)): \(error.localizedDescription)")
    }
}
```

The generic version makes the intent explicit — and is the canonical pattern to copy:

```swift
// FluidAudio 0.13.6 — Sources/FluidAudio/Shared/ModelWarmup.swift
/// We reproduce the exact shapes used during inference to make sure Core ML
/// allocates and caches buffers on the correct compute units (ANE/GPU).
static func warmup(model: MLModel, inputName: String, inputShape: [Int], iterations: Int = 1) throws -> TimeInterval {
    let array = try MLMultiArray(shape: inputShape.map { NSNumber(value: $0) }, dataType: .float32)
    array.resetToZeros()
    let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
    let start = Date()
    for _ in 0..<iterations { _ = try model.prediction(from: features) }
    return Date().timeIntervalSince(start)
}
```

> **mako's own miss (worth fixing in any app):** `KokoroFluidAudioRunner.synthesizeData` constructs a **new** `KokoroTtsManager` (hence a new `KokoroModelCache`) on every call, so a long-lived process re-pays warmup each time. For one-shot `mako say` it's invisible; for a server/batch path, hold one initialized manager for the process lifetime.

---

<a name="8-stateful-models-and-the-kv-cache"></a>
## 8. Stateful models and the KV cache

Autoregressive models (LLMs, autoregressive ASR/TTS decoders) recompute attention over the whole prefix unless you cache keys/values. Core ML offers **two** ways to do this; both appear in the stack examined here.

### 8a. CoreML-native stateful models (`MLState`) — macOS 15+/iOS 18+

You declare state buffers at conversion time; the runtime persists and updates them in place across `prediction(...)` calls, eliminating the copy-in/copy-out of cache tensors. Apple's on-device Llama 3.1 work measured the impact directly: KV-cache-as-I/O gave ~1.25 tok/s; the **stateful** cache gave ~16.26 tok/s (≈13×) and dropped TTFT from ~933 ms to ~128 ms; adding Int4 took it to ~33.67 tok/s and ~52 ms TTFT (M1 Max, macOS Sequoia).

Declare states in `coremltools`:

```python
import coremltools as ct, numpy as np
states = [
    ct.StateType(wrapped_type=ct.TensorType(shape=kv_cache_shape, dtype=np.float16), name="keyCache"),
    ct.StateType(wrapped_type=ct.TensorType(shape=kv_cache_shape, dtype=np.float16), name="valueCache"),
]
query_length = ct.RangeDim(lower_bound=1, upper_bound=2048, default=1)
mlmodel = ct.convert(
    traced_model, states=states,
    inputs=[ ... ],
    minimum_deployment_target=ct.target.iOS18,   # macOS15+; required for StateType
)
```

Use it from Swift — `makeState()` once, then `prediction(from:using:)`. This is a **real CoreML stateful decode loop** (Qwen3-ASR's stateful decoder, the same `decoderStateful` model the sibling `ectoboy` app ships):

```swift
// FluidAudio 0.13.6 — Sources/FluidAudio/ASR/Qwen3/Qwen3AsrManager.swift  (abridged)
private func generate(initialEmbeddings: [[Float]], promptLength: Int, maxNewTokens: Int,
                      models: Qwen3AsrModels) throws -> [Int] {
    let state = models.decoderStateful.makeState()          // ← allocate the persistent KV state once
    var generatedTokens: [Int] = []

    // ---- Prefill: run the whole prompt through once ----
    let prefillLogits = try runStatefulDecoder(hiddenStates: hiddenArray, positionCos: cosArray,
                                               positionSin: sinArray, mask: prefillMask,
                                               state: state, models: models)
    var currentPosition = promptLength
    var lastTokenId = argmaxFromLogits(prefillLogits)
    generatedTokens.append(lastTokenId)

    // ---- Decode: one token at a time, KV cache updated in place inside the model ----
    for _ in 1..<effectiveMaxNew {
        let nextEmbedding = models.embeddingWeights.embedding(for: lastTokenId)  // Swift-side lookup, no CoreML call
        nextEmbedding.withUnsafeBufferPointer { src in
            _ = memcpy(decHiddenPtr, src.baseAddress!, Qwen3AsrConfig.hiddenSize * MemoryLayout<Float>.size)
        }
        rope.fill(position: currentPosition, cosPtr: decodeCosPtr, sinPtr: decodeSinPtr)
        let logits = try runStatefulDecoder(hiddenStates: decHiddenArray, positionCos: decodeCosArray,
                                            positionSin: decodeSinArray, mask: try createDecodeMask(endStep: currentPosition + 1),
                                            state: state, models: models)
        currentPosition += 1
        lastTokenId = argmaxFromLogits(logits)
        if Qwen3AsrConfig.eosTokenIds.contains(lastTokenId) { break }
        generatedTokens.append(lastTokenId)
    }
    return generatedTokens
}

private func runStatefulDecoder(hiddenStates: MLMultiArray, positionCos: MLMultiArray, positionSin: MLMultiArray,
                                mask: MLMultiArray, state: MLState, models: Qwen3AsrModels) throws -> MLMultiArray {
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "hidden_states":  MLFeatureValue(multiArray: hiddenStates),
        "position_cos":   MLFeatureValue(multiArray: positionCos),
        "position_sin":   MLFeatureValue(multiArray: positionSin),
        "attention_mask": MLFeatureValue(multiArray: mask),
    ])
    let output = try models.decoderStateful.prediction(from: input, using: state)   // ← state threaded in
    guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
        throw Qwen3AsrError.decoderFailed("Missing logits from stateful decoder")
    }
    return logits
}
```

Three patterns to copy from this: (1) **prefill once, decode one-at-a-time**; (2) the embedding lookup is done in plain Swift (no CoreML round-trip for a gather); (3) preallocated decode buffers are filled by raw pointer each step.

### 8b. Manual KV cache (model-I/O) — works on any OS

If you can't require iOS 18/macOS 15, or you want explicit control, keep the cache as plain Swift tensors and pass them in/out. `FluidAudio`'s PocketTTS does exactly this — six pre-allocated arrays shaped `[2, 1, 512, 16, 64]` (`{k,v} × batch × maxLen × heads × headDim`), sliced and grown in Swift (`PocketTtsSynthesizer+KVCache.swift`, `PocketTtsConstants.kvCacheLayers = 6`, `kvCacheMaxLen = 512`). Simpler portability, more host-side copying — which is precisely the overhead `MLState` removes.

### 8c. When you need neither

mako's **Kokoro is non-autoregressive** — one forward pass per text chunk produces the whole audio window. No KV cache, no state. Don't add stateful machinery to a parallel model; it buys nothing.

---

<a name="9-mltensor"></a>
## 9. MLTensor: glue compute in Swift

`MLTensor` (macOS 15+/iOS 18+) is a NumPy/torch-like tensor type for the *glue* between models — tokenization math, softmax/argmax sampling, feature reshaping — so you stop hand-writing `Accelerate` over `MLMultiArray` pointers.

```swift
import CoreML
// Tensor math runs on a chosen compute device:
let logits: MLTensor = /* ... */
let probs = withMLTensorComputePolicy(.init(MLComputeUnits.cpuAndNeuralEngine)) {
    logits.softmax(alongAxis: -1)
}
let next = await probs.argmax(alongAxis: -1).shapedArray(of: Int32.self)
```

**Important caveat:** `MLTensor` dispatches each op separately (MPSGraph under the hood) and runs on the **GPU, not the ANE** — it's convenient but slow for hot loops. Use it for light glue; for tight per-step work (like §8a's decode loop) stay on raw `MLMultiArray` + `Accelerate`/`memcpy`. mako's DSP (crossfade/microfade, `KokoroSmooth.swift`) is plain Swift `Float` math for this reason.

---

<a name="10-converting-models-with-coremltools"></a>
## 10. Converting models with coremltools

The PyTorch → Core ML path (`coremltools` ≥ 8). Two graph-capture front-ends: `torch.jit.trace` (stable, recommended) and `torch.export` (newer, beta-tracked).

```python
import torch, coremltools as ct

torch_model = MyModel().eval()
example = torch.rand(1, 3, 224, 224)

# Capture (tracing is the stable, more-optimized path)
traced = torch.jit.trace(torch_model, example)

# Convert to an ML Program (.mlpackage)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(shape=example.shape, name="input")],
    convert_to="mlprogram",
    compute_units=ct.ComputeUnit.CPU_AND_NE,        # placement preference at load
    minimum_deployment_target=ct.target.macOS15,    # gates StateType, fused SDPA, etc.
)
mlmodel.save("MyModel.mlpackage")

# Verify numerics on macOS before shipping:
out = mlmodel.predict({"input": example.numpy()})
```

Notes that bite:
- Provide `inputs=` for PyTorch conversion (defaults to `MLMultiArray`; use `ct.ImageType` for image scale/bias).
- Models whose `forward` returns a dict (DeepLab-style) fail tracing — wrap to return a tensor first.
- Fused `scaled_dot_product_attention` is emitted as a single kernel on macOS 15+ — set the deployment target so the converter can use it.
- For variable length use `EnumeratedShapes` (ANE-friendly) over `RangeDim` (§5).

---

<a name="11-optimization"></a>
## 11. Optimization: quantization and palettization

Compression reduces size, memory, latency, and power. The hardware-aware rules:

- **Palettization (1–8 bit LUT) is generally best on the ANE** for memory + latency.
- **Per-block Int4 weight quant works well on the GPU** (block size 64/32/16).
- **8-bit per-channel weight quant** is the cheap, safe baseline (minutes, little accuracy loss).
- **W8A8 (8-bit activations + weights)** unlocks the fast int8×int8 ANE path on **A17 Pro / M4 and newer**.
- Always benchmark on *your* model × *your* Apple Silicon — decompression strategy is hardware-specific.

Data-free 4-bit palettization on an existing `.mlpackage`:

```python
from coremltools.optimize.coreml import OptimizationConfig, OpPalettizerConfig, palettize_weights
op_config = OpPalettizerConfig(nbits=4)
mlmodel_palettized = palettize_weights(mlmodel, OptimizationConfig(global_config=op_config))
```

Block-wise Int4 weight quant (the Llama/Mistral recipe — ~4× smaller, ~2× faster decode):

```python
import coremltools as ct
op_config = ct.optimize.coreml.OpLinearQuantizerConfig(
    mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32,
)
mlmodel_q = ct.optimize.coreml.linear_quantize_weights(
    mlmodel, ct.optimize.coreml.OptimizationConfig(global_config=op_config)
)
```

For 4-bit with accuracy recovery, use calibration (`GPTQ`) or `SKMPalettizer` (Fisher-weighted, SqueezeLLM-style) from `coremltools.optimize.torch`. The mako stack runs Kokoro at **FLOAT16** with selective int8 palettization on the prosody/text stages and fp32 on the noise/iSTFT tail — precision chosen *per stage* (the laishere split).

---

<a name="12-profiling-and-measuring"></a>
## 12. Profiling and measuring

- **Xcode Core ML performance report** (open the model → Performance tab → `+` → pick device + compute unit → Run). Per-op view: filled check = ran on that unit, hollow = supported-but-skipped, diamond = unsupported. Hover for the "why not ANE" reason. This is how Apple's own latency numbers are taken (median, "all").
- **[CoreMLProfiler](https://github.com/fguzman82/CoreMLProfiler)** — third-party, exports per-op placement + reasons to JSON; works on `.mlpackage` and `.mlmodelc`.
- **Power / engine utilization:** `sudo powermetrics --samplers cpu_power,gpu_power,ane_power` (estimates), or the live TUIs [`asitop`](https://github.com/tlkh/asitop), FluidInference's [`fluidtop`](https://github.com/FluidInference/fluidtop), or sudo-free [`macmon`](https://github.com/vladkens/macmon). ANE figures are *estimated* — fine for relative optimization, not cross-device benchmarking.
- **Process memory (RSS)** for whole-pipeline footprint. mako samples the process tree itself:

```swift
// mac-tts-experiment — Sources/TTSHarnessCore/RSSSampler.swift  (abridged)
public actor RSSSampler {
    public func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                let rss = sampleTreeRSSBytes()           // sums RSS over the process subtree via /bin/ps
                await self?.record(rss)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    public func stop() -> RSSMeasurement {               // returns peak + average
        task?.cancel(); task = nil
        let avg = samples.isEmpty ? 0 : samples.reduce(0, +) / UInt64(samples.count)
        return RSSMeasurement(peakBytes: peak, avgBytes: avg, sampleCount: samples.count)
    }
}
```

This is wired into `mako dev run` to print `wall · peak MB · avg MB` per model — exactly how the README's "RTF ≈10×, peak ~1.35 GB" figures are produced.

---

<a name="13-case-study"></a>
## 13. Case study: how mako runs Kokoro end to end

mako never touches Core ML directly — there is **no `import CoreML`, no `MLModelConfiguration`, no `computeUnits` anywhere in `Sources/`**. It is a clean orchestration layer over `FluidAudio`. Tracing one `mako say`:

**(1) CLI → shared entry point.** `Say` reads text (arg or stdin), guarantees sentence-final punctuation, builds a runner, and gets WAV bytes back:

```swift
// mac-tts-experiment — Sources/mako/Say.swift  (performSay, abridged)
let sentenceEnders: Set<Character> = [".", "!", "?", "…", ":", ";"]
let synthText = sentenceEnders.contains(trimmed.last!) ? trimmed : trimmed + "."

let runner = KokoroFluidAudioRunner(voice: voice)
let wavData = try await runner.synthesizeData(text: synthText)

guard let output else { try playViaAfplay(wav: wavData); return }   // afplay when no -o
// ... else OutputResolver → WAV write or pipe to ffmpeg for M4A ...
```

**(2) Runner → normalization + the actual CoreML manager.** This is the only place the model is invoked. Note it passes **no `computeUnits`**, so it runs on FluidAudio's default `.all` — the path the library warns can hit the macOS 26/27 ANE regression (§3):

```swift
// mac-tts-experiment — Sources/FluidAudioRunner/FluidAudioRunners.swift  (abridged)
public func synthesizeData(text: String) async throws -> Data {
    let (normalized, lexicon) = Self.normalize(text: text)         // ported G2P → SSML + custom lexicon
    let manager = KokoroTtsManager(defaultVoice: voice, customLexicon: lexicon)   // ← no computeUnits passed
    try await manager.initialize()                                 // download/compile/warm (cached after first)
    let voiceSpeed = Float(ProcessInfo.processInfo.environment["KOKORO_SPEED"] ?? "") ?? 1.0
    return try await manager.synthesize(text: normalized, voice: voice, voiceSpeed: voiceSpeed)
}
```

**(3) Backend dispatch.** A registry maps model id → backend → concrete runner (`.fluidAudio` = Kokoro CoreML, `.qwen3TtsCoreML` = CoreML, `.speechSwift` = CosyVoice on **MLX**):

```swift
// mac-tts-experiment — Sources/mako/RunnerFactory.swift
static func make(for entry: ModelEntry) -> Runner {
    switch entry.backend {
    case .fluidAudio:      return KokoroFluidAudioRunner(voice: entry.defaultVoice ?? "af_heart")
    case .speechSwift:     return CosyVoiceRunner()           // MLX, not CoreML
    case .qwen3TtsCoreML:  return Qwen3TTSCoreMLRunner()
    }
}
```

**(4) Inside FluidAudio** the chain is everything in §2–§7: `KokoroTtsManager.initialize()` → `TtsModels.download(computeUnits:)` → `DownloadUtils.loadModelsOnce` (`MLModel(contentsOf:config)`) → `warmUpModel` → `KokoroModelCache` (5s/15s buckets) → `KokoroSynthesizer` fills `MLMultiArray`s → `compatPrediction` → read `audio`/`pred_dur`.

**The single highest-value change for this codebase:** plumb `computeUnits` through `KokoroFluidAudioRunner` (with a `KOKORO_COMPUTE_UNITS` env knob, matching the existing `KOKORO_*` pattern) so you can A/B `.all` vs `.cpuAndGPU` vs `.cpuAndNeuralEngine` on macOS 26/27 without a rebuild — directly testing the documented ANE regression on the user's actual OS.

> Deployment-target note: `Package.swift` pins `.macOS(.v15)`. That's the *minimum*; the binary runs fine on macOS 26/27. To call any macOS-26/27-only Core ML API you'd bump this — but nothing in mako needs to today.

---

<a name="14-macos-27-and-core-ai"></a>
## 14. macOS 27 and Core AI: the successor

> **Beta caveat.** Core AI was announced at **WWDC 2026** (macOS 27 / iOS 27) and is in developer beta. The following is synthesized from Apple's [Core AI developer page](https://developer.apple.com/core-ai/), the [`coreai-torch` docs](https://apple.github.io/coreai-torch/main/), the [`apple/coreai-models`](https://github.com/apple/coreai-models) repo, the WWDC26 "Meet Core AI" session, and press coverage. Names and APIs may shift before public release. **Core ML is not removed** — everything in §1–§13 still ships and runs on macOS 27.

**What Core AI is.** An Apple-Silicon-only, inference-focused framework positioned as Core ML's successor for **neural networks and transformers**, scaling from ~3B vision models to ~70B reasoning LLMs across iPhone/iPad/Mac/Vision Pro. It is driven from **Swift** (the on-device `CoreAI.framework`, macOS/iOS 27) *and* from **Python** (the `coreai.runtime` module in the `coreai-core` pip wheel, which also runs on macOS 26 — §14b); authoring, conversion, and optimization are Python (`coreai-torch`, `coreai-opt`). It's the same technology underpinning Apple Intelligence, now opened to "custom intelligence."

**The three-way split Apple now suggests:**

| Framework | Use for |
|---|---|
| **Core ML** | "Classic," non-neural ML — decision trees, tabular, feature engineering — and everything you already ship |
| **Core AI** | Neural nets, transformers, on-device LLMs/generative |
| **MLX (Swift)** | Custom weights / research / training; also the build-pipeline layer that produces model files |

**Conversion pipeline (`coreai-torch`)** — built on `torch.export`, not `jit.trace`:

```python
import torch
from coreai_torch import TorchConverter, get_decomp_table

model = MyModel().eval()
ep = torch.export.export(model, args=(torch.randn(1, 10),))   # capture the FX graph
ep = ep.run_decompositions(get_decomp_table())

coreai_program = TorchConverter().add_exported_program(ep).to_coreai()
coreai_program.optimize()                                     # quant/palettization tuned to the Core AI runtime
# → exported as a standalone .aimodel / .aiasset file
```

- `coreai_torch.composite_ops` ships attention, RoPE, RMSNorm, and gather-matmul (MoE) as PyTorch modules; `register_torch_lowering` handles unsupported ops; `register_custom_kernels` lets you wire in Metal kernel source.
- Authoring rules in `coreai-models` cover **BC1S layout**, op compatibility, **KV-cache patterns**, precision rules, MoE, common pitfalls — i.e. the §4/§8 lessons, formalized.

**Runtime shape:** load `.aimodel` → one-time device specialization (cached; first run slow, like Core ML's §7) → instantiate an `InferenceFunction`/`AIModel` → run with `NDArray` I/O. The **Swift** runtime (the on-device `CoreAI.framework`, the `llm-runner` CLI, the pipelined LLM engine) requires **macOS 27 / Xcode 27**; the **Python** runtime (`coreai.runtime`, from the `coreai-core` pip wheel) runs the same `.aimodel` assets on **macOS 26 (Tahoe)** for static-shape models — see [§14b](#14b-core-ai-on-macos-26). Profile/push via "Device Hub."

<a name="14a-worked-example-qwen3-moe"></a>
### Worked example: running a large MoE LLM — `Qwen3.6-35B-A3B-CoreAI`

[`mlboydaisuke/Qwen3.6-35B-A3B-CoreAI`](https://huggingface.co/mlboydaisuke/Qwen3.6-35B-A3B-CoreAI) is exactly the class of model Core AI exists for and Core ML cannot host well: a **256-expert top-8 sparse MoE** (plus a shared expert), **35B total params / ~3B active per token**, GatedDeltaNet + gated-attention. It ships as a single Core AI bundle `gpu-pipelined/qwen3_6_35b_a3b_decode_sym8_gather/` (**~35 GB**, symmetric int8, per-K-block-32). It is **Mac-only** — 35 GB int8 is well past any iPhone budget; this is a 64/128 GB Apple-Silicon Mac model. Reported ~**64.9 tok/s** decode via a custom `gather_qmm` Metal kernel that reads only the 8 routed experts' weight slabs (8/256) instead of all 256 — that's the whole point of an "A3B" model: pay bandwidth for ~3B active weights, not 35B.

> **⚠️ OS requirement — this specific model needs macOS 27; it does *not* run on Tahoe 26.** The `qwen3_6_35b_a3b_decode_sym8_gather` bundle is a **`gpu-pipelined` decode graph with dynamic-shaped outputs** (`input_ids` is static `[1,1]`, but `position_ids` and the growing KV sequence are dynamic). Apple's `EngineFactory` therefore routes it to the **`CoreAIPipelinedEngine`**, which exists **only in the Swift runtime** — and the community zoo is explicit that *"the python runtime cannot execute dynamic-shaped-output graphs at all"* (zoo `knowledge/pipelined-engine.md` — [GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/pipelined-engine.md), local `./coreai-model-zoo/knowledge/pipelined-engine.md`). Because that Swift runtime declares `.macOS("27.0")` and links the OS `CoreAI.framework`, **the shipped pipelined bundle runs only on macOS 27** (via `llm-runner`/`llm-benchmark` or CoreAIChatMac), and installing Xcode 27 on Tahoe does **not** unlock it (Xcode gives you the SDK/AOT compiler, not the OS runtime). **But the model itself is not locked to 27:** re-export the decoder as a **static-S=1 twin** and drive it with a Python `coreai.runtime` decode loop, and it runs on **Tahoe 26** — the Unlimited-OCR MoE pattern (see [§14c](#14c-llm-on-macos-26)). You trade the fast Swift pipelined engine for a slower hand-written Python loop. For static vision/embedding models on 26, see [§14b](#14b-core-ai-on-macos-26).

The three ways to run it below all assume **macOS 27**, from "works today on the command line" to "in your app."

**Path A — run it directly on a Mac (CLI, concrete).** The `.aimodel` bundle is **MLIR IR**; macOS *JIT-compiles it at load* (no AOT step needed — this is why the 35 GB MoE is a Mac target and not iOS, which cannot JIT). With Xcode 27 + the `coreai-models` Swift package's CLI tools, the model card's own invocation is:

```sh
# Benchmark/run the bundle. -p prompt tokens, -g generated tokens, -n repeats.
# COREAI_CHUNK_THRESHOLD=1 enables the chunked MoE decode path.
COREAI_CHUNK_THRESHOLD=1 llm-benchmark \
  --model gpu-pipelined/qwen3_6_35b_a3b_decode_sym8_gather -p 128 -g 256 -n 3

# Interactive generation from the same Swift package:
llm-runner --model gpu-pipelined/qwen3_6_35b_a3b_decode_sym8_gather --prompt "Explain MoE routing."
```

And the upstream export/registry workflow (`apple/coreai-models`, uses `uv`), in case you convert your own instead of downloading:

```sh
uv run coreai.model.registry --list-models --type llm        # discover convertible LLMs
uv run coreai.llm.export Qwen/Qwen3-0.6B                      # export → .aimodel (macOS: dynamic KV cache, full context)
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS       # iOS variant (static-shape, AOT-compiled)
```

**Path B — integrate in an app (high-level, recommended).** Core AI's LLM wrapper collapses asset loading + engine creation + tokenizer setup into one line, and then you drive it with the *same* `LanguageModelSession` API used for Apple's built-in Foundation Model — including `@Generable` typed output:

```swift
// Illustrative per Apple's WWDC26 "Meet Core AI"; confirm exact initializers against Apple's Core AI docs.
import CoreAI
import FoundationModels

let model = try CoreAILanguageModel(url: bundleURL)        // loads .aimodel, builds engine, wires tokenizer
let session = LanguageModelSession(model: model)
let answer = try await session.respond(to: "Summarize this transcript: \(text)")

@Generable struct Lesson { let title: String; let steps: [String] }
let lesson = try await session.respond(to: prompt, generating: Lesson.self)   // typed, schema-constrained
```

**Path C — low-level runtime (full control over compute units + KV cache).** When you need to pick the engine or manage state yourself, the runtime is `AIModelAsset` (cheap inspection) → `AIModel` (device-specialized, cached) → `InferenceFunction` (one runnable graph) → `NDArray` I/O. The KV cache is passed as **stateful `MutableView`s** that the model reads and updates **in place** each step — the Core AI analogue of Core ML's `MLState` (§8a):

```swift
// Illustrative — API names per third-party WWDC26 write-ups; verify against Apple's Core AI documentation.
import CoreAI

let asset = try AIModelAsset(url: bundleURL)                       // .aimodel on disk (MLIR IR)
var options = SpecializationOptions()
options.computeUnit = .gpu                                         // .cpu | .gpu | .neuralEngine
let model = try await AIModel(asset: asset, options: options)      // one-time device specialization, then cached
let infer = try model.inferenceFunction()                          // Sendable → can run concurrently

// Allocate KV cache buffers once; hand the model mutable views so it updates them in-place.
var kCache = NDArray(descriptor: kvDescriptor)
var vCache = NDArray(descriptor: kvDescriptor)

func step(_ tokenIds: NDArray, _ positions: NDArray) throws -> NDArray {
    let out = try infer.run(
        inputs: ["input_ids": tokenIds, "positions": positions],
        states: [kCache.mutableView(), vCache.mutableView()]      // read + written in place (KV cache)
    )
    return out["logits"]!
}
// Prefill the prompt once, then greedy/sampled decode one token at a time (cf. §8a's Qwen3-ASR loop).
```

**Why this is Core AI and not Core ML.** A 35B MoE needs: expert-routing kernels (`coreai_torch.composite_ops` gather-matmul + a custom `gather_qmm` Metal kernel via `register_custom_kernels`), dynamic-context KV cache as stateful I/O, int8 per-block weights, and a runtime that JITs MLIR and dispatches across GPU/ANE at this scale — none of which Core ML's op set or `.mlmodelc` pipeline targets. This is the dividing line: **Kokoro/Qwen3-TTS stay on Core ML; a model like Qwen3.6-35B-A3B runs on Core AI.** On macOS 27 the two coexist in one process — you can serve TTS through `FluidAudio`/Core ML and an LLM through Core AI side by side.

**Practical guidance for the mako-style app on macOS 27:** keep Kokoro/Qwen3-TTS on Core ML (they work, they're tuned, they don't need Core AI). Reach for Core AI only when you add a genuinely LLM-class model — e.g. an on-device rewrite/cleanup model in the ectoboy sense, or exactly a `Qwen3.6-35B-A3B`-style assistant — where MoE routing, dynamic KV cache, and 35–70B-scale dispatch are the requirement. Don't port working Core ML TTS to Core AI for its own sake during beta.

<a name="14b-core-ai-on-macos-26"></a>
### Running Core AI on macOS 26 (Tahoe) without macOS 27 — the Python path

> **Local reference for §14b–§14c.** The primary sources cited below are checked out in this repo at [`./coreai-model-zoo/`](coreai-model-zoo) (cloned from [github.com/john-rocky/coreai-model-zoo](https://github.com/john-rocky/coreai-model-zoo)). Paths like `knowledge/…` and `conversion/…` are relative to that clone, e.g. `./coreai-model-zoo/knowledge/pipelined-engine.md`; each citation also links to its source on GitHub.

You do **not** have to install the macOS 27 beta to run *some* Core AI `.aimodel` models. Core AI ships **two independent runtimes**, and they have different OS floors:

| Runtime | What it is | Where it comes from | OS floor | Runs on Tahoe 26? |
|---|---|---|---|---|
| **Python `coreai.runtime`** | `AIModel.load` → `load_function` → `NDArray` I/O | the `coreai-core` **pip wheel** (self-contained; talks to Metal/MPSGraph directly) | **macOS 26.0** | ✅ yes — *static-shape* models |
| **Swift `CoreAI.framework`** | `AIModel`/`InferenceFunction`, the `llm-runner`/`llm-benchmark` CLI, `CoreAILanguageModel`, the pipelined LLM engine, all on-device iOS | ships **with the OS**; built/linked via **Xcode 27** | **macOS 27.0** | ❌ no |

**The decisive evidence.** Apple's own `coreai-core` wheels on PyPI ([`1.0.0b1`](https://pypi.org/project/coreai-core/) · [JSON metadata](https://pypi.org/pypi/coreai-core/json)) are tagged **`macosx_26_0_arm64`** for both cp311 and cp312 (`requires-python >=3.10,<3.14`). A `macosx_26_0` wheel is built against the macOS 26 SDK and installs/runs on Tahoe. The community knowledge base agrees: *"macOS is enough to convert + run (Python) + numerically verify. On-device iOS / the Swift runtime / the AOT compiler (`aimodelc`, shipped in Xcode 27) need iOS/macOS 27."* (zoo `knowledge/coreai-overview.md` — [GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/coreai-overview.md), local `./coreai-model-zoo/knowledge/coreai-overview.md`)

> **"Can't I just install Xcode 27?"** You *can* — [Xcode 27 beta installs on **macOS 26.4+**](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) (Apple-Silicon only; run it inline with `DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer`, no `sudo`, no `xcode-select` — zoo `knowledge/swift-runtime.md`, [GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/swift-runtime.md), local `./coreai-model-zoo/knowledge/swift-runtime.md`). But Xcode only gives you the **SDK + AOT compiler** (`xcrun coreai-build` / `aimodelc`) — it does **not** let you *run* the Swift `CoreAI.framework` on Tahoe, because that framework ships **with macOS 27 itself** (its symbols are `@available(macOS 27.0, *)`), not with Xcode. So Xcode 27 on Tahoe is for *building / AOT-compiling*, not for *running on the Mac*. The thing that actually executes models on Tahoe is the **Python wheel**.

#### Exactly how to run a Core AI model on Tahoe 26

```sh
# 1. Install the self-contained Python runtime (no Xcode, no macOS 27 needed).
uv pip install coreai-core          # or: pip install coreai-core
# (uv is the project default; the wheel is coreai_core-1.0.0b1-cp31x-macosx_26_0_arm64.whl)

# 2. Download a pre-converted, STATIC-shape .aimodel bundle from Hugging Face.
#    Good Tahoe-26 candidates: vision / embedding / depth / segmentation models.
huggingface-cli download mlboydaisuke/Depth-Anything-3-CoreAI \
  --include "small/*" --local-dir ./da3-coreai
```

```python
# 3. Load + run it with coreai.runtime — this is the path that works on macOS 26.
#    (Shape of the Depth-Anything-3 card's own documented usage example.)
import coreai.runtime as rt, numpy as np
from PIL import Image

model = await rt.AIModel.load(
    "da3-coreai/small/da3-small_float16.aimodel",
    rt.SpecializationOptions.from_preferred_compute_unit_kind(rt.ComputeUnitKind.gpu()),
)
fn = model.load_function("main")

img = np.asarray(Image.open("photo.jpg").convert("RGB").resize((504, 504)))
x = (img.astype(np.float16) / 255.0).transpose(2, 0, 1)[None]      # raw [0,1], NCHW
depth = (await fn({"image": rt.NDArray(x)}))["depth"].numpy().reshape(504, 504)
```

That is the whole story for static models: `pip install coreai-core`, download a `.aimodel`, then `AIModel.load` → `load_function` → `NDArray`. No Xcode, no macOS 27. The runtime still does a one-time device specialization on first load (§7's warmup lesson applies). For a glue tier you can also pin the compute unit via `SpecializationOptions` (`ComputeUnitKind.cpu()/.gpu()/.neuralEngine()`).

A ready-made version of this exact script ships in the clone at `./coreai-model-zoo/knowledge/scripts/depth_anything_3_sample.py` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/scripts/depth_anything_3_sample.py)), and a generic per-compute-unit CV latency bench is at `./coreai-model-zoo/knowledge/scripts/bench_cv_aimodel.py` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/scripts/bench_cv_aimodel.py)) — both drive the Python `coreai.runtime` and run on Tahoe 26.

#### What actually runs on Tahoe 26 vs what needs macOS 27

| You want to… | Tahoe 26 (Python `coreai.runtime`) | Needs macOS 27 |
|---|---|---|
| Run a **static-shape** model (vision, depth, segmentation, CLIP/embeddings, encoders) | ✅ yes | — |
| **Convert** PyTorch/ONNX → `.aimodel` (`coreai-torch`, `coreai-opt`) | ✅ yes (conversion even runs on Linux) | — |
| Numerically **verify** an exported asset | ✅ yes | — |
| Run a **pre-built dynamic-output LLM bundle** (`gpu-pipelined/*`, e.g. Qwen3.6-35B-A3B as shipped) | ❌ **no** — the Python runtime *"cannot execute dynamic-shaped-output graphs at all"* | ✅ Swift pipelined engine, macOS 27 |
| Run an LLM/MoE decoder as a **static-S=1 twin** via a Python decode loop (§14c) | ✅ **yes, with effort** — export the twin yourself (the Unlimited-OCR MoE pattern) | — |
| Use the `llm-runner` / `llm-benchmark` CLI or `CoreAIChatMac` | ❌ no (the Swift package declares `.macOS("27.0")`) | ✅ |
| **AOT-compile** (`aimodelc`) or deploy **on-device iOS** | ❌ no (needs the Xcode 27 / iOS 27 SDK) | ✅ |
| Use `CoreAILanguageModel` + `LanguageModelSession` (§14a Path B) | ❌ no | ✅ |

#### Honest caveats

- **Officially unsupported.** Apple's `apple/coreai-models` README states *"Requirements (running and app integration): macOS and iOS 27.0+, Xcode 27.0+."* The macOS-26 Python path works because the wheel is *built* for 26, but Apple only blesses 27 — expect rough edges, and note that some model cards (e.g. CLIP ViT-B/32) assume the Swift/27 path and say "Requires macOS 27 beta." Verify each asset on your own machine.
- **Everything is beta** (`coreai-core 1.0.0b1`); the public/GA toolchain is expected ~Sept 2026. If your only goal is to avoid *beta software*, waiting for GA is the zero-effort option.
- **Tahoe is *not* slower — it's currently faster.** Correcting an earlier draft of this note: the zoo's export forensics (`knowledge/apple-models-bench.md` — [GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/apple-models-bench.md), local `./coreai-model-zoo/knowledge/apple-models-bench.md`) found the *same* `coreai.llm.export qwen3-0.6b` produces a **~2.2× faster artifact when exported on macOS 26 than on the 27 beta** (26 uses native quantized-Linear lowering; the 27β toolchain emits explicit dequant ops — same code, same wheels). On the device A/B that artifact shows **~2× decode, ~3.8× prefill, and half the memory** of the 27β one. It's a beta-era lowering quirk that may normalize at GA, but today Tahoe is an export *advantage*, not a downgrade.
- **LLMs DO run on 26 — just not the pre-built pipelined bundles.** The `gpu-pipelined/*` download bundles (e.g. Qwen3.6-35B-A3B) are dynamic-output and need the Swift pipelined engine (macOS 27). But an LLM/MoE decoder in **static-S=1 stateful form** runs on the macOS-26 Python runtime — see [§14c](#14c-llm-on-macos-26) for the recipe and the working `generate.py` proof. For a *turnkey* LLM on Tahoe with zero export work, MLX or llama.cpp remain the easy path.

<a name="14c-llm-on-macos-26"></a>
### Running an actual LLM on Tahoe 26 — the static-S=1 Python decode loop

The "no LLMs on 26" wall is **only** about *pre-built `gpu-pipelined` bundles*, whose dynamic-output decode graph the Python runtime refuses (*"the python runtime cannot execute dynamic-shaped-output graphs at all — gate via a static-S=1 twin bundle"*). The escape — stated by the zoo and proven by working code — is to run a **fully-static, stateful decode graph** driven by a host-side loop. This is exactly how the zoo ports a **DeepseekV2 MoE** decoder (`baidu/Unlimited-OCR`, with a custom sym8 `gather_qmm` Metal kernel) onto the **stock `coreai.runtime` — no engine patch, no Swift** — and it was developed specifically to survive the **Metal 4 / macOS 26** dynamic-shape fault. (zoo `knowledge/unlimited-ocr-rswa-static-decode.md` — [GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/unlimited-ocr-rswa-static-decode.md), local `./coreai-model-zoo/knowledge/unlimited-ocr-rswa-static-decode.md`; the dynamic-output limit and the "gate via a static-S=1 twin bundle" line are in `./coreai-model-zoo/knowledge/pipelined-engine.md`, [GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/pipelined-engine.md).)

**The principle (why it runs on 26).** Make *no tensor shape ever change* across decode steps, so the engine compiles once and never hits the macOS-26 recompile fault (`Failed to import MPS module` / `MTL4CommandQueueErrorDomain error 1` on the 2nd distinct shape):
- decode inputs are `inputs_embeds [1,1,H]` + **`pos [1]` (int32 — the absolute position as a runtime *value*, not a shape)**;
- the KV cache is a Core AI **state** (a fixed `[L,1,Hkv,buf,d]` buffer mutated in place); the write offset is *data-driven* from `pos` via `mutable_slice_update`, which lowers to the GPU with no recompile across offsets;
- attention reads the **whole** fixed buffer and applies a visibility mask, instead of a growing `cache[0:seq_len]` slice.

**The decode loop** — adapted from the zoo's [`conversion/unlimited_ocr/generate.py`](https://github.com/john-rocky/coreai-model-zoo/blob/main/conversion/unlimited_ocr/generate.py) (local `./coreai-model-zoo/conversion/unlimited_ocr/generate.py`), a *real* autoregressive MoE generate on `coreai.runtime`:

```python
import asyncio, numpy as np, torch
import coreai.runtime as rt
from tokenizers import Tokenizer

async def generate(bundle, tokenizer_json, prefix_embeds, embed_tokens, k0, v0, Lm, eos=1, max_new=600):
    tok = Tokenizer.from_file(tokenizer_json)
    m = await rt.AIModel.load(                               # macOS 26 OK — coreai-core wheel is macosx_26_0
        bundle,
        rt.SpecializationOptions.from_preferred_compute_unit_kind(rt.ComputeUnitKind.gpu()),
    )                                                        # NB: cpu_only won't compile the MoE metal kernel graph
    fn_prefill, fn_decode = m.load_function("prefill"), m.load_function("decode")

    state = {"k_cache": rt.NDArray(k0), "v_cache": rt.NDArray(v0)}   # KV cache = Core AI state, mutated in place

    out = await fn_prefill(inputs={"inputs_embeds": rt.NDArray(prefix_embeds)}, state=state)
    tok_id, gen = int(np.argmax(out["logits"].numpy().reshape(-1))), []

    for p in range(Lm, Lm + max_new):                        # one token at a time; every shape stays static
        gen.append(tok_id)
        if tok_id == eos:
            break
        emb = embed_tokens(torch.tensor([[tok_id]])).to(torch.float16).numpy()       # host-side embed lookup
        out = await fn_decode(
            inputs={"inputs_embeds": rt.NDArray(np.ascontiguousarray(emb)),
                    "pos": rt.NDArray(np.int32([p]))},        # pos is a VALUE, not a shape
            state=state,
        )
        tok_id = int(np.argmax(out["logits"].numpy().reshape(-1)))
    return tok.decode([t for t in gen if t != eos])
```

**Applying this to `Qwen3.6-35B-A3B` specifically.** The *shipped* HF bundle is the pipelined (dynamic) form, so that download is macOS-27-only. To run the model on Tahoe 26 you build a **static-S=1 twin** of the decoder (the zoo builds exactly these twins to "gate" every model; prefill + decode are staged into one bundle that *shares a single sym8 weight set*, so it stays ~35 GB, not 70). Then drive it with the loop above. Reality check:
- **RAM:** a 35 GB int8 MoE wants a **64/128 GB Apple-Silicon Mac** (weights mmap; decode only reads the ~3B active params/token).
- **Speed:** you lose the Swift pipelined engine (async encode, on-GPU argmax, 3-deep pipeline), and static-S=1 **prefill is one token at a time** — slow for long prompts (the zoo calls chunked static prefill "a future lever"). Static *decode* is flat and fine (the OCR MoE measures ~12.7 ms/token this way).
- **Quality:** keep **consistent sym8** across prefill and decode, and use **`no_repeat_ngram`** — greedy MoE decode derails into repeats otherwise (both are in `generate.py`).
- **Effort:** this is the "works with effort" tier — you export a custom twin and write the host loop / tokenizer / prefix assembly yourself. For a turnkey LLM on Tahoe *today*, MLX/llama.cpp are less work; reach for this when you specifically want the **Core AI** runtime on macOS 26.

> **Bottom line:** there *is* a way to run an LLM-class Core AI model on Tahoe 26 — a static-S=1 stateful decode graph on the Python runtime. It is not the one-line `llm-runner` experience (that's the Swift/27 path), but it is a real, code-proven path, and exporting on Tahoe currently yields the *faster* artifact.

---

<a name="15-pitfalls-and-checklist"></a>
## 15. Pitfalls and a pre-ship checklist

**Pitfalls (each cost real time in the stacks above):**
- Loading `.mlpackage` in production → compile-on-load every launch. Ship `.mlmodelc`.
- Assuming `.cpuAndNeuralEngine` ⇒ ANE. It doesn't; profile to confirm.
- `RangeDim` flexible shapes silently dropping off the ANE (10×+ slowdown). Use `EnumeratedShapes` / fixed buckets.
- Re-creating the model manager per request → re-paying warmup. Cache the loaded `MLModel`.
- macOS/iOS **26/27 ANE compiler regression** (`"Cannot retrieve vector from IRValue format int32"`). Make compute units configurable; fall back to `.cpuAndGPU`.
- Two configs = two cache specializations = double disk + double first-load cost. Keep config stable.
- `MLTensor` in a hot loop (it's GPU, op-by-op, slow). Use raw `MLMultiArray` + `Accelerate` for inner loops.
- Adding a KV cache / stateful state to a non-autoregressive model. Pointless; Kokoro needs none.

**Checklist:**
- [ ] Distribute compiled `.mlmodelc` at a stable, non-purgeable path.
- [ ] `MLModelConfiguration`: `allowLowPrecisionAccumulationOnGPU = true`; `computeUnits` **configurable**, default chosen per OS.
- [ ] Fixed or `EnumeratedShapes` inputs; verify ANE residency in Xcode's performance report.
- [ ] Warm each model with a representative zero-input prediction at the real shapes.
- [ ] Cache loaded `MLModel`s for the process lifetime (actor or singleton).
- [ ] Autoregressive? Use `MLState` (macOS 15+) or a manual model-I/O cache; prefill once, decode one-at-a-time.
- [ ] Compress: 8-bit/per-channel baseline; palettization for ANE; per-block Int4 for GPU; benchmark on target silicon.
- [ ] Measure wall time, RTF, peak RSS, and ANE/GPU power before declaring a config "best."
- [ ] On macOS 27, decide Core ML vs Core AI per model — don't migrate working Core ML during beta.

---

<a name="16-sources"></a>
## 16. Sources

**Code quoted in this dossier**
- `mac-tts-experiment` (mako): `Sources/mako/Say.swift`, `Sources/mako/RunnerFactory.swift`, `Sources/FluidAudioRunner/FluidAudioRunners.swift`, `Sources/TTSHarnessCore/RSSSampler.swift`, `Sources/mako/KokoroSmooth.swift`, `Package.swift`.
- `FluidAudio` 0.13.6 (resolved dependency): `DownloadUtils.swift`, `Shared/MLModelConfigurationUtils.swift`, `Shared/ModelWarmup.swift`, `Shared/MLModel+Prediction.swift`, `TTS/TtsModels.swift`, `TTS/Kokoro/KokoroTtsManager.swift`, `TTS/Kokoro/Pipeline/Preprocess/KokoroModelCache.swift`, `TTS/Kokoro/Pipeline/Synthesize/KokoroSynthesizer.swift`, `TTS/Kokoro/Pipeline/Synthesize/KokoroSynthesizer+ModelUtils.swift`, `ASR/Qwen3/Qwen3AsrManager.swift`, `TTS/PocketTTS/Pipeline/PocketTtsSynthesizer+KVCache.swift`.

**Apple — Core ML & research**
- [Core ML | Apple Developer](https://developer.apple.com/machine-learning/core-ml/) · [MLComputeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits) · [MLTensor](https://developer.apple.com/documentation/coreml/mltensor)
- [On-device Llama 3.1 with Core ML](https://machinelearning.apple.com/research/core-ml-on-device-llama) · [Deploying Transformers on the ANE](https://machinelearning.apple.com/research/neural-engine-transformers)
- WWDC: [Optimize your Core ML usage (22)](https://developer.apple.com/videos/play/wwdc2022/10027/) · [Async prediction (23)](https://developer.apple.com/videos/play/wwdc2023/10049/) · [Deploy ML/AI models on-device (24)](https://developer.apple.com/videos/play/wwdc2024/10161/)

**Core ML Tools**
- [Stateful models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html) · [Flexible input shapes](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html) · [PyTorch conversion](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html) · [Optimization overview](https://apple.github.io/coremltools/docs-guides/source/opt-overview.html) · [Quantization algorithms](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-algos.html)

**TTS / model specifics**
- [FluidAudio](https://github.com/FluidInference/FluidAudio) · [FluidInference/kokoro-82m-coreml](https://huggingface.co/FluidInference/kokoro-82m-coreml) · [laishere/kokoro-coreml](https://github.com/laishere/kokoro-coreml) · [ml-ane-transformers](https://github.com/apple/ml-ane-transformers) · [Running Mistral 7B with Core ML](https://huggingface.co/blog/mistral-coreml)

**Profiling**
- [CoreMLProfiler](https://github.com/fguzman82/CoreMLProfiler) · [asitop](https://github.com/tlkh/asitop) · [fluidtop](https://github.com/FluidInference/fluidtop) · [macmon](https://github.com/vladkens/macmon)

**macOS 27 / Core AI (beta)**
- [Core AI | Apple Developer](https://developer.apple.com/core-ai/) · [coreai-torch docs](https://apple.github.io/coreai-torch/main/) · [apple/coreai-models](https://github.com/apple/coreai-models) · [Meet Core AI — WWDC26](https://developer.apple.com/videos/play/wwdc2026/324/) · [Integrate on-device AI with Core AI — WWDC26](https://developer.apple.com/videos/play/wwdc2026/326/) · [Apple launches Core AI (InfoQ)](https://www.infoq.com/news/2026/06/apple-core-ai-wwdc/)
- Worked example: [mlboydaisuke/Qwen3.6-35B-A3B-CoreAI](https://huggingface.co/mlboydaisuke/Qwen3.6-35B-A3B-CoreAI) · [john-rocky/coreai-model-zoo](https://github.com/john-rocky/coreai-model-zoo) · [coreai-models getting started (DeepWiki)](https://deepwiki.com/apple/coreai-models/1.1-getting-started) · [Core AI: Running Models on Apple Silicon (Crosley)](https://blakecrosley.com/blog/core-ai-run-models-apple-silicon) · [Core AI vs MLX benchmark (MLBoy)](https://rockyshikoku.medium.com/i-benchmarked-apples-new-framework-against-mlx-for-on-device-llms-e52a769494b1)
- **Running Core AI on macOS 26 (Python path) — primary sources.** Local clone (kept as reference): `./coreai-model-zoo/` ([github.com/john-rocky/coreai-model-zoo](https://github.com/john-rocky/coreai-model-zoo)).
    - *Wheel floor (macOS 26):* [`coreai-core` on PyPI — wheels tagged `macosx_26_0_arm64`](https://pypi.org/project/coreai-core/) · [PyPI JSON metadata](https://pypi.org/pypi/coreai-core/json) · [`coreai.runtime` docs](https://apple.github.io/coreai-torch/main/coreai-core/)
    - *Static-S=1 LLM decode on the Python runtime (§14c):* `./coreai-model-zoo/conversion/unlimited_ocr/generate.py` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/conversion/unlimited_ocr/generate.py)) · `./coreai-model-zoo/knowledge/unlimited-ocr-rswa-static-decode.md` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/unlimited-ocr-rswa-static-decode.md)) · `./coreai-model-zoo/knowledge/stateful-kv-cache.md` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/stateful-kv-cache.md))
    - *Pipelined/dynamic-output limit + "gate via static-S=1 twin":* `./coreai-model-zoo/knowledge/pipelined-engine.md` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/pipelined-engine.md))
    - *Two-runtime split + "macOS is enough to run (Python)":* `./coreai-model-zoo/knowledge/coreai-overview.md` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/coreai-overview.md)) · *Swift floor / Xcode-27-on-26.4:* `./coreai-model-zoo/knowledge/swift-runtime.md` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/swift-runtime.md)) · [Xcode 27 requires macOS 26.4+](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
    - *macOS 26 is faster (export-lowering A/B):* `./coreai-model-zoo/knowledge/apple-models-bench.md` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/apple-models-bench.md))
    - *Python CV runtime samples (run on 26):* `./coreai-model-zoo/knowledge/scripts/depth_anything_3_sample.py` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/scripts/depth_anything_3_sample.py)) · `./coreai-model-zoo/knowledge/scripts/bench_cv_aimodel.py` ([GitHub](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/scripts/bench_cv_aimodel.py))
    - *Pre-converted bundles:* [Depth-Anything-3-CoreAI](https://huggingface.co/mlboydaisuke/Depth-Anything-3-CoreAI) · [Unlimited-OCR-CoreAI](https://huggingface.co/mlboydaisuke/Unlimited-OCR-CoreAI) · [Qwen3.6-35B-A3B-CoreAI](https://huggingface.co/mlboydaisuke/Qwen3.6-35B-A3B-CoreAI) · [HN: "Requires OS 27+"](https://news.ycombinator.com/item?id=48449665)
</content>
</invoke>
