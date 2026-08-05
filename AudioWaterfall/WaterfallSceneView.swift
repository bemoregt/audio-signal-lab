//
//  WaterfallSceneView.swift
//  AudioWaterfall
//

import SwiftUI
import SceneKit
import simd

/// SceneKit's built-in `allowsCameraControl` binds a plain mouse scroll wheel to panning
/// (and zoom only to trackpad pinch), with no supported way to remap it — so orbit and
/// zoom are both driven manually here via raw mouse events instead.
private final class InteractiveSCNView: SCNView {
    var onScroll: ((CGFloat) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    private var lastDragLocation: NSPoint?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        defer { lastDragLocation = event.locationInWindow }
        guard let last = lastDragLocation else { return }
        let current = event.locationInWindow
        onDrag?(current.x - last.x, current.y - last.y)
    }
}

struct WaterfallSceneView: NSViewRepresentable {
    let history: SpectrumHistory
    var colormap: Colormap = .turboLike
    var backgroundColorOption: BackgroundColorOption = .black
    var cameraViewpoint: CameraViewpoint = .standard

    func makeCoordinator() -> Coordinator {
        Coordinator(history: history, colormap: colormap)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = InteractiveSCNView()
        view.scene = context.coordinator.scene
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = true
        view.backgroundColor = backgroundColorOption.color
        view.rendersContinuously = true
        view.delegate = context.coordinator
        view.pointOfView = context.coordinator.cameraNode
        view.onScroll = { [weak coordinator = context.coordinator] deltaY in
            coordinator?.zoom(by: deltaY)
        }
        view.onDrag = { [weak coordinator = context.coordinator] deltaX, deltaY in
            coordinator?.orbit(deltaX: Float(deltaX), deltaY: Float(deltaY))
        }
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.colormap = colormap
        nsView.backgroundColor = backgroundColorOption.color
        if context.coordinator.appliedViewpoint != cameraViewpoint {
            context.coordinator.applyViewpoint(cameraViewpoint)
        }
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var colormap: Colormap
        let scene = SCNScene()

        private let history: SpectrumHistory
        private let waterfallNode = SCNNode()
        private let waterfallFillNode = SCNNode()
        let cameraNode = SCNNode()
        private let indexElement: SCNGeometryElement
        private var lastRenderedVersion = -1

        private let timeSteps: Int
        private let binCount: Int
        private let width: Float = 20
        private let depth: Float = 20
        private let heightScale: Float = 6

        // Orbit/zoom camera state: position is derived each update from spherical
        // coordinates (yaw, pitch, distance) around a fixed look-at target, so drag (orbit)
        // and scroll (zoom) can independently update it without drifting.
        private var orbitTarget = SIMD3<Float>(0, 0, 0)
        private var orbitYaw: Float = 0
        private var orbitPitch: Float = 0
        private var orbitDistance: Float = 1
        private let minCameraDistance: Float = 4
        private let maxCameraDistance: Float = 60
        private let orbitSensitivity: Float = 0.01
        private let zoomSensitivity: Float = 0.05

        // Tracks the last preset applied via the View picker, so WaterfallSceneView's
        // updateNSView (called on every unrelated SwiftUI update too) only re-snaps the
        // camera when the user actually picked a different preset — not on every redraw,
        // which would otherwise fight manual drag/scroll adjustments.
        private(set) var appliedViewpoint: CameraViewpoint = .standard

        // Metal (SceneKit's renderer) always draws .line primitives at 1px regardless of any
        // material setting, so real thickness requires building quad "ribbons" in place of
        // each line segment, thickened along a fixed local axis (Z) rather than a
        // camera-facing billboard — billboarding made the offset direction swing toward
        // vertical near sharp peaks, producing stray vertical-looking spikes.
        private let lineHalfThickness: Float = 0.02
        private let rowOffsetAxis = SIMD3<Float>(0, 0, 1)

        // The line sits exactly on the fill's top edge, so it's lifted a hair toward the
        // camera in Y to avoid z-fighting with the opaque fill quad directly beneath it.
        private let lineTopLift: Float = 0.015
        private let fillShadeFactor: Float = 0.35

        private let rowSegmentCount: Int
        private var totalSegmentCount: Int { rowSegmentCount }

        init(history: SpectrumHistory, colormap: Colormap) {
            self.history = history
            self.colormap = colormap
            self.timeSteps = history.timeSteps
            self.binCount = history.binCount
            self.rowSegmentCount = timeSteps * (binCount - 1)
            self.indexElement = Coordinator.buildIndexElement(segmentCount: rowSegmentCount)
            super.init()
            setupScene()
        }

        private func setupScene() {
            scene.rootNode.addChildNode(waterfallFillNode)
            scene.rootNode.addChildNode(waterfallNode)

            let camera = SCNCamera()
            camera.zFar = 100
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            orbitTarget = SIMD3<Float>(0, 0, -depth / 2)
            applyViewpoint(.standard)
        }

        /// Snaps the orbit camera to a named preset (see CameraViewpoint) — used by the
        /// View picker. Degrees-to-radians conversion happens here since the preset is
        /// authored in degrees for readability.
        func applyViewpoint(_ viewpoint: CameraViewpoint) {
            appliedViewpoint = viewpoint
            orbitYaw = viewpoint.yawDegrees * .pi / 180
            orbitPitch = viewpoint.pitchDegrees * .pi / 180
            orbitDistance = min(maxCameraDistance, max(minCameraDistance, viewpoint.distance))
            updateCameraTransform()
        }

        private func updateCameraTransform() {
            let horizontal = orbitDistance * cos(orbitPitch)
            let position = orbitTarget + SIMD3<Float>(
                horizontal * sin(orbitYaw),
                orbitDistance * sin(orbitPitch),
                horizontal * cos(orbitYaw)
            )
            cameraNode.simdPosition = position
            cameraNode.look(at: SCNVector3(orbitTarget.x, orbitTarget.y, orbitTarget.z))
        }

        /// Left-drag orbit around the fixed look-at target.
        func orbit(deltaX: Float, deltaY: Float) {
            let maxPitch = Float.pi / 2 - 0.05
            orbitYaw -= deltaX * orbitSensitivity
            orbitPitch = min(maxPitch, max(-maxPitch, orbitPitch + deltaY * orbitSensitivity))
            updateCameraTransform()
        }

        /// Scroll-wheel zoom: dolly toward/away from the look-at target, clamped so it can't
        /// pass through the waterfall or drift too far away.
        func zoom(by scrollDeltaY: CGFloat) {
            orbitDistance = min(maxCameraDistance, max(minCameraDistance, orbitDistance - Float(scrollDeltaY) * zoomSensitivity))
            updateCameraTransform()
        }

        /// Topology for a flat list of independent quads (4 vertices, 2 triangles each) —
        /// one quad per line segment along the frequency axis. amesh-authentic: only row
        /// (frequency) lines, no depth-direction cross lines, stacked receding into the screen.
        private static func buildIndexElement(segmentCount: Int) -> SCNGeometryElement {
            var indices: [UInt32] = []
            indices.reserveCapacity(segmentCount * 6)
            for i in 0..<segmentCount {
                let base = UInt32(i * 4)
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            }
            let data = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
            return SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: segmentCount * 2,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard history.version != lastRenderedVersion else { return }
            lastRenderedVersion = history.version
            rebuildGeometry(rows: history.snapshot())
        }

        private func rebuildGeometry(rows: [[Float]]) {
            var gridPositions = [SIMD3<Float>](repeating: .zero, count: timeSteps * binCount)
            var gridColors = [(Float, Float, Float, Float)](repeating: (0, 0, 0, 1), count: timeSteps * binCount)

            // Color encodes frequency-axis position (same hue at a given bin on every row),
            // not recency and not amplitude. Low frequency = red (colormap value 1), high
            // frequency = blue (colormap value 0).
            let binColors = (0..<binCount).map { colormap.rgba(for: 1 - Float($0) / Float(binCount - 1)) }

            for t in 0..<timeSteps {
                let row = rows[t]
                let z = -Float(t) / Float(timeSteps - 1) * depth
                for b in 0..<binCount {
                    let amplitude = row[b]
                    let x = (Float(b) / Float(binCount - 1) - 0.5) * width
                    let y = amplitude * heightScale
                    gridPositions[t * binCount + b] = SIMD3<Float>(x, y, z)
                    gridColors[t * binCount + b] = binColors[b]
                }
            }

            var linePositions = [Float](repeating: 0, count: totalSegmentCount * 4 * 3)
            var lineColors = [Float](repeating: 0, count: totalSegmentCount * 4 * 4)
            var fillPositions = [Float](repeating: 0, count: totalSegmentCount * 4 * 3)
            var fillColors = [Float](repeating: 0, count: totalSegmentCount * 4 * 4)
            var segmentIndex = 0

            func write(_ buffer: inout [Float], _ index: Int, _ vertices: [SIMD3<Float>], _ vertexColors: [(Float, Float, Float, Float)], colorBuffer: inout [Float]) {
                let pBase = index * 4 * 3
                for (i, v) in vertices.enumerated() {
                    buffer[pBase + i * 3] = v.x
                    buffer[pBase + i * 3 + 1] = v.y
                    buffer[pBase + i * 3 + 2] = v.z
                }
                let cBase = index * 4 * 4
                for (i, c) in vertexColors.enumerated() {
                    colorBuffer[cBase + i * 4] = c.0
                    colorBuffer[cBase + i * 4 + 1] = c.1
                    colorBuffer[cBase + i * 4 + 2] = c.2
                    colorBuffer[cBase + i * 4 + 3] = c.3
                }
            }

            for t in 0..<timeSteps {
                for b in 0..<(binCount - 1) {
                    let aIndex = t * binCount + b
                    let bIndex = t * binCount + b + 1
                    let a = gridPositions[aIndex]
                    let b2 = gridPositions[bIndex]
                    let ca = gridColors[aIndex]
                    let cb = gridColors[bIndex]

                    // Bright top line: a thin ribbon (thickened along Z) lifted slightly in Y
                    // so it doesn't z-fight with the fill's top edge directly beneath it.
                    let lift = SIMD3<Float>(0, lineTopLift, 0)
                    let offset = rowOffsetAxis * lineHalfThickness
                    write(&linePositions, segmentIndex, [
                        a + offset + lift, a - offset + lift, b2 - offset + lift, b2 + offset + lift
                    ], [ca, ca, cb, cb], colorBuffer: &lineColors)

                    // Opaque fill beneath the line, from the row's baseline up to the curve —
                    // this is what actually blocks whatever lies behind it, so a tall nearby
                    // peak hides the rows behind it instead of leaving them visible in the gaps.
                    let aBase = SIMD3<Float>(a.x, 0, a.z)
                    let bBase = SIMD3<Float>(b2.x, 0, b2.z)
                    let shadedA = (ca.0 * fillShadeFactor, ca.1 * fillShadeFactor, ca.2 * fillShadeFactor, ca.3)
                    let shadedB = (cb.0 * fillShadeFactor, cb.1 * fillShadeFactor, cb.2 * fillShadeFactor, cb.3)
                    write(&fillPositions, segmentIndex, [aBase, a, b2, bBase], [shadedA, shadedA, shadedB, shadedB], colorBuffer: &fillColors)

                    segmentIndex += 1
                }
            }

            func makeGeometrySource(_ values: [Float], semantic: SCNGeometrySource.Semantic, componentsPerVector: Int) -> SCNGeometrySource {
                let data = Data(bytes: values, count: values.count * MemoryLayout<Float>.size)
                return SCNGeometrySource(
                    data: data,
                    semantic: semantic,
                    vectorCount: totalSegmentCount * 4,
                    usesFloatComponents: true,
                    componentsPerVector: componentsPerVector,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<Float>.size * componentsPerVector
                )
            }

            let lineGeometry = SCNGeometry(
                sources: [
                    makeGeometrySource(linePositions, semantic: .vertex, componentsPerVector: 3),
                    makeGeometrySource(lineColors, semantic: .color, componentsPerVector: 4)
                ],
                elements: [indexElement]
            )
            let lineMaterial = SCNMaterial()
            lineMaterial.lightingModel = .constant
            lineMaterial.isDoubleSided = true
            lineMaterial.diffuse.contents = NSColor.white
            lineGeometry.materials = [lineMaterial]
            waterfallNode.geometry = lineGeometry

            let fillGeometry = SCNGeometry(
                sources: [
                    makeGeometrySource(fillPositions, semantic: .vertex, componentsPerVector: 3),
                    makeGeometrySource(fillColors, semantic: .color, componentsPerVector: 4)
                ],
                elements: [indexElement]
            )
            let fillMaterial = SCNMaterial()
            fillMaterial.lightingModel = .constant
            fillMaterial.isDoubleSided = true
            fillMaterial.diffuse.contents = NSColor.white
            fillGeometry.materials = [fillMaterial]
            waterfallFillNode.geometry = fillGeometry
        }
    }
}
