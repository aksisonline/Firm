#ifndef MultitouchShim_h
#define MultitouchShim_h

// Struct layouts and function pointer types for the private MultitouchSupport.framework.
// The framework itself is resolved at runtime with dlopen/dlsym (it lives in the dyld
// shared cache, so it cannot be linked directly). Layout taken from the widely used
// community headers (OpenMultitouchSupport / M5MultitouchSupport).

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef int MTTouchState;
enum {
    MTTouchStateNotTracking   = 0,
    MTTouchStateStartInRange  = 1,
    MTTouchStateHoverInRange  = 2,
    MTTouchStateMakeTouch     = 3,
    MTTouchStateTouching      = 4,
    MTTouchStateBreakTouch    = 5,
    MTTouchStateLingerInRange = 6,
    MTTouchStateOutOfRange    = 7
};

typedef struct {
    int          frame;
    double       timestamp;
    int          identifier;
    MTTouchState state;
    int          fingerId;
    int          handId;
    MTVector     normalizedPosition;
    float        total;      // total capacitance
    float        pressure;   // force; empirically ~grams on Force Touch trackpads
    float        angle;
    float        majorAxis;
    float        minorAxis;
    MTVector     absolutePosition;
    int          field14;
    int          field15;
    float        density;    // area density of capacitance
} MTTouch;

typedef void *MTDeviceRef;

typedef enum {
    MTRunModeVerbose     = 0,
    MTRunModeLessVerbose = 0x10000000,
} MTRunMode;

typedef void (*MTFrameCallbackWithRefcon)(MTDeviceRef device, MTTouch *touches, size_t numTouches,
                                          double timestamp, size_t frame, void *refcon);

// dlsym'd function signatures
typedef MTDeviceRef (*MTDeviceCreateDefault_f)(void);
typedef void        (*MTDeviceRelease_f)(MTDeviceRef);
typedef int32_t     (*MTDeviceStart_f)(MTDeviceRef, MTRunMode);
typedef int32_t     (*MTDeviceStop_f)(MTDeviceRef);
typedef bool        (*MTDeviceSupportsForce_f)(MTDeviceRef);
typedef bool        (*MTDeviceIsBuiltIn_f)(MTDeviceRef);
typedef bool        (*MTRegisterContactFrameCallbackWithRefcon_f)(MTDeviceRef, MTFrameCallbackWithRefcon, void *);
typedef bool        (*MTDeviceGetSystemForceResponseEnabled_f)(MTDeviceRef);
typedef void        (*MTDeviceSetSystemForceResponseEnabled_f)(MTDeviceRef, bool);

#endif /* MultitouchShim_h */
