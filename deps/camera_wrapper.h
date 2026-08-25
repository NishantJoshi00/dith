#ifndef CAMERA_WRAPPER_H
#define CAMERA_WRAPPER_H

#include <stdint.h>
#include <stdbool.h>
#include "depth_model.h"

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to the camera object
typedef void* CameraHandle;

// Image data structure
typedef struct {
    uint8_t* data;      // Grayscale (Y) pixel data
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
    uint8_t* chroma_data;   // Interleaved CbCr, half resolution (4:2:0)
    uint32_t chroma_width;
    uint32_t chroma_height;
    uint32_t chroma_bytes_per_row;
    uint8_t* mask_data;     // Nearness 0-255 from the depth model, own resolution; NULL when off
    uint32_t mask_width;
    uint32_t mask_height;
    uint32_t mask_bytes_per_row;
} CameraImage;

// Error codes
typedef enum {
    CAMERA_OK = 0,
    CAMERA_ERROR_INIT = -1,
    CAMERA_ERROR_NO_DEVICE = -2,
    CAMERA_ERROR_PERMISSION = -3,
    CAMERA_ERROR_SESSION = -4,
    CAMERA_ERROR_CAPTURE = -5,
    CAMERA_ERROR_NOT_OPEN = -6,
    CAMERA_ERROR_ALREADY_OPEN = -7,
} CameraError;

// Create a new camera instance
CameraHandle camera_create(void);

// Destroy a camera instance and free resources
void camera_destroy(CameraHandle handle);

// Open the camera and start the capture session
CameraError camera_open(CameraHandle handle);

// Close the camera and stop the capture session
void camera_close(CameraHandle handle);

// Capture a single frame (blocking call)
// Returns CAMERA_OK on success, error code on failure
// The image data is owned by the camera and will be valid until next capture or close
CameraError camera_capture_frame(CameraHandle handle, CameraImage* out_image);

// Check if the camera is currently open
bool camera_is_open(CameraHandle handle);

// Attach (or detach with NULL) a depth model. While attached, every captured
// frame carries a nearness mask. The camera does not own the model.
void camera_set_depth_model(CameraHandle handle, DepthModelHandle model);

#ifdef __cplusplus
}
#endif

#endif // CAMERA_WRAPPER_H
