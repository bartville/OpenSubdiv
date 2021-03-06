
#import "mtlPtexViewer.h"

#import <simd/simd.h>
#import <algorithm>
#import <cfloat>
#import <fstream>
#import <iostream>
#import <iterator>
#import <string>
#import <sstream>
#import <vector>
#import <memory>

#import <far/error.h>
#import <osd/mesh.h>
#import <osd/cpuVertexBuffer.h>
#import <osd/cpuEvaluator.h>
#import <osd/cpuPatchTable.h>
#import <osd/mtlLegacyGregoryPatchTable.h>
#import <osd/mtlVertexBuffer.h>
#import <osd/mtlMesh.h>
#import <osd/mtlPatchTable.h>
#import <osd/mtlComputeEvaluator.h>
#import <osd/mtlPatchShaderSource.h>

#import "../common/simple_math.h"
#import "../../regression/common/far_utils.h"
#import "init_shapes.h"
#import "../common/mtlUtils.h"
#import "../common/mtlControlMeshDisplay.h"
#import "../common/MTLPtexMipmapTexture.h"

#define VERTEX_BUFFER_INDEX 0
#define PATCH_INDICES_BUFFER_INDEX 1
#define CONTROL_INDICES_BUFFER_INDEX 2
#define OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX 3
#define OSD_PATCHPARAM_BUFFER_INDEX 4
#define OSD_VALENCE_BUFFER_INDEX 6
#define OSD_QUADOFFSET_BUFFER_INDEX 7
#define OSD_PERPATCHTESSFACTORS_BUFFER_INDEX 8
#define QUAD_TESSFACTORS_INDEX 10
#define OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX
#define OSD_PATCH_INDEX_BUFFER_INDEX 13
#define OSD_DRAWINDIRECT_BUFFER_INDEX 14
#define OSD_KERNELLIMIT_BUFFER_INDEX 15

#define DISPLACEMENT_TEXTURE_INDEX 0
#define IMAGE_TEXTURE_INDEX 1
#define OCCLUSION_TEXTURE_INDEX 2
#define SPECULAR_TEXTURE_INDEX 3

#define DISPLACEMENT_BUFFER_INDEX 15
#define IMAGE_BUFFER_INDEX 16
#define OCCLUSION_BUFFER_INDEX 17
#define SPECULAR_BUFFER_INDEX 18
#define CONFIG_BUFFER_INDEX 19

#define FRAME_CONST_BUFFER_INDEX 11
#define INDICES_BUFFER_INDEX 2

using namespace OpenSubdiv::OPENSUBDIV_VERSION;

template <> Far::StencilTable const * Osd::convertToCompatibleStencilTable<OpenSubdiv::Far::StencilTable, OpenSubdiv::Far::StencilTable, OpenSubdiv::Osd::MTLContext>(
                                                                                                                                                                           OpenSubdiv::Far::StencilTable const *table, OpenSubdiv::Osd::MTLContext*  /*context*/) {
    // no need for conversion
    // XXX: We don't want to even copy.
    if (not table) return NULL;
    return new Far::StencilTable(*table);
}


struct alignas(256) DisplacementConfig {
    float displacementScale;
    float mipmapBias;
};

using CPUMeshType = Osd::Mesh<
    Osd::CPUMTLVertexBuffer,
    Far::StencilTable,
    Osd::CpuEvaluator,
    Osd::MTLPatchTable,
    Osd::MTLContext>;

using MTLMeshType = Osd::Mesh<
    Osd::CPUMTLVertexBuffer,
    Osd::MTLStencilTable,
    Osd::MTLComputeEvaluator,
    Osd::MTLPatchTable,
    Osd::MTLContext>;

using MTLMeshInterface = Osd::MTLMeshInterface;

struct alignas(256) PerFrameConstants
{
    float ModelViewMatrix[16];
    float ProjectionMatrix[16];
    float ModelViewProjectionMatrix[16];
    float ModelViewInverseMatrix[16];
    float TessLevel;
    DisplacementConfig displacementConfig;
};

struct alignas(16) Light {
    simd::float4 position;
    simd::float4 ambient;
    simd::float4 diffuse;
    simd::float4 specular;
};


using Osd::MTLRingBuffer;

const char* shaderSource =
#include "mtlPtexViewer.gen.h"
;

#define FRAME_LAG 3
template<typename DataType>
using PerFrameBuffer = MTLRingBuffer<DataType, FRAME_LAG>;

@implementation OSDRenderer {

    MTLRingBuffer<Light, 1> _lightsBuffer;
    
    PerFrameBuffer<PerFrameConstants> _frameConstantsBuffer;
    PerFrameBuffer<MTLQuadTessellationFactorsHalf> _tessFactorsBuffer;
    PerFrameBuffer<unsigned> _patchIndexBuffers[4];
    PerFrameBuffer<uint8_t> _perPatchDataBuffer;
    PerFrameBuffer<uint8_t> _hsDataBuffer;
    PerFrameBuffer<MTLDrawPatchIndirectArguments> _drawIndirectCommandsBuffer;
    
    unsigned _tessFactorOffsets[4];
    unsigned _perPatchDataOffsets[4];
    
    id<MTLComputePipelineState> _computePipelines[10];
    id<MTLRenderPipelineState> _renderPipelines[10];
    id<MTLDepthStencilState> _readWriteDepthStencilState;
    id<MTLDepthStencilState> _readOnlyDepthStencilState;
    
    Camera _cameraData;
    Osd::MTLContext _context;
    
    std::unique_ptr<MTLMeshInterface> _mesh;
    std::unique_ptr<Shape> _shape;
    
    std::unique_ptr<MTLPtexMipmapTexture> _colorPtexture;
    std::unique_ptr<MTLPtexMipmapTexture> _displacementPtexture;
    std::unique_ptr<MTLPtexMipmapTexture> _occlusionPtexture;
    std::unique_ptr<MTLPtexMipmapTexture> _specularPtexture;
    
    bool _needsRebuild, _doAdaptive;
    NSString* _osdShaderSource;
    simd::float3 _meshCenter;
    NSMutableArray<NSString*>* _loadedModels;
    int _numVertexElements, _numVertices;
    std::vector<float> _vertexData, _animatedVertices;
    int _numFrames, _animationFrames;
    float _meshSize;
}

-(Camera*)camera {
    return &_cameraData;
}

-(instancetype)initWithDelegate:(id<OSDRendererDelegate>)delegate {
    self = [super init];
    if(self) {
        self.useSingleCrease = true;
        self.useScreenspaceTessellation = true;
        self.usePatchClipCulling = false;
        self.usePatchIndexBuffer = false;
        self.usePatchBackfaceCulling = false;
        self.usePrimitiveBackfaceCulling = false;
        self.kernelType = kMetal;
        self.refinementLevel = 2;
        self.tessellationLevel = 8;
        self.normalMode = kNormalModeSurface;
        self.colorMode = kColorModeNormal;
        self.displacementMode = kDisplacementModeNone;
        self.useAdaptive = true;
        self.displayStyle = kDisplayStyleShaded;
        
        const auto colorFilename = getenv("COLOR_FILENAME");
        const auto displacementFilename = getenv("DISPLACEMENT_FILENAME");
        
        if(colorFilename)
            _ptexColorFilename = [NSString stringWithUTF8String:colorFilename];
        
        if(displacementFilename)
            _ptexDisplacementFilename = [NSString stringWithUTF8String:displacementFilename];
        
        _delegate = delegate;
        _context.device = [delegate deviceFor:self];
        _context.commandQueue = [delegate commandQueueFor:self];
        
        _osdShaderSource = @(shaderSource);

        _needsRebuild = true;
        _numFrames = 0;
        _animationFrames = 0;
        
        
        [self _initializeBuffers];
        [self _initializeCamera];
        [self _initializeLights];
        [self _initializeModels];
    }
    return self;
}

