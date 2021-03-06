//
//  GLTF+Extension.swift
//  
//
//  Created by Volodymyr Boichentsov on 13/10/2017.
//  Copyright © 2017 Volodymyr Boichentsov. All rights reserved.
//

import Foundation
import SceneKit

// TODO: clear cache
// TODO: exec completion block

let dracoExtensionKey = "KHR_draco_mesh_compression"
let compressedTextureExtensionKey = "3D4M_compressed_texture"
let supportedExtensions = [dracoExtensionKey, compressedTextureExtensionKey]

extension GLTF {

    struct Keys {
        static var cache_nodes = "cache_nodes"
        static var animation_duration = "animation_duration"
        static var resource_loader = "resource_loader"
        static var load_canceled = "load_canceled"
        static var completion_handler = "completion_handler"
        static var scnview = "scnview"
    }
    
    @objc
    open var isCanceled:Bool {
        get { return (objc_getAssociatedObject(self, &Keys.load_canceled) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Keys.load_canceled, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }
    
    var cache_nodes:[SCNNode?]? {
        get { return objc_getAssociatedObject(self, &Keys.cache_nodes) as? [SCNNode?] }
        set { objc_setAssociatedObject(self, &Keys.cache_nodes, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    
    var renderer:SCNSceneRenderer? {
        get { return objc_getAssociatedObject(self, &Keys.scnview) as? SCNSceneRenderer }
        set { objc_setAssociatedObject(self, &Keys.scnview, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }
    
    var _completionHandler:(() -> Void) {
        get { return (objc_getAssociatedObject(self, &Keys.completion_handler) as? (() -> Void) ?? {}) }
        set { objc_setAssociatedObject(self, &Keys.completion_handler, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    /// Convert glTF object to SceneKit scene. 
    ///
    /// - Parameter scene: Optional parameter. If property is set then loaded model will be add to existing objects in scene.
    /// - Parameter view: Required for Metal. But optional for OpenGL rendering.
    /// - Parameter directoryPath: location to others related resources of glTF.
    /// - Parameter multiThread: By default model will be load in multiple threads.
    /// - Parameter completionHandler: Execute completion block once model fully loaded. If multiThread parameter set to true, then scene will be returned soon as possible and completion block will be executed later, after all textures load. 
    /// - Returns: instance of Scene
    @objc open func convert(to scene:SCNScene = SCNScene.init(),
                             renderer:SCNSceneRenderer? = nil, 
                             directoryPath:String? = nil, 
                             multiThread:Bool = true, 
                             completionHandler: @escaping (() -> Void) = {} ) -> SCNScene? {

        if (self.extensionsUsed != nil) {
            for key in self.extensionsUsed! {
                if !supportedExtensions.contains(key) {
                    print("Used `\(key)` extension is not supported!")
                }
            }
        }
        
        if (self.extensionsRequired != nil) {
            for key in self.extensionsRequired! {
                if !supportedExtensions.contains(key) {
                    print("Required `\(key)` extension is not supported!")
                    return nil
                }
            }
        }
        
        self.renderer = renderer
        self._completionHandler = completionHandler
        
        if directoryPath != nil {
            self.loader.directoryPath = directoryPath!
        }
        
        
        if self.scenes != nil && self.scene != nil {
            let sceneGlTF = self.scenes![(self.scene)!]
            if let sceneName = sceneGlTF.name {
                scene.setAttribute(sceneName, forKey: "name")
            }
            
            self.cache_nodes = [SCNNode?](repeating: nil, count: (self.nodes?.count)!)
            
            // run in multi-thread or single
            if (multiThread) {
                
                let start = Date() 
                
                // get global worker 
                let group = DispatchGroup()
                
                // parse nodes
                for nodeIndex in sceneGlTF.nodes! {
                    
                    group.enter()
                    self._preloadBuffersData(nodeIndex: nodeIndex) { error in
                        let node = self.buildNode(nodeIndex:nodeIndex)
                        scene.rootNode.addChildNode(node)
                        group.leave()
                        if error != nil {
                            print(error!)
                        }
                    }
                }
                
                #if DEBUG                
                print("preload time \(-1000 * start.timeIntervalSinceNow)")
                #endif     
                
                // completion
                group.notify(queue: DispatchQueue.global()) {
                    self._loadAnimationsAndCompleteConvertion()
                    
                    #if DEBUG
                    print("load glTF \(-1000 * start.timeIntervalSinceNow)")
                    #endif
                }
            } else {
                for nodeIndex in sceneGlTF.nodes! {
                    let node = self.buildNode(nodeIndex:nodeIndex)
                    scene.rootNode.addChildNode(node)
                }
                self._loadAnimationsAndCompleteConvertion()
            }
        }
        
        if self.isCanceled {
            return nil
        }
        
        return scene
    }
    
    @objc
    open func cancel() {
        self.isCanceled = true
        self.loader.cancelAll()
    }
    
     
    /// Parse and create animation. 
    /// And in case no textures required to load, complete convertion from glTF to SceneKit.
    fileprivate func _loadAnimationsAndCompleteConvertion() {
        
        self.parseAnimations()
        
        if self.textures?.count == 0 {
            self._converted()
        }
    }
    
    /// Completion function and cache cleaning.
    func _converted() {
        #if DEBUG
        print("convert completed")
        #endif
        // clear cache
        _completionHandler()
        _completionHandler = {}
        
        self.cache_nodes?.removeAll()
        
        self.clearCache()
    }
    
    
    // TODO: Collect associated buffers for node into a Set on Decode time.  
    fileprivate func _preloadBuffersData(nodeIndex:Int, completionHandler: @escaping (Error?) -> Void ) {
        
        var buffers:Set = Set<GLTFBuffer>()
        
        if let node = self.nodes?[nodeIndex] {
            if node.mesh != nil {
                if let mesh = self.meshes?[node.mesh!] {
                    for primitive in mesh.primitives {
                        // check on draco extension
                        if let dracoMesh = primitive.extensions?[dracoExtensionKey] as? GLTFKHRDracoMeshCompressionExtension {
                            let buffer = self.buffers![self.bufferViews![dracoMesh.bufferView].buffer]
                            buffers.insert(buffer)
                        } else {
                            for (_,index) in primitive.attributes {
                                if let accessor = self.accessors?[index] {
                                    if let bufferView = accessor.bufferView {
                                        let buffer = self.buffers![self.bufferViews![bufferView].buffer]
                                        buffers.insert(buffer)
                                    }
                                }
                            }
                            if primitive.indices != nil {
                                if let accessor = self.accessors?[primitive.indices!] {
                                    if let bufferView = accessor.bufferView {
                                        let buffer = self.buffers![self.bufferViews![bufferView].buffer]
                                        buffers.insert(buffer)
                                    }
                                }
                            }
                        }
                    }
                }
            }                        
        }
        
        self.loader.load(gltf:self, resources: buffers, completionHandler:completionHandler)
    }
    
    // MARK: - Nodes
    
    fileprivate func buildNode(nodeIndex:Int) -> SCNNode {
        let scnNode = SCNNode()
        if let node = self.nodes?[nodeIndex] {
            scnNode.name = node.name
            
            // Get camera, if it has reference on any. 
            constructCamera(node, scnNode)
            
            // convert meshes if any exists in gltf node
            geometryNode(node, scnNode)
            
            // construct animation paths
            var weightPaths = [String]()
            for i in 0..<scnNode.childNodes.count {
                let primitive = scnNode.childNodes[i]
                if let morpher = primitive.morpher {
                    for j in 0..<morpher.targets.count {
                        let path = "childNodes[\(i)].morpher.weights[\(j)]"
                        weightPaths.append(path)
                    }
                }
            }
            scnNode.setValue(weightPaths, forUndefinedKey: "weightPaths")
            
            // load skin if any reference exists
            if let skin = node.skin {
                loadSkin(skin, scnNode)
            }
            
            // bake all transformations into one mtarix
            scnNode.transform = bakeTransformationMatrix(node)
            
            if self.isCanceled {
                return scnNode
            }
            self.cache_nodes?[nodeIndex] = scnNode
            
            if let children = node.children {
                for i in children {
                    let subSCNNode = buildNode(nodeIndex:i)
                    scnNode.addChildNode(subSCNNode)
                }
            }
        }
        return scnNode
    }
    
    fileprivate func bakeTransformationMatrix(_ node:GLTFNode) -> SCNMatrix4 {
        let rotation = GLKMatrix4MakeWithQuaternion(GLKQuaternion.init(q: (Float(node.rotation[0]), Float(node.rotation[1]), Float(node.rotation[2]), Float(node.rotation[3]))))
        var matrix = SCNMatrix4.init(array:node.matrix)
        matrix = SCNMatrix4Translate(matrix, SCNFloat(node.translation[0]), SCNFloat(node.translation[1]), SCNFloat(node.translation[2]))
        matrix = SCNMatrix4Mult(matrix, SCNMatrix4FromGLKMatrix4(rotation)) 
        matrix = SCNMatrix4Scale(matrix, SCNFloat(node.scale[0]), SCNFloat(node.scale[1]), SCNFloat(node.scale[2]))
        return matrix
    }
    
    fileprivate func constructCamera(_ node:GLTFNode, _ scnNode:SCNNode) {
        if let cameraIndex = node.camera {
            scnNode.camera = SCNCamera()
            if self.cameras != nil {
                let camera = self.cameras![cameraIndex]
                scnNode.camera?.name = camera.name
                switch camera.type {
                case .perspective:
                    scnNode.camera?.zNear = (camera.perspective?.znear)!
                    scnNode.camera?.zFar = (camera.perspective?.zfar)!
                    if #available(OSX 10.13, iOS 11.0, *) {
                        scnNode.camera?.fieldOfView = CGFloat((camera.perspective?.yfov)! * 180.0 / .pi)
                        scnNode.camera?.wantsDepthOfField = true
                        scnNode.camera?.motionBlurIntensity = 0.3
                    }
                    break
                case .orthographic:
                    scnNode.camera?.usesOrthographicProjection = true
                    scnNode.camera?.zNear = (camera.orthographic?.znear)!
                    scnNode.camera?.zFar = (camera.orthographic?.zfar)!
                    break
                }
            }
        }
    }  

    
    /// convert glTF mesh into SCNGeometry
    ///
    /// - Parameters:
    ///   - node: gltf node
    ///   - scnNode: SceneKit node, which is going to be parent node 
    fileprivate func geometryNode(_ node:GLTFNode, _ scnNode:SCNNode) {
        
        if self.isCanceled {
            return
        }
        
        if let meshIndex = node.mesh {
            if let mesh = self.meshes?[meshIndex] {
                
                for primitive in mesh.primitives {
                    
                    var sources:[SCNGeometrySource] = [SCNGeometrySource]()
                    var elements:[SCNGeometryElement] = [SCNGeometryElement]()
                    
                    // get indices 
                    if let element = self.geometryElement(primitive) {
                        elements.append(element)   
                    }
                    
                    // get sources from attributes information
                    sources.append(contentsOf: self.geometrySources(primitive.attributes))
                    
                    // check on draco extension
                    if let dracoMesh = primitive.extensions?[dracoExtensionKey] as? GLTFKHRDracoMeshCompressionExtension {
                        let (dElement, dSources) = self.convertDracoMesh(dracoMesh)
                        
                        if (dElement != nil) {
                            elements.append(dElement!)
                        }
                        
                        if (dSources != nil) {
                            sources.append(contentsOf: dSources!)
                        }
                    }
                    
                    if self.isCanceled {
                        return
                    }
                    
                    // create geometry
                    let geometry = SCNGeometry.init(sources: sources, elements: elements)
                    
                    if let materialIndex = primitive.material {
                        self.loadMaterial(index:materialIndex) { scnMaterial in 
                            geometry.materials = [scnMaterial]
                        }
                    }
                    
                    let primitiveNode = SCNNode.init(geometry: geometry)
                    primitiveNode.name = mesh.name
                    
                    if let targets = primitive.targets {
                        let morpher = SCNMorpher()
                        for targetIndex in 0..<targets.count {
                            let target = targets[targetIndex]
                            let sourcesMorph = geometrySources(target)
                            let geometryMorph = SCNGeometry(sources: sourcesMorph, elements: nil)
                            morpher.targets.append(geometryMorph)
                        }
                        morpher.calculationMode = .additive
                        primitiveNode.morpher = morpher
                    }
                    
                    scnNode.addChildNode(primitiveNode)
                }
            }
        }
    }
    
    fileprivate func geometryElement(_ primitive: GLTFMeshPrimitive) -> SCNGeometryElement? {
        if let indicesIndex = primitive.indices {
            if let accessor = self.accessors?[indicesIndex] {
                
                if let (indicesData, _, _) = loadAcessor(accessor) {
                    
                    var count = accessor.count
                    
                    let primitiveType = primitive.mode.scn()
                    switch primitiveType {
                    case .triangles:
                        count = count/3
                        break
                    case .triangleStrip:
                        count = count-2
                        break
                    case .line:
                        count = count/2
                    default:
                        break
                    }
                    
                    return SCNGeometryElement.init(data: indicesData,
                                                   primitiveType: primitiveType,
                                                   primitiveCount: count,
                                                   bytesPerIndex: accessor.bytesPerElement())
                } else {
                    // here is should be errors handling
                    print("Error load geometryElement")
                }
            }
        }
        return nil
    }

    /// Convert mesh/animation attributes into SCNGeometrySource
    ///
    /// - Parameter attributes: dictionary of accessors
    /// - Returns: array of SCNGeometrySource objects
    fileprivate func geometrySources(_ attributes:[String:Int]) -> [SCNGeometrySource]  {
        var geometrySources = [SCNGeometrySource]()
        for (key, accessorIndex) in attributes {
            if let accessor = self.accessors?[accessorIndex] {
                
                if let (data, byteStride, byteOffset) = loadAcessor(accessor) {
                    
                    let count = accessor.count
                    
                    // convert string semantic to SceneKit semantic type 
                    let semantic = self.sourceSemantic(name:key)
                    
                    let geometrySource = SCNGeometrySource.init(data: data, 
                                                                semantic: semantic, 
                                                                vectorCount: count, 
                                                                usesFloatComponents: true, 
                                                                componentsPerVector: accessor.components(), 
                                                                bytesPerComponent: accessor.bytesPerElement(), 
                                                                dataOffset: byteOffset, 
                                                                dataStride: byteStride)
                    geometrySources.append(geometrySource)
                }
            }
        }
        return geometrySources
    }
    
    
    func requestData(bufferView:Int) throws -> (GLTFBufferView, Data) {
        if let bufferView = self.bufferViews?[bufferView] {  
            let buffer = self.buffers![bufferView.buffer]
            
            if let data = try self.loader.load(gltf:self, resource: buffer) {
                return (bufferView, data)
            }
            throw "Can't load data!"
        }
        throw "Can't load data! Can't find bufferView or buffer" 
    }
    
    
    // get data by accessor
    func loadAcessor(_ accessor:GLTFAccessor) -> (Data, Int, Int)? {
        
        if accessor.bufferView == nil {
            return nil
        }
        
        if let (bufferView, data) = try? requestData(bufferView: accessor.bufferView!) { 
            
            var addAccessorOffset = false
            if (bufferView.byteStride == nil || accessor.components()*accessor.bytesPerElement() == bufferView.byteStride) {
                addAccessorOffset = true
            }
            
            let count = accessor.count
            let byteStride = (bufferView.byteStride == nil) ? accessor.components()*accessor.bytesPerElement() : bufferView.byteStride!
            let bytesLength = byteStride*count
            
            let start = bufferView.byteOffset+((addAccessorOffset) ? accessor.byteOffset : 0)
            let end = start+bytesLength
            
            var subdata = data
            if start != 0 || end != data.count {
                subdata = data.subdata(in: start..<end)
            }
            
            let byteOffset = ((!addAccessorOffset) ? accessor.byteOffset : 0)
            return (subdata, byteStride, byteOffset)
        }
        
        return nil
    }
    
    
    // convert attributes name to SceneKit semantic
    func sourceSemantic(name:String) -> SCNGeometrySource.Semantic {
        switch name {
        case "POSITION":
            return .vertex
        case "NORMAL":
            return .normal
        case "TANGENT":
            return .tangent
        case "COLOR", "COLOR_0", "COLOR_1", "COLOR_2":
            return .color
        case "TEXCOORD_0", "TEXCOORD_1", "TEXCOORD_2", "TEXCOORD_3", "TEXCOORD_4":
            return .texcoord
        case "JOINTS_0":
            return .boneIndices
        case "WEIGHTS_0":
            return .boneWeights
        default:
            return .vertex
        }
    }
    
    
    @objc
    open func clearCache() {
        if self.buffers != nil {
            for buffer in self.buffers! {
                buffer.data = nil
            }
        }
        
        if self.images != nil {
            for image in self.images! {
                image.image = nil
            }
        }
    }
}


extension GLTFAccessor {
    fileprivate func components() -> Int {
        switch type {
        case .SCALAR:
            return 1
        case .VEC2:
            return 2
        case .VEC3:
            return 3
        case .VEC4, .MAT2:
            return 4
        case .MAT3:
            return 9
        case .MAT4:
            return 16
        }
    }
    
    fileprivate func bytesPerElement() -> Int {
        switch componentType {
        case .UNSIGNED_BYTE, .BYTE:
            return 1
        case .UNSIGNED_SHORT, .SHORT:
            return 2
        default:
            return 4
        }
    }
}

extension GLTFMeshPrimitiveMode {
    fileprivate func scn() -> SCNGeometryPrimitiveType {
        switch self {
        case .POINTS:
            return .point
        case .LINES, .LINE_LOOP, .LINE_STRIP:
            return .line
        case .TRIANGLE_STRIP:
            return .triangleStrip
        case .TRIANGLES:
            return .triangles
        default:
            return .triangles
        }
    }
}



