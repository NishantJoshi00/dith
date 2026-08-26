#import "depth_model.h"
#import <CoreML/CoreML.h>
#import <Vision/Vision.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

// The model's relative depth is normalized per frame. The range is eased over
// time so the picture does not pump when someone walks in or out of frame.
static const float kRangeEase = 0.15f;

// The model works in 14x14 patches and its map keeps that grid. A box blur
// about a patch wide smooths the steps out before the map becomes nearness.
static const int kBlurRadius = 7;

// Separable box blur in place, using `scratch` (same size) as a temporary
static void boxBlur(float* map, float* scratch, size_t width, size_t height, int radius) {
    // Horizontal
    for (size_t y = 0; y < height; y++) {
        const float* row = map + y * width;
        float* out = scratch + y * width;
        float sum = 0;
        int count = 0;
        for (int x = 0; x < radius && x < (int)width; x++) { sum += row[x]; count++; }
        for (size_t x = 0; x < width; x++) {
            int add = (int)x + radius;
            if (add < (int)width) { sum += row[add]; count++; }
            int drop = (int)x - radius - 1;
            if (drop >= 0) { sum -= row[drop]; count--; }
            out[x] = sum / count;
        }
    }
    // Vertical
    for (size_t x = 0; x < width; x++) {
        float sum = 0;
        int count = 0;
        for (int y = 0; y < radius && y < (int)height; y++) { sum += scratch[y * width + x]; count++; }
        for (size_t y = 0; y < height; y++) {
            int add = (int)y + radius;
            if (add < (int)height) { sum += scratch[add * width + x]; count++; }
            int drop = (int)y - radius - 1;
            if (drop >= 0) { sum -= scratch[drop * width + x]; count--; }
            map[y * width + x] = sum / count;
        }
    }
}

@interface DepthModel : NSObject
{
    VNCoreMLModel* model;
    VNCoreMLRequest* request;

    uint8_t* mapData;
    size_t mapDataSize;
    uint32_t mapWidth;
    uint32_t mapHeight;
    float* floatMap;      // depth as floats, blurred before normalization
    float* floatScratch;
    size_t floatCount;

    float rangeLo;
    float rangeHi;
    bool haveRange;

    // Scratch frame for RGB input, reused while the size stays the same
    CVPixelBufferRef scratch;
}
- (DepthError)loadModelAtPath:(NSString*)modelPath compiledPath:(NSString*)compiledPath;
- (DepthError)estimatePixelBuffer:(CVPixelBufferRef)buffer map:(DepthMap*)outMap;
- (DepthError)estimateRGB:(const uint8_t*)rgb width:(uint32_t)width height:(uint32_t)height bytesPerRow:(uint32_t)bytesPerRow map:(DepthMap*)outMap;
@end