-(id<MTLRenderCommandEncoder>)drawFrame:(id<MTLCommandBuffer>)commandBuffer {
    if(_needsRebuild) {
        [self _rebuildState];
    }
    
    if(!_freeze) {
        if(_animateVertices) {
            _animatedVertices.resize(_vertexData.size());
            auto p = _vertexData.data();
            auto n = _animatedVertices.data();
            
            float r = sin(_animationFrames*0.01f) * _animateVertices;
            for (int i = 0; i < _numVertices; ++i) {
                float move = 0.05f*cosf(p[0]*20+_animationFrames*0.01f);
                float ct = cos(p[2] * r);
                float st = sin(p[2] * r);
                n[0] = p[0]*ct + p[1]*st;
                n[1] = -p[0]*st + p[1]*ct;
                n[2] = p[2];
                
                p += _numVertexElements;
                n += _numVertexElements;
            }
            
            _mesh->UpdateVertexBuffer(_animatedVertices.data(), 0, _numVertices);
            _animationFrames++;
        }
        _mesh->Refine();
        _mesh->Synchronize();
    }
    
    [self _updateState];
    
    if(_doAdaptive) {
        auto computeEncoder = [commandBuffer computeCommandEncoder];
        [self _computeTessFactors:computeEncoder];
        [computeEncoder endEncoding];
    }
    
    auto renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:[_delegate renderPassDescriptorFor: self]];
    
    if(_usePrimitiveBackfaceCulling) {
        [renderEncoder setCullMode:MTLCullModeBack];
    } else {
        [renderEncoder setCullMode:MTLCullModeNone];
    }
    
    [self _renderMesh:renderEncoder];
    
    _frameConstantsBuffer.next();
    _tessFactorsBuffer.next();
    _patchIndexBuffers[0].next();
    _patchIndexBuffers[1].next();
    _patchIndexBuffers[2].next();
    _patchIndexBuffers[3].next();
    _lightsBuffer.next();
    _perPatchDataBuffer.next();
    _hsDataBuffer.next();
    _drawIndirectCommandsBuffer.next();
    
    _numFrames++;
    
    return renderEncoder;
}

-(void)_renderMesh:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    auto buffer = _mesh->BindVertexBuffer();
    assert(buffer);
    
    auto pav = _mesh->GetPatchTable()->GetPatchArrays();
    auto pib = _mesh->GetPatchTable()->GetPatchIndexBuffer();
    
    [renderCommandEncoder setVertexBuffer:buffer offset:0 atIndex:VERTEX_BUFFER_INDEX];
    [renderCommandEncoder setVertexBuffer: pib offset:0 atIndex:INDICES_BUFFER_INDEX];
    [renderCommandEncoder setVertexBuffer:_frameConstantsBuffer offset:0 atIndex:FRAME_CONST_BUFFER_INDEX];
    [renderCommandEncoder setVertexBuffer:_frameConstantsBuffer offset:offsetof(PerFrameConstants, displacementConfig) atIndex:CONFIG_BUFFER_INDEX];
    
    
    if(_doAdaptive)
    {
        [renderCommandEncoder setVertexBuffer:_hsDataBuffer offset:0 atIndex:OSD_PERPATCHTESSFACTORS_BUFFER_INDEX];
        [renderCommandEncoder setVertexBuffer:_perPatchDataBuffer offset:0 atIndex:OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX];
        [renderCommandEncoder setVertexBuffer:_mesh->GetPatchTable()->GetPatchParamBuffer() offset:0 atIndex:OSD_PATCHPARAM_BUFFER_INDEX];
        [renderCommandEncoder setVertexBuffer:_perPatchDataBuffer offset:0 atIndex:OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX];
    }
    
    [renderCommandEncoder setFragmentBuffer:_frameConstantsBuffer offset:offsetof(PerFrameConstants, displacementConfig) atIndex:1];
    [renderCommandEncoder setFragmentBuffer:_lightsBuffer offset:0 atIndex:0];
    
    [renderCommandEncoder setFragmentTexture:_colorPtexture->GetTexelsTexture() atIndex:IMAGE_TEXTURE_INDEX];
    [renderCommandEncoder setFragmentBuffer:_colorPtexture->GetLayoutBuffer() offset:0 atIndex:IMAGE_BUFFER_INDEX];
    if(_displacementPtexture)
    {
        [renderCommandEncoder setFragmentTexture:_displacementPtexture->GetTexelsTexture() atIndex:DISPLACEMENT_TEXTURE_INDEX];
        [renderCommandEncoder setFragmentBuffer:_displacementPtexture->GetLayoutBuffer() offset:0 atIndex:DISPLACEMENT_BUFFER_INDEX];
        
        [renderCommandEncoder setVertexTexture:_displacementPtexture->GetTexelsTexture() atIndex:DISPLACEMENT_TEXTURE_INDEX];
        [renderCommandEncoder setVertexBuffer:_displacementPtexture->GetLayoutBuffer() offset:0 atIndex:DISPLACEMENT_BUFFER_INDEX];
    }
    
    
    for(int i = 0; i < pav.size(); i++)
    {
        auto& patch = pav[i];
        auto d = patch.GetDescriptor();
        auto patchType = d.GetType();
        auto offset = patchType - Far::PatchDescriptor::REGULAR;
        
        if(_doAdaptive)
        {
            [renderCommandEncoder setVertexBufferOffset:patch.primitiveIdBase * sizeof(int) * 3 atIndex:OSD_PATCHPARAM_BUFFER_INDEX];
        }
        [renderCommandEncoder setVertexBufferOffset:patch.indexBase * sizeof(unsigned) atIndex:INDICES_BUFFER_INDEX];
        
        
        simd::float4 shade{.0f,0.0f,0.0f,1.0f};
        [renderCommandEncoder setFragmentBytes:&shade length:sizeof(shade) atIndex:2];
        [renderCommandEncoder setDepthBias:0 slopeScale:1.0 clamp:0];
        [renderCommandEncoder setTriangleFillMode:MTLTriangleFillModeFill];
        
        [renderCommandEncoder setDepthStencilState:_readWriteDepthStencilState];
        [renderCommandEncoder setRenderPipelineState:_renderPipelines[patchType]];
        
        if(_displayStyle == kDisplayStyleWire)
            [renderCommandEncoder setTriangleFillMode:MTLTriangleFillModeLines];
        else
            [renderCommandEncoder setTriangleFillMode:MTLTriangleFillModeFill];
        
        switch(patchType)
        {
            case Far::PatchDescriptor::GREGORY_BASIS:
            case Far::PatchDescriptor::GREGORY_BOUNDARY:
            case Far::PatchDescriptor::GREGORY:
            case Far::PatchDescriptor::REGULAR:
                [renderCommandEncoder setTessellationFactorBuffer:_tessFactorsBuffer offset:_tessFactorOffsets[offset] instanceStride:0];
                [renderCommandEncoder setVertexBufferOffset:_perPatchDataOffsets[offset] atIndex:OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX];
            break;
        }
        
        
        switch(patchType)
        {
            case Far::PatchDescriptor::POINTS:
            case Far::PatchDescriptor::LOOP:
            case Far::PatchDescriptor::NON_PATCH:
            case Far::PatchDescriptor::LINES:
                assert(0 && "Bad Patch type");
            break;
            case Far::PatchDescriptor::GREGORY_BASIS:
                if(_usePatchIndexBuffer)
                {
                    [renderCommandEncoder drawIndexedPatches:d.GetNumControlVertices() patchStart:0 patchCount:patch.GetNumPatches()
                                             patchIndexBuffer:_patchIndexBuffers[offset] patchIndexBufferOffset:0
                                      controlPointIndexBuffer:pib controlPointIndexBufferOffset:patch.indexBase * sizeof(unsigned)
                                                instanceCount:1 baseInstance:0];
                }
                else
                {
                    [renderCommandEncoder drawIndexedPatches:d.GetNumControlVertices() patchStart:0 patchCount:patch.GetNumPatches()
                                             patchIndexBuffer:nil patchIndexBufferOffset:0
                                      controlPointIndexBuffer:pib controlPointIndexBufferOffset:patch.indexBase * sizeof(unsigned)
                                                instanceCount:1 baseInstance:0];
                }

                if(_displayStyle == kDisplayStyleWireOnShaded)
                {
                    simd::float4 shade = {1, 1,1,1};
                    [renderCommandEncoder setFragmentBytes:&shade length:sizeof(shade) atIndex:2];
                    [renderCommandEncoder setTriangleFillMode:MTLTriangleFillModeLines];
                    [renderCommandEncoder setDepthBias:-5 slopeScale:-1.0 clamp:-100.0];
                    
                    if(_usePatchIndexBuffer)
                    {
                        [renderCommandEncoder drawIndexedPatches:d.GetNumControlVertices() patchStart:0 patchCount:patch.GetNumPatches()
                                                patchIndexBuffer:_patchIndexBuffers[offset] patchIndexBufferOffset:0
                                         controlPointIndexBuffer:pib controlPointIndexBufferOffset:patch.indexBase * sizeof(unsigned)
                                                   instanceCount:1 baseInstance:0];
                    }
                    else
                    {
                        [renderCommandEncoder drawIndexedPatches:d.GetNumControlVertices() patchStart:0 patchCount:patch.GetNumPatches()
                                                patchIndexBuffer:nil patchIndexBufferOffset:0
                                         controlPointIndexBuffer:pib controlPointIndexBufferOffset:patch.indexBase * sizeof(unsigned)
                                                   instanceCount:1 baseInstance:0];
                    }
                    [renderCommandEncoder setTriangleFillMode:MTLTriangleFillModeFill];
                }
                break;
            case Far::PatchDescriptor::REGULAR:
            case Far::PatchDescriptor::GREGORY:
            case Far::PatchDescriptor::GREGORY_BOUNDARY:
            {
#if !TARGET_OS_EMBEDDED
                if(_usePatchIndexBuffer)
                {
                    [renderCommandEncoder drawPatches:d.GetNumControlVertices()
                        patchIndexBuffer:_patchIndexBuffers[offset] patchIndexBufferOffset:0
                          indirectBuffer:_drawIndirectCommandsBuffer indirectBufferOffset: sizeof(MTLDrawPatchIndirectArguments) * offset];
                }
                else
#endif
                {
                    [renderCommandEncoder drawPatches:d.GetNumControlVertices() patchStart:0 patchCount:patch.GetNumPatches()
                        patchIndexBuffer:nil patchIndexBufferOffset:0 instanceCount:1 baseInstance:0];
                }
                
                if(_displayStyle == kDisplayStyleWireOnShaded)
                {
                    simd::float4 shade = {1, 1,1,1};
                    [renderCommandEncoder setFragmentBytes:&shade length:sizeof(shade) atIndex:2];
                    [renderCommandEncoder setTriangleFillMode:MTLTriangleFillModeLines];
                    [renderCommandEncoder setDepthBias:-5 slopeScale:-1.0 clamp:-100.0];
                    
#if !TARGET_OS_EMBEDDED
                    if(_usePatchIndexBuffer)
                    {
                        [renderCommandEncoder drawPatches:d.GetNumControlVertices()
                                         patchIndexBuffer:_patchIndexBuffers[offset] patchIndexBufferOffset:0
                                           indirectBuffer:_drawIndirectCommandsBuffer indirectBufferOffset: sizeof(MTLDrawPatchIndirectArguments) * offset];
                    }
                    else
#endif
                    {
                        [renderCommandEncoder drawPatches:d.GetNumControlVertices() patchStart:0 patchCount:patch.GetNumPatches()
                                         patchIndexBuffer:nil patchIndexBufferOffset:0 instanceCount:1 baseInstance:0];
                    }
                    [renderCommandEncoder setTriangleFillMode:MTLTriangleFillModeFill];
                }
            }
            break;
            
            
            case Far::PatchDescriptor::QUADS:
                [renderCommandEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:patch.GetNumPatches() * 6];
            break;
            case Far::PatchDescriptor::TRIANGLES:
                [renderCommandEncoder drawIndexedPrimitives:MTLPrimitiveTypeLine
                                    indexCount:patch.GetNumPatches() * d.GetNumControlVertices() indexType:MTLIndexTypeUInt32
                                   indexBuffer:pib indexBufferOffset:patch.GetIndexBase() * sizeof(uint32_t)
                                 instanceCount:1 baseVertex:0 baseInstance:0];
            break;
        }
    }
}

