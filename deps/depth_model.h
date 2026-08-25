#ifndef DEPTH_MODEL_H
#define DEPTH_MODEL_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a loaded monocular depth model
typedef void* DepthModelHandle;

typedef enum {
    DEPTH_OK = 0,
    DEPTH_ERROR_LOAD = -1,        // model could not be loaded
    DEPTH_ERROR_COMPILE = -2,     // package could not be compiled
    DEPTH_ERROR_INFERENCE = -3,   // running the model failed
    DEPTH_ERROR_UNSUPPORTED = -4, // model output is not a depth image
} DepthError;

// Nearness map: 0 = farthest, 255 = nearest, at the model's own resolution.
// Owned by the model; valid until the next estimate or destroy.
typedef struct {
    uint8_t* data;
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
} DepthMap;

// Load a model. model_path is an .mlpackage or an already compiled .mlmodelc.
// A package is compiled once into compiled_path (a directory path ending in
// .mlmodelc) and loaded from there on later runs.
DepthError depth_model_create(const char* model_path, const char* compiled_path, DepthModelHandle* out_handle);

// Release the model and everything it holds on the Neural Engine
void depth_model_destroy(DepthModelHandle handle);

// Estimate depth for an interleaved 8-bit RGB image
DepthError depth_model_estimate_rgb(DepthModelHandle handle, const uint8_t* rgb, uint32_t width, uint32_t height, uint32_t bytes_per_row, DepthMap* out_map);

#ifdef __OBJC__
#import <CoreVideo/CoreVideo.h>
// Estimate depth for a camera frame (any pixel format Vision accepts)
DepthError depth_model_estimate_pixel_buffer(DepthModelHandle handle, CVPixelBufferRef buffer, DepthMap* out_map);
#endif

#ifdef __cplusplus
}
#endif

#endif // DEPTH_MODEL_H
