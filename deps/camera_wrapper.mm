#import "camera_wrapper.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

@interface CameraCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    AVCaptureSession* session;
    AVCaptureDevice* device;
    AVCaptureDeviceInput* input;
    AVCaptureVideoDataOutput* output;
    dispatch_queue_t captureQueue;
    dispatch_semaphore_t frameSemaphore;

    uint8_t* imageData;
    size_t imageDataSize;
    uint32_t imageWidth;
    uint32_t imageHeight;
    uint32_t imageBytesPerRow;
    uint8_t* chromaData;
    size_t chromaDataSize;
    uint32_t chromaWidth;
    uint32_t chromaHeight;
    uint32_t chromaBytesPerRow;
    bool hasNewFrame;
    bool isOpen;

    DepthModelHandle depthModel;   // not owned
    uint8_t* maskData;
    size_t maskDataSize;
    uint32_t maskWidth;
    uint32_t maskHeight;
    uint32_t maskBytesPerRow;
    bool hasMask;
}

- (id)init;
- (void)dealloc;
- (CameraError)open;
- (void)close;
- (CameraError)captureFrame:(CameraImage*)outImage;
- (bool)isSessionOpen;
- (void)setDepthModel:(DepthModelHandle)model;

@end

@implementation CameraCapture

- (id)init {
    self = [super init];
    if (self) {
        session = nil;
        device = nil;
        input = nil;
        output = nil;
        captureQueue = nil;
        frameSemaphore = nil;
        imageData = nullptr;
        imageDataSize = 0;
        imageWidth = 0;
        imageHeight = 0;
        imageBytesPerRow = 0;
        chromaData = nullptr;
        chromaDataSize = 0;
        chromaWidth = 0;
        chromaHeight = 0;
        chromaBytesPerRow = 0;
        hasNewFrame = false;
        isOpen = false;
        depthModel = nullptr;
        maskData = nullptr;
        maskDataSize = 0;
        maskWidth = 0;
        maskHeight = 0;
        maskBytesPerRow = 0;
        hasMask = false;
    }
    return self;
}

- (void)dealloc {
    [self close];
    if (imageData) {
        free(imageData);
        imageData = nullptr;
    }
    if (chromaData) {
        free(chromaData);
        chromaData = nullptr;
    }
    if (maskData) {
        free(maskData);
        maskData = nullptr;
    }
    [super dealloc];
}

- (CameraError)open {
    if (isOpen) {
        return CAMERA_ERROR_ALREADY_OPEN;
    }

    // Create capture session
    session = [[AVCaptureSession alloc] init];
    if (!session) {
        return CAMERA_ERROR_SESSION;
    }

    // Set session preset for quality
    [session setSessionPreset:AVCaptureSessionPreset640x480];

    // Get default video device
    if (@available(macOS 10.15, *)) {
        device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                    mediaType:AVMediaTypeVideo
                                                     position:AVCaptureDevicePositionUnspecified];
    } else {
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }

    if (!device) {
        [session release];
        session = nil;
        return CAMERA_ERROR_NO_DEVICE;
    }

    // Create device input
    NSError* error = nil;
    input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input || error) {
        [session release];
        session = nil;
        device = nil;
        return CAMERA_ERROR_INIT;
    }

    // Add input to session
    if ([session canAddInput:input]) {
        [session addInput:input];
    } else {
        [session release];
        session = nil;
        device = nil;
        input = nil;
        return CAMERA_ERROR_SESSION;
    }

    // Create output
    output = [[AVCaptureVideoDataOutput alloc] init];
    if (!output) {
        [session release];
        session = nil;
        device = nil;
        input = nil;
        return CAMERA_ERROR_INIT;
    }

    // Configure output for grayscale (Y only from YUV)
    NSDictionary* videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    };
    [output setVideoSettings:videoSettings];

    // Create dispatch queue for frame processing
    captureQueue = dispatch_queue_create("camera.capture.queue", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:self queue:captureQueue];

    // Discard frames if processing is slow
    [output setAlwaysDiscardsLateVideoFrames:YES];

    // Add output to session
    if ([session canAddOutput:output]) {
        [session addOutput:output];
    } else {
        [output setSampleBufferDelegate:nil queue:nil];
        dispatch_release(captureQueue);
        captureQueue = nil;
        [output release];
        output = nil;
        [session release];
        session = nil;
        device = nil;
        input = nil;
        return CAMERA_ERROR_SESSION;
    }

    // Create semaphore for frame synchronization
    frameSemaphore = dispatch_semaphore_create(0);

    // Start the session
    [session startRunning];
    isOpen = true;

    return CAMERA_OK;
}

- (void)close {
    if (!isOpen) {
        return;
    }

    // Stop delivering frames, then wait for any delegate call still running
    // on the capture queue (it may be inside a Vision request) to finish
    // before anything it uses is released.
    if (session) {
        [session stopRunning];
    }
    if (output) {
        [output setSampleBufferDelegate:nil queue:nil];
    }
    if (captureQueue) {
        dispatch_sync(captureQueue, ^{});
    }

    // Wake any waiter in captureFrame so it sees the closed state
    isOpen = false;
    hasNewFrame = false;
    if (frameSemaphore) {
        dispatch_semaphore_signal(frameSemaphore);
    }

    if (session) {
        if (input && [session.inputs containsObject:input]) {
            [session removeInput:input];
        }
        if (output && [session.outputs containsObject:output]) {
            [session removeOutput:output];
        }
        [session release];
        session = nil;
    }
    // input and device are autoreleased results that the session retained;
    // dropping the session drops them
    input = nil;
    device = nil;
    if (output) {
        [output release];
        output = nil;
    }
    if (captureQueue) {
        dispatch_release(captureQueue);
        captureQueue = nil;
    }
    if (frameSemaphore) {
        dispatch_release(frameSemaphore);
        frameSemaphore = nil;
    }

    // The depth model is owned by the caller; just stop using it
    depthModel = nullptr;
    hasMask = false;
}

