//
//  WaterfallSceneView.swift
//  AudioWaterfall
//

import SwiftUI
import SceneKit
import simd

struct WaterfallSceneView: NSViewRepresentable {
    let history: SpectrumHistory
    var colormap: Colormap = .turboLike
    var backgroundColorOption: BackgroundColorOption = .black

    func makeCoordinator() -> Coordinator {
        Coordinator(history: history, colormap: colormap)
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = backgroundColorOption.color
        view.rendersContinuously = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.colormap = colormap
        nsView.backgroundColor = backgroundColorOption.color
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var colormap: Colormap
        let scene = SCNScene()

        private let history: SpectrumHistory
        private let waterfallNode = SCNNode()
        private let cameraNode = SCNNode()
        private let indexElement: SCNGeometryElement
        private var lastRenderedVersion = -1

        private let timeSteps: Int
        private let binCount: Int
        private let width: Float = 20
        private let depth: Float = 20
        private let heightScale: Float = 6

        // Metal (SceneKit's renderer) always draws .line primitives at 1px regardless of any
        // material setting, so real thickness requires building quad "ribbons" in place of
        // each line segment, thickened along a fixed local axis (Z) rather than a
        // camera-facing billboard — billboarding made the offset direction swing toward
        // vertical near sharp peaks, producing stray vertical-looking spikes.
        private let lineHalfThickness: Float = 0.02
        private let rowOffsetAxis = SIMD3<Float>(0, 0, 1)

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
            scene.rootNode.addChildNode(waterfallNode)

            let camera = SCNCamera()
            camera.zFar = 100
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 8, 12)
            cameraNode.look(at: SCNVector3(0, 0, -depth / 2))
            scene.rootNode.addChildNode(cameraNode)
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

            var positions = [Float](repeating: 0, count: totalSegmentCount * 4 * 3)
            var colors = [Float](repeating: 0, count: totalSegmentCount * 4 * 4)
            var segmentIndex = 0

            func emitSegment(_ aIndex: Int, _ bIndex: Int, offsetAxis: SIMD3<Float>) {
                let a = gridPositions[aIndex]
                let b = gridPositions[bIndex]
                let ca = gridColors[aIndex]
                let cb = gridColors[bIndex]

                let offset = offsetAxis * lineHalfThickness

                let v0 = a + offset
                let v1 = a - offset
                let v2 = b - offset
                let v3 = b + offset

                let pBase = segmentIndex * 4 * 3
                for (i, v) in [v0, v1, v2, v3].enumerated() {
                    positions[pBase + i * 3] = v.x
                    positions[pBase + i * 3 + 1] = v.y
                    positions[pBase + i * 3 + 2] = v.z
                }

                let cBase = segmentIndex * 4 * 4
                for (i, c) in [ca, ca, cb, cb].enumerated() {
                    colors[cBase + i * 4] = c.0
                    colors[cBase + i * 4 + 1] = c.1
                    colors[cBase + i * 4 + 2] = c.2
                    colors[cBase + i * 4 + 3] = c.3
                }

                segmentIndex += 1
            }

            for t in 0..<timeSteps {
                for b in 0..<(binCount - 1) {
                    emitSegment(t * binCount + b, t * binCount + b + 1, offsetAxis: rowOffsetAxis)
                }
            }

            let positionData = Data(bytes: positions, count: positions.count * MemoryLayout<Float>.size)
            let positionSource = SCNGeometrySource(
                data: positionData,
                semantic: .vertex,
                vectorCount: totalSegmentCount * 4,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 3
            )

            let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<Float>.size)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: totalSegmentCount * 4,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )

            let geometry = SCNGeometry(sources: [positionSource, colorSource], elements: [indexElement])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.diffuse.contents = NSColor.white
            geometry.materials = [material]

            waterfallNode.geometry = geometry
        }
    }
}