// Compile a package into a temporary .mlmodelc, returning its URL (autoreleased)
static NSURL* compilePackage(NSURL* packageURL, NSError** error) {
    if (@available(macOS 13.0, *)) {
        __block NSURL* compiled = nil;
        __block NSError* compileError = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [MLModel compileModelAtURL:packageURL
                 completionHandler:^(NSURL* _Nullable url, NSError* _Nullable err) {
                     compiled = [url retain];
                     compileError = [err retain];
                     dispatch_semaphore_signal(done);
                 }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        dispatch_release(done);
        if (error) {
            *error = [compileError autorelease];
        } else {
            [compileError release];
        }
        return [compiled autorelease];
    } else {
        return [MLModel compileModelAtURL:packageURL error:error];
    }
}

@implementation DepthModel

- (id)init {
    self = [super init];
    if (self) {
        model = nil;
        request = nil;
        mapData = nullptr;
        mapDataSize = 0;
        mapWidth = 0;
        mapHeight = 0;
        floatMap = nullptr;
        floatScratch = nullptr;
        floatCount = 0;
        rangeLo = 0;
        rangeHi = 0;
        haveRange = false;
        scratch = NULL;
    }
    return self;
}

- (void)dealloc {
    [request release];
    [model release];
    if (mapData) {
        free(mapData);
    }
    if (floatMap) {
        free(floatMap);
    }
    if (floatScratch) {
        free(floatScratch);
    }
    if (scratch) {
        CVPixelBufferRelease(scratch);
    }
    [super dealloc];
}

- (DepthError)loadModelAtPath:(NSString*)modelPath compiledPath:(NSString*)compiledPath {
    NSFileManager* files = [NSFileManager defaultManager];
    NSURL* modelURL = [NSURL fileURLWithPath:modelPath];

    if (![modelPath hasSuffix:@".mlmodelc"]) {
        // Compile once; later runs load the compiled copy directly
        if (![files fileExistsAtPath:compiledPath]) {
            NSError* error = nil;
            NSURL* temporary = compilePackage(modelURL, &error);
            if (!temporary) {
                return DEPTH_ERROR_COMPILE;
            }
            NSString* parent = [compiledPath stringByDeletingLastPathComponent];
            [files createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![files moveItemAtURL:temporary toURL:[NSURL fileURLWithPath:compiledPath] error:&error]) {
                return DEPTH_ERROR_COMPILE;
            }
        }
        modelURL = [NSURL fileURLWithPath:compiledPath];
    }

    MLModelConfiguration* configuration = [[MLModelConfiguration alloc] init];
    configuration.computeUnits = MLComputeUnitsAll;
    NSError* error = nil;
    MLModel* coreModel = [MLModel modelWithContentsOfURL:modelURL configuration:configuration error:&error];
    [configuration release];
    if (!coreModel) {
        return DEPTH_ERROR_LOAD;
    }

    VNCoreMLModel* visionModel = [VNCoreMLModel modelForMLModel:coreModel error:&error];
    if (!visionModel) {
        return DEPTH_ERROR_LOAD;
    }

    VNCoreMLRequest* depthRequest = [[VNCoreMLRequest alloc] initWithModel:visionModel];
    depthRequest.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill;

    [request release];
    [model release];
    model = [visionModel retain];
    request = depthRequest;
    haveRange = false;
    return DEPTH_OK;
}

// Converts the model's depth image into the nearness map
- (DepthError)readDepthImage:(CVPixelBufferRef)depth {
    OSType format = CVPixelBufferGetPixelFormatType(depth);
    if (format != kCVPixelFormatType_OneComponent16Half &&
        format != kCVPixelFormatType_OneComponent32Float &&
        format != kCVPixelFormatType_OneComponent8) {
        return DEPTH_ERROR_UNSUPPORTED;
    }

    CVPixelBufferLockBaseAddress(depth, kCVPixelBufferLock_ReadOnly);
    const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(depth);
    size_t width = CVPixelBufferGetWidth(depth);
    size_t height = CVPixelBufferGetHeight(depth);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(depth);

    size_t size = width * height;
    if (!mapData || mapDataSize != size) {
        if (mapData) {
            free(mapData);
        }
        mapData = (uint8_t*)malloc(size);
        mapDataSize = size;
    }
    if (!floatMap || floatCount != size) {
        free(floatMap);
        free(floatScratch);
        floatMap = (float*)malloc(size * sizeof(float));
        floatScratch = (float*)malloc(size * sizeof(float));
        floatCount = size;
    }
    mapWidth = (uint32_t)width;
    mapHeight = (uint32_t)height;

    // Read the model output as floats
    for (size_t y = 0; y < height; y++) {
        const uint8_t* row = base + y * bytesPerRow;
        float* out = floatMap + y * width;
        for (size_t x = 0; x < width; x++) {
            if (format == kCVPixelFormatType_OneComponent16Half) {
                out[x] = (float)((const _Float16*)row)[x];
            } else if (format == kCVPixelFormatType_OneComponent32Float) {
                out[x] = ((const float*)row)[x];
            } else {
                out[x] = row[x];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(depth, kCVPixelBufferLock_ReadOnly);

    // Smooth away the model's patch grid
    boxBlur(floatMap, floatScratch, width, height, kBlurRadius);

    // This frame's range, eased into the running one
    float lo = INFINITY;
    float hi = -INFINITY;
    for (size_t i = 0; i < size; i++) {
        float v = floatMap[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    if (!haveRange) {
        rangeLo = lo;
        rangeHi = hi;
        haveRange = true;
    } else {
        rangeLo += kRangeEase * (lo - rangeLo);
        rangeHi += kRangeEase * (hi - rangeHi);
    }
    float span = rangeHi - rangeLo;
    float scale = span > 1e-6f ? 255.0f / span : 0.0f;

    // Larger model output = nearer, mapped to 0..255
    for (size_t i = 0; i < size; i++) {
        float n = (floatMap[i] - rangeLo) * scale;
        if (n < 0) n = 0;
        if (n > 255) n = 255;
        mapData[i] = (uint8_t)(n + 0.5f);
    }

    return DEPTH_OK;
}

- (DepthError)estimatePixelBuffer:(CVPixelBufferRef)buffer map:(DepthMap*)outMap {
    if (!request) {
        return DEPTH_ERROR_LOAD;
    }
    DepthError result = DEPTH_ERROR_INFERENCE;
    @autoreleasepool {
        VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer
                                                                                  orientation:kCGImagePropertyOrientationUp
                                                                                      options:@{}];
        NSError* error = nil;
        BOOL ok = [handler performRequests:@[request] error:&error];
        [handler release];
        if (ok) {
            VNObservation* observation = [request.results firstObject];
            if ([observation isKindOfClass:[VNPixelBufferObservation class]]) {
                result = [self readDepthImage:((VNPixelBufferObservation*)observation).pixelBuffer];
            } else {
                result = DEPTH_ERROR_UNSUPPORTED;
            }
        }
    }
    if (result == DEPTH_OK && outMap) {
        outMap->data = mapData;
        outMap->width = mapWidth;
        outMap->height = mapHeight;
        outMap->bytes_per_row = mapWidth;
    }
    return result;
}

- (DepthError)estimateRGB:(const uint8_t*)rgb width:(uint32_t)width height:(uint32_t)height bytesPerRow:(uint32_t)bytesPerRow map:(DepthMap*)outMap {
    if (scratch && (CVPixelBufferGetWidth(scratch) != width || CVPixelBufferGetHeight(scratch) != height)) {
        CVPixelBufferRelease(scratch);
        scratch = NULL;
    }
    if (!scratch) {
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL, &scratch) != kCVReturnSuccess) {
            return DEPTH_ERROR_INFERENCE;
        }
    }

    CVPixelBufferLockBaseAddress(scratch, 0);
    uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(scratch);
    size_t dstBytesPerRow = CVPixelBufferGetBytesPerRow(scratch);
    for (uint32_t y = 0; y < height; y++) {
        const uint8_t* src = rgb + (size_t)y * bytesPerRow;
        uint8_t* dst = base + (size_t)y * dstBytesPerRow;
        for (uint32_t x = 0; x < width; x++) {
            dst[x * 4 + 0] = src[x * 3 + 2];
            dst[x * 4 + 1] = src[x * 3 + 1];
            dst[x * 4 + 2] = src[x * 3 + 0];
            dst[x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(scratch, 0);

    return [self estimatePixelBuffer:scratch map:outMap];
}

@end

// C API

DepthError depth_model_create(const char* model_path, const char* compiled_path, DepthModelHandle* out_handle) {
    if (!model_path || !compiled_path || !out_handle) {
        return DEPTH_ERROR_LOAD;
    }
    @autoreleasepool {
        DepthModel* model = [[DepthModel alloc] init];
        DepthError result = [model loadModelAtPath:[NSString stringWithUTF8String:model_path]
                                      compiledPath:[NSString stringWithUTF8String:compiled_path]];
        if (result != DEPTH_OK) {
            [model release];
            return result;
        }
        *out_handle = (__bridge_retained void*)model;
        return DEPTH_OK;
    }
}

void depth_model_destroy(DepthModelHandle handle) {
    if (!handle) {
        return;
    }
    @autoreleasepool {
        DepthModel* model = (__bridge_transfer DepthModel*)handle;
        model = nil;
    }
}

DepthError depth_model_estimate_rgb(DepthModelHandle handle, const uint8_t* rgb, uint32_t width, uint32_t height, uint32_t bytes_per_row, DepthMap* out_map) {
    if (!handle || !rgb || !out_map) {
        return DEPTH_ERROR_INFERENCE;
    }
    @autoreleasepool {
        DepthModel* model = (__bridge DepthModel*)handle;
        return [model estimateRGB:rgb width:width height:height bytesPerRow:bytes_per_row map:out_map];
    }
}

DepthError depth_model_estimate_pixel_buffer(DepthModelHandle handle, CVPixelBufferRef buffer, DepthMap* out_map) {
    if (!handle || !buffer || !out_map) {
        return DEPTH_ERROR_INFERENCE;
    }
    @autoreleasepool {
        DepthModel* model = (__bridge DepthModel*)handle;
        return [model estimatePixelBuffer:buffer map:out_map];
    }
}