- (CameraError)captureFrame:(CameraImage*)outImage {
    if (!isOpen) {
        return CAMERA_ERROR_NOT_OPEN;
    }

    hasNewFrame = false;

    // Wait for a new frame (with timeout of 5 seconds)
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(frameSemaphore, timeout) != 0) {
        return CAMERA_ERROR_CAPTURE;
    }

    if (!isOpen) {
        return CAMERA_ERROR_NOT_OPEN;
    }
    if (!hasNewFrame || !imageData) {
        return CAMERA_ERROR_CAPTURE;
    }

    outImage->data = imageData;
    outImage->width = imageWidth;
    outImage->height = imageHeight;
    outImage->bytes_per_row = imageBytesPerRow;
    outImage->chroma_data = chromaData;
    outImage->chroma_width = chromaWidth;
    outImage->chroma_height = chromaHeight;
    outImage->chroma_bytes_per_row = chromaBytesPerRow;
    outImage->mask_data = hasMask ? maskData : nullptr;
    outImage->mask_width = hasMask ? maskWidth : 0;
    outImage->mask_height = hasMask ? maskHeight : 0;
    outImage->mask_bytes_per_row = hasMask ? maskBytesPerRow : 0;

    return CAMERA_OK;
}

- (bool)isSessionOpen {
    return isOpen;
}

- (void)setDepthModel:(DepthModelHandle)model {
    depthModel = model;
    if (!model) {
        hasMask = false;
    }
}

// Runs the depth model on the frame and keeps a copy of its nearness map
- (void)updateMaskFromBuffer:(CVPixelBufferRef)imageBuffer {
    DepthMap map;
    if (depth_model_estimate_pixel_buffer(depthModel, imageBuffer, &map) != DEPTH_OK) {
        hasMask = false;
        return;
    }
    size_t size = (size_t)map.bytes_per_row * map.height;
    if (!maskData || maskDataSize != size) {
        if (maskData) {
            free(maskData);
        }
        maskData = (uint8_t*)malloc(size);
        maskDataSize = size;
    }
    if (!maskData) {
        hasMask = false;
        return;
    }
    memcpy(maskData, map.data, size);
    maskWidth = map.width;
    maskHeight = map.height;
    maskBytesPerRow = map.bytes_per_row;
    hasMask = true;
}

// AVCaptureVideoDataOutputSampleBufferDelegate method
- (void)captureOutput:(AVCaptureOutput*)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        return;
    }

    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    // Plane 0: Y (luma). Plane 1: interleaved CbCr at half resolution.
    uint8_t* baseAddress = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    size_t width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0);
    size_t height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
    size_t dataSize = bytesPerRow * height;

    uint8_t* chromaBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1);
    size_t cWidth = CVPixelBufferGetWidthOfPlane(imageBuffer, 1);
    size_t cHeight = CVPixelBufferGetHeightOfPlane(imageBuffer, 1);
    size_t cBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);
    size_t cDataSize = cBytesPerRow * cHeight;

    // Allocate or reallocate buffers if the layout changed
    if (!imageData || imageDataSize != dataSize) {
        if (imageData) {
            free(imageData);
        }
        imageData = (uint8_t*)malloc(dataSize);
        imageDataSize = dataSize;
    }
    imageWidth = (uint32_t)width;
    imageHeight = (uint32_t)height;
    imageBytesPerRow = (uint32_t)bytesPerRow;

    if (chromaBase && (!chromaData || chromaDataSize != cDataSize)) {
        if (chromaData) {
            free(chromaData);
        }
        chromaData = (uint8_t*)malloc(cDataSize);
        chromaDataSize = cDataSize;
    }
    if (chromaBase && chromaData) {
        chromaWidth = (uint32_t)cWidth;
        chromaHeight = (uint32_t)cHeight;
        chromaBytesPerRow = (uint32_t)cBytesPerRow;
        memcpy(chromaData, chromaBase, cDataSize);
    } else {
        chromaWidth = 0;
        chromaHeight = 0;
        chromaBytesPerRow = 0;
    }

    if (imageData) {
        memcpy(imageData, baseAddress, dataSize);
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    if (depthModel) {
        [self updateMaskFromBuffer:imageBuffer];
    }

    if (imageData) {
        hasNewFrame = true;
        dispatch_semaphore_signal(frameSemaphore);
    }
}

@end

// C API implementation

CameraHandle camera_create(void) {
    @autoreleasepool {
        CameraCapture* camera = [[CameraCapture alloc] init];
        return (__bridge_retained void*)camera;
    }
}

void camera_destroy(CameraHandle handle) {
    if (!handle) {
        return;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge_transfer CameraCapture*)handle;
        camera = nil;
    }
}

CameraError camera_open(CameraHandle handle) {
    if (!handle) {
        return CAMERA_ERROR_INIT;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        return [camera open];
    }
}

void camera_close(CameraHandle handle) {
    if (!handle) {
        return;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        [camera close];
    }
}

CameraError camera_capture_frame(CameraHandle handle, CameraImage* out_image) {
    if (!handle || !out_image) {
        return CAMERA_ERROR_INIT;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        return [camera captureFrame:out_image];
    }
}

void camera_set_depth_model(CameraHandle handle, DepthModelHandle model) {
    if (!handle) {
        return;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        [camera setDepthModel:model];
    }
}

bool camera_is_open(CameraHandle handle) {
    if (!handle) {
        return false;
    }
    @autoreleasepool {
        CameraCapture* camera = (__bridge CameraCapture*)handle;
        return [camera isSessionOpen];
    }
}