-(void)_computeTessFactors:(id<MTLComputeCommandEncoder>)computeCommandEncoder {
    auto& patchArray = _mesh->GetPatchTable()->GetPatchArrays();
    
    [computeCommandEncoder setBuffer:_mesh->BindVertexBuffer() offset:0 atIndex:VERTEX_BUFFER_INDEX];
    [computeCommandEncoder setBuffer:_mesh->GetPatchTable()->GetPatchIndexBuffer() offset:0 atIndex:CONTROL_INDICES_BUFFER_INDEX];
    [computeCommandEncoder setBuffer:_mesh->GetPatchTable()->GetPatchParamBuffer() offset:0 atIndex:OSD_PATCHPARAM_BUFFER_INDEX];
    [computeCommandEncoder setBuffer:_perPatchDataBuffer offset:0 atIndex:OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX];
    [computeCommandEncoder setBuffer:_hsDataBuffer offset:0 atIndex:OSD_PERPATCHTESSFACTORS_BUFFER_INDEX];
    [computeCommandEncoder setBuffer:_tessFactorsBuffer offset:0 atIndex:QUAD_TESSFACTORS_INDEX];
    [computeCommandEncoder setBuffer:_frameConstantsBuffer offset:0 atIndex:FRAME_CONST_BUFFER_INDEX];
    [computeCommandEncoder setBuffer:_perPatchDataBuffer offset:0 atIndex:OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX];
    
    for(auto& patch : patchArray)
    {
        auto usefulControlPoints = patch.GetDescriptor().GetNumControlVertices();
        if(patch.GetDescriptor().GetType() == Far::PatchDescriptor::GREGORY_BASIS)
            usefulControlPoints = 4;
        
        auto threadsPerThreadgroup = MTLSizeMake([_computePipelines[patch.GetPatchType()] threadExecutionWidth], 1, 1);
        auto threadsPerControlPoint = std::max<int>(1, usefulControlPoints / threadsPerThreadgroup.width);
        
        auto groupPerControlPoint = MTLSizeMake(patch.GetNumPatches() * usefulControlPoints, 1, 1);
        
        groupPerControlPoint.width /= threadsPerControlPoint;
        
        groupPerControlPoint.width = (groupPerControlPoint.width + threadsPerThreadgroup.width - 1) & ~(threadsPerThreadgroup.width - 1);
        groupPerControlPoint.width = groupPerControlPoint.width / threadsPerThreadgroup.width;
        
        
        auto groupPerPatch = MTLSizeMake(patch.GetNumPatches(), 1, 1);
        groupPerPatch.width = (groupPerPatch.width + threadsPerThreadgroup.width - 1) & ~(threadsPerThreadgroup.width - 1);
        groupPerPatch.width = groupPerPatch.width / threadsPerThreadgroup.width;
        
        [computeCommandEncoder setBufferOffset:patch.primitiveIdBase * sizeof(int) * 3 atIndex:OSD_PATCHPARAM_BUFFER_INDEX];
        [computeCommandEncoder setBufferOffset:patch.indexBase * sizeof(unsigned) atIndex:INDICES_BUFFER_INDEX];
        
        
        if(_usePatchIndexBuffer)
        {
            [computeCommandEncoder setBuffer:_patchIndexBuffers[patch.desc.GetType() - Far::PatchDescriptor::REGULAR] offset:0 atIndex:OSD_PATCH_INDEX_BUFFER_INDEX];
            [computeCommandEncoder setBuffer:_drawIndirectCommandsBuffer offset:sizeof(MTLDrawPatchIndirectArguments) * (patch.desc.GetType() - Far::PatchDescriptor::REGULAR) atIndex:OSD_DRAWINDIRECT_BUFFER_INDEX];
        }
        
        [computeCommandEncoder setComputePipelineState:_computePipelines[patch.desc.GetType()]];
        
        unsigned kernelExecutionLimit;
        switch(patch.desc.GetType())
        {
            case Far::PatchDescriptor::REGULAR:
                kernelExecutionLimit = patch.GetNumPatches() * patch.desc.GetNumControlVertices();
                [computeCommandEncoder setBufferOffset:_tessFactorOffsets[0] atIndex:QUAD_TESSFACTORS_INDEX];
                [computeCommandEncoder setBufferOffset:_perPatchDataOffsets[0] atIndex:OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX];
                break;
            case Far::PatchDescriptor::GREGORY_BASIS:
                kernelExecutionLimit = patch.GetNumPatches() * 4;
                [computeCommandEncoder setBufferOffset:_tessFactorOffsets[3] atIndex:QUAD_TESSFACTORS_INDEX];
                [computeCommandEncoder setBufferOffset:_perPatchDataOffsets[3] atIndex:OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX];
                break;
            default: return;
        }
        
        [computeCommandEncoder setBytes:&kernelExecutionLimit length:sizeof(kernelExecutionLimit) atIndex:OSD_KERNELLIMIT_BUFFER_INDEX];
        [computeCommandEncoder dispatchThreadgroups:groupPerControlPoint threadsPerThreadgroup:threadsPerThreadgroup];
    }
}

