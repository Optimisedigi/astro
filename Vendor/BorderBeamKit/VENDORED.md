Vendored from https://github.com/Jakubantalik/Libraries
path: packages/border-beam/ports/ios/BorderBeamKit
commit: cb9e9b06c54bff3281abe4072a82d4b246dfd093
license: MIT (see LICENSE)
Local change: test target removed from Package.swift.
Local change: `beamFrozenTime(_:)` view modifier made public (BeamFrozenTime.swift) so the app can render still snapshots offscreen.
Local change: the rotate family (sm/md) now honours BeamTuning.strokeOpacity / innerOpacity / bloomOpacity, matching the web library (styles.ts applies --beam-*-opacity to every family). RotateBeamLayers.swift, BorderBeam.swift.
Local change: RotateBeamConfig.layerOpacities holds the per-layer opacity maths (used by the layers), exposed read-only as borderBeamLayerOpacities(...) for consumer tests. BorderBeam.swift, RotateBeamLayers.swift.
