# Parakeet Model Download Size Analysis

When downloading Parakeet models from HuggingFace, the total repository sizes (e.g., 2.99 GB for v3) do not reflect the actual data downloaded to the user's machine. The `FluidAudio` package selectively downloads only the specific components required for execution in the requested precision (defaulting to int8).

This reduces the effective download size significantly:
- **Parakeet v2**: ~464 MB
- **Parakeet v3**: ~483 MB

Here is the exact trace of how the `FluidAudio` package determines which files to pull from the remote repository.

## 1. The Download Request (`DownloadUtils.swift`)

The download process begins in `DownloadUtils.downloadRepo`. Instead of pulling the entire repository blindly, it queries the `ModelNames` structure to ask for a specific list of required files for the target repository variant.

[DownloadUtils.swift:L382](file:///Users/sher/Development/OpenSuperWhisper2/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/DownloadUtils.swift#L382)
```swift
let requiredModels = ModelNames.getRequiredModelNames(for: repo, variant: variant)
```

The script then constructs a list of URL path patterns from this `requiredModels` set. It uses the HuggingFace API to list the repository tree, filtering the server's response to **only download files that match the requested paths** (ignoring anything else).

## 2. Resolving Required Models (`ModelNames.swift`)

The `ModelNames.getRequiredModelNames` function maps a specific HuggingFace repository (`Repo` enum) to its exact file requirements.

[ModelNames.swift:L1220-L1228](file:///Users/sher/Development/OpenSuperWhisper2/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ModelNames.swift#L1220-L1228)
```swift
public static func getRequiredModelNames(for repo: Repo, variant: String? = nil) -> Set<String> {
    switch repo {
    // ...
    case .parakeetV3:
        let precision = ParakeetEncoderPrecision(rawValue: variant ?? "") ?? .int8
        return ModelNames.ASR.requiredModelsV3(precision: precision)
    case .parakeetV2:
        return ModelNames.ASR.requiredModels
    // ...
}
```

This acts as a router, directing `.parakeetV2` to `ModelNames.ASR.requiredModels` and `.parakeetV3` to `ModelNames.ASR.requiredModelsV3(precision:)`.

## 3. The Hardcoded File Lists (`ModelNames.swift`)

Inside the `ModelNames.ASR` namespace, the explicit `.mlmodelc` CoreML component directories are defined:

[ModelNames.swift:L323-L338](file:///Users/sher/Development/OpenSuperWhisper2/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ModelNames.swift#L323-L338)
```swift
public static let preprocessorFile = "Preprocessor.mlmodelc"
public static let encoderFile = "Encoder.mlmodelc"
public static let decoderFile = "Decoder.mlmodelc"
public static let jointFile = "JointDecision.mlmodelc"
public static let jointV3File = "JointDecisionv3.mlmodelc"
public static let encoderInt4File = "EncoderInt4.mlmodelc"
```

These string constants are then grouped into the sets that are returned to the downloader:

### For Parakeet v2
The v2 model requests the standard legacy set of 4 CoreML packages.

[ModelNames.swift:L344-L349](file:///Users/sher/Development/OpenSuperWhisper2/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ModelNames.swift#L344-L349)
```swift
public static let requiredModels: Set<String> = [
    preprocessorFile, // "Preprocessor.mlmodelc"
    encoderFile,      // "Encoder.mlmodelc"
    decoderFile,      // "Decoder.mlmodelc"
    jointFile,        // "JointDecision.mlmodelc"
]
```

### For Parakeet v3
The v3 model requests the v3-specific joint network (which includes top-K heads for language filtering) and selects the encoder based on precision (defaulting to the int8 encoder, `ParakeetEncoder.mlmodelc`). 

[ModelNames.swift:L351-L360](file:///Users/sher/Development/OpenSuperWhisper2/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ModelNames.swift#L351-L360)
```swift
public static func requiredModelsV3(precision: ParakeetEncoderPrecision = .int8) -> Set<String> {
    [
        preprocessorFile,          // "Preprocessor.mlmodelc"
        precision.encoderFileName, // "ParakeetEncoder.mlmodelc" (int8)
        decoderFile,               // "Decoder.mlmodelc"
        jointV3File,               // "JointDecisionv3.mlmodelc"
    ]
}
```

## Conclusion

Because `DownloadUtils` selectively queries the HuggingFace API based on the explicit sets returned by `ModelNames`, it never downloads the unused variants stored in the repository.

For example, when downloading Parakeet v3 (int8), the downloader ignores:
- `EncoderInt4.mlmodelc` (the 4-bit encoder alternative)
- `JointDecision.mlmodelc` (the legacy joint network)
- Various uncompiled model graphs or raw PyTorch checkpoints if present

This targeted fetching is what drops the total downloaded size down from the repository's aggregate 2.99 GB to the ~483 MB actually written to disk.