-(void)_rebuildState {
    [self _rebuildTextures];
    [self _rebuildModel];
    [self _rebuildBuffers];
    [self _rebuildPipelines];
    
    _needsRebuild = false;
}

-(void)_rebuildTextures {
    _colorPtexture.reset();
    _displacementPtexture.reset();
    _occlusionPtexture.reset();
    _specularPtexture.reset();
    
    _colorPtexture = [self _createPtex:_ptexColorFilename];
    if(_ptexDisplacementFilename) {
        _displacementPtexture = [self _createPtex:_ptexDisplacementFilename];
    }
}

-(std::unique_ptr<MTLPtexMipmapTexture>)_createPtex:(NSString*) filename {
    
    Ptex::String ptexError;
    printf("Loading ptex : %s\n", filename.UTF8String);
#if TARGET_OS_EMBEDDED
    const auto path = [[NSBundle mainBundle] pathForResource:filename ofType:nil];
#else
    const auto path = filename;
#endif
    
#define USE_PTEX_CACHE 1
#define PTEX_CACHE_SIZE (512*1024*1024)
    
#if USE_PTEX_CACHE
    PtexCache *cache = PtexCache::create(1, PTEX_CACHE_SIZE);
    PtexTexture *ptex = cache->get(path.UTF8String, ptexError);
#else
    PtexTexture *ptex = PtexTexture::open(path.UTF8String, ptexError, true);
#endif
    
    if (ptex == NULL) {
        printf("Error in reading %s\n", filename.UTF8String);
        exit(1);
    }
    
    std::unique_ptr<MTLPtexMipmapTexture> osdPtex(MTLPtexMipmapTexture::Create(&_context, ptex));
    
    ptex->release();
    
#if USE_PTEX_CACHE
    cache->release();
#endif
    
    return osdPtex;
}

-(std::unique_ptr<Shape>)_shapeFromPtex:(Ptex::PtexTexture*) tex {
    const auto meta = tex->getMetaData();
    
    if (meta->numKeys() < 3) {
        return NULL;
    }
    
    float const * vp;
    int const *vi, *vc;
    int nvp, nvi, nvc;
    
    meta->getValue("PtexFaceVertCounts", vc, nvc);
    if (nvc == 0) {
        return NULL;
    }
    meta->getValue("PtexVertPositions", vp, nvp);
    if (nvp == 0) {
        return NULL;
    }
    meta->getValue("PtexFaceVertIndices", vi, nvi);
    if (nvi == 0) {
        return NULL;
    }
    
    std::unique_ptr<Shape> shape(new Shape);
    
    shape->scheme = kCatmark;
    
    shape->verts.resize(nvp);
    for (int i=0; i<nvp; ++i) {
        shape->verts[i] = vp[i];
    }
    
    shape->nvertsPerFace.resize(nvc);
    for (int i=0; i<nvc; ++i) {
        shape->nvertsPerFace[i] = vc[i];
    }
    
    shape->faceverts.resize(nvi);
    for (int i=0; i<nvi; ++i) {
        shape->faceverts[i] = vi[i];
    }
    
    // compute model bounding
    float min[3] = {vp[0], vp[1], vp[2]};
    float max[3] = {vp[0], vp[1], vp[2]};
    for (int i = 0; i < nvp/3; ++i) {
        for (int j = 0; j < 3; ++j) {
            float v = vp[i*3+j];
            min[j] = std::min(min[j], v);
            max[j] = std::max(max[j], v);
        }
    }
    
    for (int j = 0; j < 3; ++j) {
        _meshCenter[j] = (min[j] + max[j]) * 0.5f;
        _meshSize += (max[j]-min[j])*(max[j]-min[j]);
    }
    _meshSize = sqrtf(_meshSize);
    
    return shape;
}

-(void)_rebuildModel {
    
    using namespace OpenSubdiv;
    using namespace Sdc;
    using namespace Osd;
    using namespace Far;
    
    Ptex::String ptexError;
#if TARGET_OS_EMBEDDED
    const auto ptexColor = PtexTexture::open([[NSBundle mainBundle] pathForResource:_ptexColorFilename ofType:nil].UTF8String, ptexError);
#else
    const auto ptexColor = PtexTexture::open(_ptexColorFilename.UTF8String, ptexError);
#endif
    _shape = [self _shapeFromPtex:ptexColor];
    
    // create Far mesh (topology)
    Sdc::SchemeType sdctype = GetSdcType(*_shape);
    Sdc::Options sdcoptions = GetSdcOptions(*_shape);
    
    std::unique_ptr<OpenSubdiv::Far::TopologyRefiner> refiner;
    refiner.reset(
                  Far::TopologyRefinerFactory<Shape>::Create(*_shape, Far::TopologyRefinerFactory<Shape>::Options(sdctype, sdcoptions)));
    
    // save coarse topology (used for coarse mesh drawing)
    Far::TopologyLevel const & refBaseLevel = refiner->GetLevel(0);
    
    // Adaptive refinement currently supported only for catmull-clark scheme
    _doAdaptive = (_useAdaptive);
    bool doSingleCreasePatch = (_useSingleCrease);
    
    Osd::MeshBitset bits;
    bits.set(Osd::MeshAdaptive, _doAdaptive);
    bits.set(Osd::MeshUseSingleCreasePatch, doSingleCreasePatch);
    bits.set(Osd::MeshEndCapGregoryBasis, true);
    
    int level = _refinementLevel;
    _numVertexElements = 3;
    int numVaryingElements = 0;
    
    if(_kernelType == kCPU)
    {
        _mesh.reset(new CPUMeshType(
                                    refiner.release(),
                                    _numVertexElements,
                                    numVaryingElements,
                                    level, bits, nullptr, &_context));
    }
    else
    {
        _mesh.reset(new MTLMeshType(
                                    refiner.release(),
                                    _numVertexElements,
                                    numVaryingElements,
                                    level, bits, nullptr, &_context));
    }
    
    
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    [_delegate setupRenderPipelineState:desc for:self];
    
    const auto vertexDescriptor = desc.vertexDescriptor;
    vertexDescriptor.layouts[0].stride = sizeof(float) * _numVertexElements;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    vertexDescriptor.layouts[0].stepRate = 1;
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;
    
    _numVertices = refBaseLevel.GetNumVertices();
    
    _vertexData.resize(refBaseLevel.GetNumVertices() * _numVertexElements);
    _meshCenter = simd::float3{0,0,0};
    
    
    for(int vertexIdx = 0; vertexIdx < refBaseLevel.GetNumVertices(); vertexIdx++)
    {
        _vertexData[vertexIdx * _numVertexElements + 0] = _shape->verts[vertexIdx * 3 + 0];
        _vertexData[vertexIdx * _numVertexElements + 1] = _shape->verts[vertexIdx * 3 + 1];
        _vertexData[vertexIdx * _numVertexElements + 2] = _shape->verts[vertexIdx * 3 + 2];
        
        _meshCenter[0] += _vertexData[vertexIdx * _numVertexElements + 0];
        _meshCenter[1] += _vertexData[vertexIdx * _numVertexElements + 1];
        _meshCenter[2] += _vertexData[vertexIdx * _numVertexElements + 2];
    }

    _meshCenter /= (_shape->verts.size() / 3);
    _mesh->UpdateVertexBuffer(_vertexData.data(), 0, refBaseLevel.GetNumVertices());
    _mesh->Refine();
    _mesh->Synchronize();
}

-(void)_updateState {
    [self _updateCamera];
    auto pData = _frameConstantsBuffer.data();
    
    pData->TessLevel = _tessellationLevel;
    pData->displacementConfig.mipmapBias = _mipmapBias;
    pData->displacementConfig.displacementScale = _displacementScale;
    
    {
        for(auto& patch : _mesh->GetPatchTable()->GetPatchArrays())
        {
            if(_usePatchIndexBuffer)
            {
                MTLDrawPatchIndirectArguments* drawCommand = _drawIndirectCommandsBuffer.data();
                drawCommand[patch.desc.GetType() - Far::PatchDescriptor::REGULAR].baseInstance = 0;
                drawCommand[patch.desc.GetType() - Far::PatchDescriptor::REGULAR].instanceCount = 1;
                drawCommand[patch.desc.GetType() - Far::PatchDescriptor::REGULAR].patchCount = 0;
                drawCommand[patch.desc.GetType() - Far::PatchDescriptor::REGULAR].patchStart = 0;
            }
        }
        
        if(_usePatchIndexBuffer)
        {
            _drawIndirectCommandsBuffer.markModified();
        }
    }

    _frameConstantsBuffer.markModified();
}

-(void)_rebuildBuffers {
    auto totalPatches = 0;
    auto totalVertices = 0;
    auto totalPatchDataSize = 0;
    
    if(_usePatchIndexBuffer)
    {
        _drawIndirectCommandsBuffer.alloc(_context.device, 4, @"draw patch indirect commands");
    }
    
    if(_doAdaptive)
    {
        auto& patchArray = _mesh->GetPatchTable()->GetPatchArrays();
        for(auto& patch : patchArray)
        {
            auto patchDescriptor = patch.GetDescriptor();
            
            switch(patch.desc.GetType())
            {
                case Far::PatchDescriptor::REGULAR: {
                    if(_usePatchIndexBuffer)
                    {
                        _patchIndexBuffers[0].alloc(_context.device, patch.GetNumPatches(), @"regular patch indices", MTLResourceStorageModePrivate);
                    }
                    _tessFactorOffsets[0] = totalPatches * sizeof(MTLQuadTessellationFactorsHalf);
                    _perPatchDataOffsets[0] = totalPatchDataSize;
                    float elementFloats = 3;
                    if(_useSingleCrease)
                        elementFloats += 6;
                    
                    totalPatchDataSize += elementFloats * sizeof(float) * patch.GetNumPatches() * patch.desc.GetNumControlVertices();
                }
                break;
                case Far::PatchDescriptor::GREGORY:
                if(_usePatchIndexBuffer)
                {
                    _patchIndexBuffers[1].alloc(_context.device, patch.GetNumPatches(), @"gregory patch indices", MTLResourceStorageModePrivate);
                }
                _tessFactorOffsets[1] = totalPatches * sizeof(MTLQuadTessellationFactorsHalf);
                _perPatchDataOffsets[1] = totalPatchDataSize;
                totalPatchDataSize += sizeof(float) * 4 * 8 * patch.GetNumPatches() * patch.desc.GetNumControlVertices();
                break;
                case Far::PatchDescriptor::GREGORY_BOUNDARY:
                if(_usePatchIndexBuffer)
                {
                    _patchIndexBuffers[2].alloc(_context.device, patch.GetNumPatches(), @"gregory boundry patch indices", MTLResourceStorageModePrivate);
                }
                _tessFactorOffsets[2] = totalPatches * sizeof(MTLQuadTessellationFactorsHalf);
                _perPatchDataOffsets[2] = totalPatchDataSize;
                totalPatchDataSize += sizeof(float) * 4 * 8 * patch.GetNumPatches() * patch.desc.GetNumControlVertices();
                break;
                case Far::PatchDescriptor::GREGORY_BASIS:
                if(_usePatchIndexBuffer)
                {
                    _patchIndexBuffers[3].alloc(_context.device, patch.GetNumPatches(), @"gregory basis patch indices", MTLResourceStorageModePrivate);
                }
                _tessFactorOffsets[3] = totalPatches * sizeof(MTLQuadTessellationFactorsHalf);
                _perPatchDataOffsets[3] = totalPatchDataSize;
                //Improved basis doesn't have per-patch-per-vertex data. But we need to have at least 4 so a buffer is allocated
                totalPatchDataSize += 4;
                //                totalPatchDataSize += sizeof(float) * 4 * 2 * patch.GetNumPatches() * patch.desc.GetNumControlVertices();
                break;
            }
            
            totalPatches += patch.GetNumPatches();
            totalVertices += patch.GetDescriptor().GetNumControlVertices() * patch.GetNumPatches();
        }
        
        _perPatchDataBuffer.alloc(_context.device, totalPatchDataSize, @"per patch data", MTLResourceStorageModePrivate);
        _hsDataBuffer.alloc(_context.device, 20 * sizeof(float) * totalPatches, @"hs constant data", MTLResourceStorageModePrivate);
        _tessFactorsBuffer.alloc(_context.device, totalPatches, @"tessellation factors buffer", MTLResourceStorageModePrivate);
    
    }
}

-(void)_rebuildPipelines {
    for(int i = 0; i < 10; i++) {
        _computePipelines[i] = nil;
        _renderPipelines[i] = nil;
    }
    
    Osd::MTLPatchShaderSource shaderSource;
    auto& patchArrays = _mesh->GetPatchTable()->GetPatchArrays();
    for(auto& patch : patchArrays)
    {
        int threadsPerThreadgroup = 32;
        int usefulControlPoints = patch.GetDescriptor().GetNumControlVertices();
        auto controlPointsPerThread = [&]() {
            return std::max<int>(1, usefulControlPoints  / threadsPerThreadgroup);
        };
        
        auto type = patch.GetDescriptor().GetType();
        auto compileOptions = [[MTLCompileOptions alloc] init];
        compileOptions.fastMathEnabled = YES;
        
        auto preprocessor = [[NSMutableDictionary alloc] init];
#define DEFINE(x, y) preprocessor[@(#x)] = @(y)
        bool allowsSingleCrease = true;
        std::stringstream shaderBuilder;
        switch(type)
        {
            case Far::PatchDescriptor::QUADS:
                DEFINE(OSD_PATCH_QUADS, 1);
                break;
            case Far::PatchDescriptor::REGULAR:
                DEFINE(OSD_PATCH_REGULAR, 1);
                DEFINE(CONTROL_POINTS_PER_PATCH, 16);
                break;
            case Far::PatchDescriptor::GREGORY:
                DEFINE(OSD_PATCH_GREGORY, 1);
                DEFINE(CONTROL_POINTS_PER_PATCH, 4);
                usefulControlPoints = 4;
                allowsSingleCrease = false;
                break;
            case Far::PatchDescriptor::GREGORY_BASIS:
                DEFINE(OSD_PATCH_GREGORY_BASIS, 1);
                DEFINE(CONTROL_POINTS_PER_PATCH, 4);
                allowsSingleCrease = false;
                usefulControlPoints = 4;
                break;
            case Far::PatchDescriptor::GREGORY_BOUNDARY:
                DEFINE(OSD_PATCH_GREGORY_BOUNDARY, 1);
                DEFINE(CONTROL_POINTS_PER_PATCH, 4);
                allowsSingleCrease = false;
                usefulControlPoints = 4;
                break;
        }
        
#if TARGET_OS_EMBEDDED
        shaderBuilder << "#define OSD_UV_CORRECTION if(t > 0.5){ ti += 0.01f; } else { ti += 0.01f; }\n";
#endif
        
        //Need to define the input vertex struct so that it's available everywhere.
        shaderBuilder << R"(
#include <metal_stdlib>
        struct OsdInputVertexType {
            metal::packed_float3 position;
        };
        )";
        
        auto fvarType = Far::PatchDescriptor::REGULAR;
        shaderBuilder << shaderSource.GetHullShaderSource(type, fvarType);
        shaderBuilder << MTLPtexMipmapTexture::GetShaderSource();
        shaderBuilder << _osdShaderSource.UTF8String;
        
        const auto str = shaderBuilder.str();
        
        DEFINE(CONFIG_BUFFER_INDEX,CONFIG_BUFFER_INDEX);
        DEFINE(VERTEX_BUFFER_INDEX,VERTEX_BUFFER_INDEX);
        DEFINE(PATCH_INDICES_BUFFER_INDEX,PATCH_INDICES_BUFFER_INDEX);
        DEFINE(CONTROL_INDICES_BUFFER_INDEX,CONTROL_INDICES_BUFFER_INDEX);
        DEFINE(OSD_PATCHPARAM_BUFFER_INDEX,OSD_PATCHPARAM_BUFFER_INDEX);
        DEFINE(OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX,OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX);
        DEFINE(OSD_PERPATCHTESSFACTORS_BUFFER_INDEX,OSD_PERPATCHTESSFACTORS_BUFFER_INDEX);
        DEFINE(OSD_VALENCE_BUFFER_INDEX,OSD_VALENCE_BUFFER_INDEX);
        DEFINE(OSD_QUADOFFSET_BUFFER_INDEX,OSD_QUADOFFSET_BUFFER_INDEX);
        DEFINE(FRAME_CONST_BUFFER_INDEX,FRAME_CONST_BUFFER_INDEX);
        DEFINE(INDICES_BUFFER_INDEX,INDICES_BUFFER_INDEX);
        DEFINE(QUAD_TESSFACTORS_INDEX,QUAD_TESSFACTORS_INDEX);
        DEFINE(OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX,OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX);
        DEFINE(OSD_PATCH_INDEX_BUFFER_INDEX,OSD_PATCH_INDEX_BUFFER_INDEX);
        DEFINE(OSD_DRAWINDIRECT_BUFFER_INDEX,OSD_DRAWINDIRECT_BUFFER_INDEX);
        DEFINE(DISPLACEMENT_TEXTURE_INDEX,DISPLACEMENT_TEXTURE_INDEX);
        DEFINE(DISPLACEMENT_BUFFER_INDEX,DISPLACEMENT_BUFFER_INDEX);
        DEFINE(IMAGE_TEXTURE_INDEX,IMAGE_TEXTURE_INDEX);
        DEFINE(IMAGE_BUFFER_INDEX,IMAGE_BUFFER_INDEX);
        DEFINE(OCCLUSION_TEXTURE_INDEX,OCCLUSION_TEXTURE_INDEX);
        DEFINE(OCCLUSION_BUFFER_INDEX,OCCLUSION_BUFFER_INDEX);
        DEFINE(SPECULAR_TEXTURE_INDEX,SPECULAR_TEXTURE_INDEX);
        DEFINE(SPECULAR_BUFFER_INDEX,SPECULAR_BUFFER_INDEX);
        DEFINE(OSD_KERNELLIMIT_BUFFER_INDEX,OSD_KERNELLIMIT_BUFFER_INDEX);
        DEFINE(OSD_PATCH_ENABLE_SINGLE_CREASE, allowsSingleCrease && _useSingleCrease);
        
        DEFINE(COLOR_NORMAL, _colorMode == kColorModeNormal);
        DEFINE(COLOR_PATCHTYPE, _colorMode == kColorModePatchType);
        DEFINE(COLOR_PATCHCOORD, _colorMode == kColorModePatchCoord);
        DEFINE(COLOR_PTEX_BIQUADRATIC, _colorMode == kColorModePtexBiQuadratic);
        DEFINE(COLOR_PTEX_BILINEAR, _colorMode == kColorModePtexBilinear);
        DEFINE(COLOR_PTEX_NEAREST, _colorMode == kColorModePtexNearest);
        DEFINE(COLOR_PTEX_HW_BILINEAR, _colorMode == kColorModePtexHWBilinear);

        DEFINE(NORMAL_SCREENSPACE, _normalMode == kNormalModeScreenspace);
        DEFINE(NORMAL_HW_SCREENSPACE, _normalMode == kNormalModeHWScreenspace);
        DEFINE(NORMAL_BIQUADRATIC_WG, _normalMode == kNormalModeBiQuadraticWG);
        DEFINE(NORMAL_BIQUADRATIC, _normalMode == kNormalModeBiQuadratic);
        
        DEFINE(DISPLACEMENT_BILINEAR, _displacementMode == kDisplacementModeBilinear);
        DEFINE(DISPLACEMENT_HW_BILINEAR, _displacementMode == kDisplacementModeHWBilinear);
        DEFINE(DISPLACEMENT_BIQUADRATIC, _displacementMode == kDisplacementModeBiQuadratic);
        
        DEFINE(OSD_COMPUTE_NORMAL_DERIVATIVES, _normalMode == kNormalModeBiQuadraticWG);

        auto partitionMode = _useScreenspaceTessellation ? MTLTessellationPartitionModeFractionalOdd : MTLTessellationPartitionModePow2;
        DEFINE(OSD_FRACTIONAL_EVEN_SPACING, partitionMode == MTLTessellationPartitionModeFractionalEven);
        DEFINE(OSD_FRACTIONAL_ODD_SPACING, partitionMode == MTLTessellationPartitionModeFractionalOdd);
#if TARGET_OS_EMBEDDED
        DEFINE(OSD_MAX_TESS_LEVEL, 16);
#else
        DEFINE(OSD_MAX_TESS_LEVEL, 64);
#endif
        DEFINE(USE_STAGE_IN, 1);
        DEFINE(USE_PTVS_FACTORS, !_useScreenspaceTessellation);
        DEFINE(USE_PTVS_SHARPNESS, 1);
        DEFINE(THREADS_PER_THREADGROUP, threadsPerThreadgroup);
        DEFINE(CONTROL_POINTS_PER_THREAD, controlPointsPerThread());
        DEFINE(VERTEX_CONTROL_POINTS_PER_PATCH, patch.desc.GetNumControlVertices());
        DEFINE(OSD_MAX_VALENCE, _mesh->GetMaxValence());
        DEFINE(OSD_NUM_ELEMENTS, _numVertexElements);
        DEFINE(OSD_ENABLE_BACKPATCH_CULL, _usePatchClipCulling);
        DEFINE(OSD_USE_PATCH_INDEX_BUFFER, _usePatchIndexBuffer);
        DEFINE(SEAMLESS_MIPMAP, _useSeamlessMipmap);
        DEFINE(USE_PTEX_OCCLUSION, _occlusionPtexture != nullptr && _displayOcclusion);
        DEFINE(USE_PTEX_SPECULAR, _specularPtexture != nullptr && _displaySpecular);
        DEFINE(OSD_ENABLE_SCREENSPACE_TESSELLATION, _useScreenspaceTessellation && _useFractionalTessellation);
        DEFINE(OSD_ENABLE_PATCH_CULL, _usePatchClipCulling);

        compileOptions.preprocessorMacros = preprocessor;
        
        NSError* err = nil;
        auto librarySource = [NSString stringWithUTF8String:str.data()];
        auto library = [_context.device newLibraryWithSource:librarySource options:compileOptions error:&err];
        if(!library && err) {
            NSLog(@"%s", [err localizedDescription].UTF8String);
        }
        assert(library);
        auto vertexFunction = [library newFunctionWithName:@"vertex_main"];
        auto fragmentFunction = [library newFunctionWithName:@"fragment_main"];
        assert(vertexFunction && fragmentFunction);
        if(vertexFunction && fragmentFunction)
        {
            
            MTLRenderPipelineDescriptor* pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
            pipelineDesc.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
            pipelineDesc.tessellationPartitionMode = partitionMode;
            pipelineDesc.tessellationFactorScaleEnabled = false;
            pipelineDesc.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionPerPatch;
            
            if(type == Far::PatchDescriptor::GREGORY_BASIS)
                pipelineDesc.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeUInt32;
            
            [_delegate setupRenderPipelineState:pipelineDesc for:self];
            
            pipelineDesc.fragmentFunction = fragmentFunction;
            pipelineDesc.vertexFunction = vertexFunction;
            
            auto vertexDesc = pipelineDesc.vertexDescriptor;
            [vertexDesc reset];
            
            vertexDesc.layouts[OSD_PATCHPARAM_BUFFER_INDEX].stepFunction = MTLVertexStepFunctionPerPatch;
            vertexDesc.layouts[OSD_PATCHPARAM_BUFFER_INDEX].stepRate = 1;
            vertexDesc.layouts[OSD_PATCHPARAM_BUFFER_INDEX].stride = sizeof(int) * 3;
            
            
            vertexDesc.attributes[10].bufferIndex = OSD_PATCHPARAM_BUFFER_INDEX;
            vertexDesc.attributes[10].format = MTLVertexFormatInt3;
            vertexDesc.attributes[10].offset = 0;
            
            switch(type)
            {
                case Far::PatchDescriptor::REGULAR:
                    vertexDesc.layouts[OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX].stepFunction = MTLVertexStepFunctionPerPatchControlPoint;
                    vertexDesc.layouts[OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX].stepRate = 1;
                    vertexDesc.layouts[OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX].stride = sizeof(float) * 3;
                    
                    vertexDesc.attributes[0].bufferIndex = OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX;
                    vertexDesc.attributes[0].format = MTLVertexFormatFloat3;
                    vertexDesc.attributes[0].offset = 0;
                    
                    if(_useSingleCrease)
                    {
                        vertexDesc.layouts[OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX].stride += sizeof(float) * 6;
                        
                        vertexDesc.attributes[1].bufferIndex = OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX;
                        vertexDesc.attributes[1].format = MTLVertexFormatFloat3;
                        vertexDesc.attributes[1].offset = sizeof(float) * 3;
                        
                        vertexDesc.attributes[2].bufferIndex = OSD_PERPATCHVERTEXBEZIER_BUFFER_INDEX;
                        vertexDesc.attributes[2].format = MTLVertexFormatFloat3;
                        vertexDesc.attributes[2].offset = sizeof(float) * 6;
                    }
                    
                    if(_useScreenspaceTessellation)
                    {
                        vertexDesc.layouts[OSD_PERPATCHTESSFACTORS_BUFFER_INDEX].stepFunction = MTLVertexStepFunctionPerPatch;
                        vertexDesc.layouts[OSD_PERPATCHTESSFACTORS_BUFFER_INDEX].stepRate = 1;
                        vertexDesc.layouts[OSD_PERPATCHTESSFACTORS_BUFFER_INDEX].stride = sizeof(float) * 8;
                        
                        vertexDesc.attributes[5].bufferIndex = OSD_PERPATCHTESSFACTORS_BUFFER_INDEX;
                        vertexDesc.attributes[5].format = MTLVertexFormatFloat4;
                        vertexDesc.attributes[5].offset = 0;
                        
                        vertexDesc.attributes[6].bufferIndex = OSD_PERPATCHTESSFACTORS_BUFFER_INDEX;
                        vertexDesc.attributes[6].format = MTLVertexFormatFloat4;
                        vertexDesc.attributes[6].offset = sizeof(float) * 4;
                    }
                break;
                case Far::PatchDescriptor::GREGORY_BOUNDARY:
                case Far::PatchDescriptor::GREGORY:
                    
                    vertexDesc.layouts[OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX].stepFunction = MTLVertexStepFunctionPerPatchControlPoint;
                    vertexDesc.layouts[OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX].stepRate = 1;
                    vertexDesc.layouts[OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX].stride = sizeof(float) * 3 * 5;
                    
                    for(int i = 0; i < 5; i++)
                    {
                        vertexDesc.attributes[i].bufferIndex = OSD_PERPATCHVERTEXGREGORY_BUFFER_INDEX;
                        vertexDesc.attributes[i].format = MTLVertexFormatFloat3;
                        vertexDesc.attributes[i].offset = i * sizeof(float) * 3;
                    }
                break;
                case Far::PatchDescriptor::GREGORY_BASIS:
                    vertexDesc.layouts[VERTEX_BUFFER_INDEX].stepFunction = MTLVertexStepFunctionPerPatchControlPoint;
                    vertexDesc.layouts[VERTEX_BUFFER_INDEX].stepRate = 1;
                    vertexDesc.layouts[VERTEX_BUFFER_INDEX].stride = sizeof(float) * 3;
                    
                    vertexDesc.attributes[0].bufferIndex = VERTEX_BUFFER_INDEX;
                    vertexDesc.attributes[0].format = MTLVertexFormatFloat3;
                    vertexDesc.attributes[0].offset = 0;
                break;
                case Far::PatchDescriptor::QUADS:
                case Far::PatchDescriptor::TRIANGLES:
                    [vertexDesc reset];
                    break;
            }
            
            
            _renderPipelines[type] = [_context.device newRenderPipelineStateWithDescriptor:pipelineDesc error:&err];
            if(!_renderPipelines[type] && err)
            {
                NSLog(@"%s", [[err localizedDescription] UTF8String]);
            }
        }
        
        auto computeFunction = [library newFunctionWithName:@"compute_main"];
        if(computeFunction)
        {
            MTLComputePipelineDescriptor* computeDesc = [[MTLComputePipelineDescriptor alloc] init];
#if MTL_TARGET_IPHONE
            computeDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = true;
#else
            computeDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = false;
#endif
            computeDesc.computeFunction = computeFunction;
            
            
            NSError* err;
            
            _computePipelines[type] = [_context.device newComputePipelineStateWithDescriptor:computeDesc options:MTLPipelineOptionNone reflection:nil error:&err];
            
            if(err && _computePipelines[type] == nil)
            {
                NSLog(@"%s", [[err description] UTF8String]);
            }
            
            if(_computePipelines[type].threadExecutionWidth != threadsPerThreadgroup)
            {
                preprocessor[@"THREADS_PER_THREADGROUP"] = @(_computePipelines[type].threadExecutionWidth);
                preprocessor[@"CONTROL_POINTS_PER_THREAD"] = @(std::max<int>(1, usefulControlPoints / _computePipelines[type].threadExecutionWidth));
                compileOptions.preprocessorMacros = preprocessor;
                
                library = [_context.device newLibraryWithSource:librarySource options:compileOptions error:nil];
                assert(library);
                
                computeDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = true;
                computeDesc.computeFunction = [library newFunctionWithName:@"compute_main"];
                
                threadsPerThreadgroup = _computePipelines[type].threadExecutionWidth;
                _computePipelines[type] = [_context.device newComputePipelineStateWithDescriptor:computeDesc options:MTLPipelineOptionNone reflection:nil error:&err];
                assert(_computePipelines[type].threadExecutionWidth == threadsPerThreadgroup);
            }
        }
    }
    
    MTLDepthStencilDescriptor* depthStencilDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStencilDesc.depthCompareFunction = MTLCompareFunctionLess;
    
    [_delegate setupDepthStencilState:depthStencilDesc for:self];
    
    depthStencilDesc.depthWriteEnabled = YES;
    _readWriteDepthStencilState = [_context.device newDepthStencilStateWithDescriptor:depthStencilDesc];
    
    depthStencilDesc.depthWriteEnabled = NO;
    _readOnlyDepthStencilState = [_context.device newDepthStencilStateWithDescriptor:depthStencilDesc];
}

-(void)_updateCamera {
    auto pData = _frameConstantsBuffer.data();
    
    identity(pData->ModelViewMatrix);
    translate(pData->ModelViewMatrix, 0, 0, -_cameraData.dollyDistance);
    rotate(pData->ModelViewMatrix, _cameraData.rotationY, 1, 0, 0);
    rotate(pData->ModelViewMatrix, _cameraData.rotationX, 0, 1, 0);
    translate(pData->ModelViewMatrix, -_meshCenter[0], -_meshCenter[2], _meshCenter[1]); // z-up model
    rotate(pData->ModelViewMatrix, -90, 1, 0, 0); // z-up model
    inverseMatrix(pData->ModelViewInverseMatrix, pData->ModelViewMatrix);
    
    identity(pData->ProjectionMatrix);
    perspective(pData->ProjectionMatrix, 45.0, _cameraData.aspectRatio, 0.01f, 500.0);
    multMatrix(pData->ModelViewProjectionMatrix, pData->ModelViewMatrix, pData->ProjectionMatrix);
    
}


-(void)_initializeBuffers {
    _frameConstantsBuffer.alloc(_context.device, 1, @"frame constants");
    _tessFactorsBuffer.alloc(_context.device, 1, @"tessellation factors", MTLResourceStorageModePrivate);
    _lightsBuffer.alloc(_context.device, 2, @"lights");
}

-(void)_initializeCamera {
    _cameraData.dollyDistance = 4;
    _cameraData.rotationY = 30;
    _cameraData.rotationX = 0;
    _cameraData.aspectRatio = 1;
}

-(void)_initializeLights {
    _lightsBuffer[0] = {
        simd::normalize(simd::float4{ 0.5,  0.2f, 1.0f, 0.0f }),
        { 0.1f, 0.1f, 0.1f, 1.0f },
        { 0.7f, 0.7f, 0.7f, 1.0f },
        { 0.8f, 0.8f, 0.8f, 1.0f },
    };
    
    _lightsBuffer[1] = {
        simd::normalize(simd::float4{ -0.8f, 0.4f, -1.0f, 0.0f }),
        {  0.0f, 0.0f,  0.0f, 1.0f },
        {  0.5f, 0.5f,  0.5f, 1.0f },
        {  0.8f, 0.8f,  0.8f, 1.0f }
    };
    
    _lightsBuffer.markModified();
}

-(void)_initializeModels {
    initShapes();
    _loadedModels = [[NSMutableArray alloc] initWithCapacity:g_defaultShapes.size()];
    int i = 0;
    for(auto& shape : g_defaultShapes)
    {
        _loadedModels[i++] = [NSString stringWithUTF8String:shape.name.c_str()];
    }
    _currentModel = _loadedModels[0];
}


//Setters for triggering _needsRebuild on property change

-(void)setKernelType:(KernelType)kernelType {
    _needsRebuild |= kernelType != _kernelType;
    _kernelType = kernelType;
}

-(void)setCurrentModel:(NSString *)currentModel {
    _needsRebuild |= ![currentModel isEqualToString:_currentModel];
    _currentModel = currentModel;
}

-(void)setRefinementLevel:(unsigned int)refinementLevel {
    _needsRebuild |= refinementLevel != _refinementLevel;
    _refinementLevel = refinementLevel;
}

-(void)setUseSingleCrease:(bool)useSingleCrease {
    _needsRebuild |= useSingleCrease != _useSingleCrease;
    _useSingleCrease = useSingleCrease;
}

-(void)setUsePatchClipCulling:(bool)usePatchClipCulling {
    _needsRebuild |= usePatchClipCulling != _usePatchClipCulling;
    _usePatchClipCulling = usePatchClipCulling;
}

-(void)setUsePatchIndexBuffer:(bool)usePatchIndexBuffer {
    _needsRebuild |= usePatchIndexBuffer != _usePatchIndexBuffer;
    _usePatchIndexBuffer = usePatchIndexBuffer;
}

-(void)setUsePatchBackfaceCulling:(bool)usePatchBackfaceCulling {
    _needsRebuild |= usePatchBackfaceCulling != _usePatchBackfaceCulling;
    _usePatchBackfaceCulling = usePatchBackfaceCulling;
}

-(void)setUseScreenspaceTessellation:(bool)useScreenspaceTessellation {
    _needsRebuild |= useScreenspaceTessellation != _useScreenspaceTessellation;
    _useScreenspaceTessellation = useScreenspaceTessellation;
}

-(void)setColorMode:(ColorMode)colorMode {
    _needsRebuild |= colorMode != _colorMode;
    _colorMode = colorMode;
}

-(void)setNormalMode:(NormalMode)normalMode {
    _needsRebuild |= normalMode != _normalMode;
    _normalMode = normalMode;
}

-(void)setDisplacementMode:(DisplacementMode)displacementMode {
    _needsRebuild |= displacementMode != _displacementMode;
    _displacementMode = displacementMode;
}

-(void)setUseAdaptive:(bool)useAdaptive {
    _needsRebuild |= useAdaptive != _useAdaptive;
    _useAdaptive = useAdaptive;
}

-(void)setDisplayOcclusion:(bool)displayOcclusion {
    _needsRebuild |= displayOcclusion != _displayOcclusion;
    _displayOcclusion = displayOcclusion;
}

-(void)setDisplaySpecular:(bool)displaySpecular {
    _needsRebuild |= displaySpecular != _displaySpecular;
    _displaySpecular = displaySpecular;
}

@end
