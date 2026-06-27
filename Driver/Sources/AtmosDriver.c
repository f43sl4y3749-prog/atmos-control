/*
 * AtmosDriver.c — atmos-control HAL virtual audio driver
 *
 * AudioServerPlugIn implementing a stereo loopback device:
 *   - Output stream:  apps write mixed audio into the ring buffer  (WriteMix)
 *   - Input  stream:  capture clients read from the ring buffer    (ReadInput)
 *
 * Object model:
 *   Plugin  (kAudioObjectPlugInObject = 1)
 *     └─ Device  (kObjectID_Device = 2)
 *           ├─ Input  stream  (kObjectID_Stream_Input  = 3)
 *           └─ Output stream  (kObjectID_Stream_Output = 4)
 *
 * Format: 32-bit float, 48 kHz, 2 channels (stereo interleaved).
 * Ring buffer: 65536 frames × 2ch × 4 bytes = 512 KiB (power-of-2, > 10923 minimum).
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <stdint.h>

/* ─────────────────────────────────────────────────────────────────
 * Device identity & format constants
 * ───────────────────────────────────────────────────────────────── */

#define kDriver_BundleID         "com.atmos-control.driver"
#define kDevice_UID              "atmos-control:loopback:0"
#define kDevice_ModelUID         "atmos-control:model"
#define kDevice_Name             "atmos-control"
#define kDevice_Manufacturer     "atmos-control"

#define kDevice_SampleRate       48000.0
#define kDevice_ChannelsPerFrame 2u
#define kDevice_BytesPerChannel  4u                                    /* sizeof(Float32) */
#define kDevice_BytesPerFrame    (kDevice_ChannelsPerFrame * kDevice_BytesPerChannel)

/* Ring buffer must be a power-of-two and >= 10923 frames per the API contract */
#define kDevice_RingBufferFrames 65536u
#define kDevice_RingBufferSamples (kDevice_RingBufferFrames * kDevice_ChannelsPerFrame)

/* Fixed AudioObjectIDs */
#define kObjectID_PlugIn         kAudioObjectPlugInObject  /* 1 */
#define kObjectID_Device         2u
#define kObjectID_Stream_Input   3u
#define kObjectID_Stream_Output  4u

/* ─────────────────────────────────────────────────────────────────
 * Global state
 * ───────────────────────────────────────────────────────────────── */

/* Mutex protecting gIORunCount and the ZTS anchor */
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

/* Host reference set in Initialize() */
static AudioServerPlugInHostRef gHost = NULL;

/* IO ref-count: IO is live while this is > 0 */
static uint32_t gIORunCount = 0;

/* Loopback ring buffer: float32 interleaved stereo */
static Float32  gRingBuffer[kDevice_RingBufferSamples];

/* Zero-timestamp anchor (guarded by gStateMutex) */
static Float64  gAnchorSampleTime = 0.0;
static uint64_t gAnchorHostTime   = 0;

/* mach_timebase: converts host ticks ↔ nanoseconds */
static mach_timebase_info_data_t gTimebaseInfo;

/* ─────────────────────────────────────────────────────────────────
 * Forward declarations
 * ───────────────────────────────────────────────────────────────── */

static HRESULT   AtmosDriver_QueryInterface(void*, REFIID, LPVOID*);
static ULONG     AtmosDriver_AddRef(void*);
static ULONG     AtmosDriver_Release(void*);

static OSStatus  AtmosDriver_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus  AtmosDriver_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus  AtmosDriver_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus  AtmosDriver_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus  AtmosDriver_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus  AtmosDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus  AtmosDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);

static Boolean   AtmosDriver_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus  AtmosDriver_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus  AtmosDriver_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus  AtmosDriver_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus  AtmosDriver_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);

static OSStatus  AtmosDriver_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus  AtmosDriver_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus  AtmosDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus  AtmosDriver_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus  AtmosDriver_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus  AtmosDriver_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus  AtmosDriver_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

/* ─────────────────────────────────────────────────────────────────
 * VTable + driver ref (COM singleton pattern from NullAudio)
 * ───────────────────────────────────────────────────────────────── */

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,                                         /* _reserved */
    AtmosDriver_QueryInterface,
    AtmosDriver_AddRef,
    AtmosDriver_Release,
    AtmosDriver_Initialize,
    AtmosDriver_CreateDevice,
    AtmosDriver_DestroyDevice,
    AtmosDriver_AddDeviceClient,
    AtmosDriver_RemoveDeviceClient,
    AtmosDriver_PerformDeviceConfigurationChange,
    AtmosDriver_AbortDeviceConfigurationChange,
    AtmosDriver_HasProperty,
    AtmosDriver_IsPropertySettable,
    AtmosDriver_GetPropertyDataSize,
    AtmosDriver_GetPropertyData,
    AtmosDriver_SetPropertyData,
    AtmosDriver_StartIO,
    AtmosDriver_StopIO,
    AtmosDriver_GetZeroTimeStamp,
    AtmosDriver_WillDoIOOperation,
    AtmosDriver_BeginIOOperation,
    AtmosDriver_DoIOOperation,
    AtmosDriver_EndIOOperation
};

/* Pointer-to-pointer chain required by the AudioServerPlugInDriverRef typedef */
static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef        gDriverRef           = &gDriverInterfacePtr;

/* ─────────────────────────────────────────────────────────────────
 * Factory function  (name must match CFPlugInFactories in Info.plist)
 * ───────────────────────────────────────────────────────────────── */

void *AtmosDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void *AtmosDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

/* ─────────────────────────────────────────────────────────────────
 * COM plumbing
 * ───────────────────────────────────────────────────────────────── */

static HRESULT AtmosDriver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    (void)inDriver;
    if (!outInterface) return E_POINTER;

    /* REFIID is CFUUIDBytes (passed by value) on macOS */
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;

    if (CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID) ||
        CFEqual(uuid, IUnknownUUID))
    {
        AtmosDriver_AddRef(inDriver);
        *outInterface = gDriverRef;
        result = S_OK;
    } else {
        *outInterface = NULL;
    }

    CFRelease(uuid);
    return result;
}

static ULONG AtmosDriver_AddRef(void *inDriver)
{
    (void)inDriver;
    return 1; /* static singleton — no actual ref count */
}

static ULONG AtmosDriver_Release(void *inDriver)
{
    (void)inDriver;
    return 1;
}

/* ─────────────────────────────────────────────────────────────────
 * Initialize
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_Initialize(AudioServerPlugInDriverRef inDriver,
                                       AudioServerPlugInHostRef   inHost)
{
    (void)inDriver;
    gHost = inHost;
    mach_timebase_info(&gTimebaseInfo);
    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    return kAudioHardwareNoError;
}

/* ─────────────────────────────────────────────────────────────────
 * CreateDevice / DestroyDevice — static device; reject dynamic requests
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_CreateDevice(AudioServerPlugInDriverRef         inDriver,
                                         CFDictionaryRef                    inDescription,
                                         const AudioServerPlugInClientInfo *inClientInfo,
                                         AudioObjectID                     *outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AtmosDriver_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID              inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

/* ─────────────────────────────────────────────────────────────────
 * Client tracking — nothing to record for a static loopback
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_AddDeviceClient(AudioServerPlugInDriverRef         inDriver,
                                            AudioObjectID                      inDeviceObjectID,
                                            const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus AtmosDriver_RemoveDeviceClient(AudioServerPlugInDriverRef         inDriver,
                                               AudioObjectID                      inDeviceObjectID,
                                               const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

/* ─────────────────────────────────────────────────────────────────
 * Config change — never requested by a static device
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                             AudioObjectID              inDeviceObjectID,
                                                             UInt64                     inChangeAction,
                                                             void                      *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AtmosDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                           AudioObjectID              inDeviceObjectID,
                                                           UInt64                     inChangeAction,
                                                           void                      *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareUnsupportedOperationError;
}

/* ─────────────────────────────────────────────────────────────────
 * Helpers
 * ───────────────────────────────────────────────────────────────── */

static void FillStreamFormat(AudioStreamBasicDescription *f)
{
    f->mSampleRate       = kDevice_SampleRate;
    f->mFormatID         = kAudioFormatLinearPCM;
    f->mFormatFlags      = kAudioFormatFlagIsFloat |
                           kAudioFormatFlagsNativeEndian |
                           kAudioFormatFlagIsPacked;
    f->mBitsPerChannel   = 32;
    f->mChannelsPerFrame = kDevice_ChannelsPerFrame;
    f->mBytesPerFrame    = kDevice_BytesPerFrame;
    f->mFramesPerPacket  = 1;
    f->mBytesPerPacket   = kDevice_BytesPerFrame;
    f->mReserved         = 0;
}

static Boolean IsStreamObject(AudioObjectID oid)
{
    return oid == kObjectID_Stream_Input || oid == kObjectID_Stream_Output;
}

/* ─────────────────────────────────────────────────────────────────
 * HasProperty
 * ───────────────────────────────────────────────────────────────── */

static Boolean AtmosDriver_HasProperty(AudioServerPlugInDriverRef        inDriver,
                                       AudioObjectID                     inObjectID,
                                       pid_t                             inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver; (void)inClientProcessID;

    if (inAddress == NULL) return false;

    AudioObjectPropertySelector sel = inAddress->mSelector;

    switch (inObjectID) {

    /* ---- Plugin ---- */
    case kObjectID_PlugIn:
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyTranslateUIDToBox:
                return true;
            default:
                return false;
        }

    /* ---- Device ---- */
    case kObjectID_Device:
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyPreferredChannelLayout:
            case kAudioDevicePropertyZeroTimeStampPeriod:
                return true;
            default:
                return false;
        }

    /* ---- Streams ---- */
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
            default:
                return false;
        }

    default:
        return false;
    }
}

/* ─────────────────────────────────────────────────────────────────
 * IsPropertySettable — everything is read-only for this static device
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_IsPropertySettable(AudioServerPlugInDriverRef        inDriver,
                                               AudioObjectID                     inObjectID,
                                               pid_t                             inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               Boolean                          *outIsSettable)
{
    if (outIsSettable == NULL)
        return kAudioHardwareIllegalOperationError;

    if (!AtmosDriver_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress))
        return kAudioHardwareUnknownPropertyError;

    /* The device is fixed-format, but clients (and AUHAL) routinely "set" the
     * current sample rate / format / active flag while opening the device.
     * Report those selectors as settable so SetPropertyData gets a chance to
     * accept the matching (no-op) value; everything else stays read-only. */
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            *outIsSettable = (inObjectID == kObjectID_Device);
            break;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = IsStreamObject(inObjectID);
            break;
        default:
            *outIsSettable = false;
            break;
    }
    return kAudioHardwareNoError;
}

/* ─────────────────────────────────────────────────────────────────
 * GetPropertyDataSize
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_GetPropertyDataSize(AudioServerPlugInDriverRef        inDriver,
                                                AudioObjectID                     inObjectID,
                                                pid_t                             inClientProcessID,
                                                const AudioObjectPropertyAddress *inAddress,
                                                UInt32                            inQualifierDataSize,
                                                const void                       *inQualifierData,
                                                UInt32                           *outDataSize)
{
    (void)inQualifierDataSize; (void)inQualifierData;

    if (inAddress == NULL || outDataSize == NULL)
        return kAudioHardwareIllegalOperationError;

    if (!AtmosDriver_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress))
        return kAudioHardwareUnknownPropertyError;

    AudioObjectPropertySelector sel   = inAddress->mSelector;
    AudioObjectPropertyScope    scope = inAddress->mScope;

    switch (inObjectID) {

    /* ---------------------------------------------------------------- Plugin */
    case kObjectID_PlugIn:
        switch (sel) {
            case kAudioObjectPropertyBaseClass:           *outDataSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass:               *outDataSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner:               *outDataSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyManufacturer:        *outDataSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:        *outDataSize = 1 * sizeof(AudioObjectID); return 0;
            case kAudioPlugInPropertyBundleID:            *outDataSize = sizeof(CFStringRef); return 0;
            case kAudioPlugInPropertyDeviceList:          *outDataSize = 1 * sizeof(AudioObjectID); return 0;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return 0;
            case kAudioPlugInPropertyBoxList:             *outDataSize = 0; return 0;
            case kAudioPlugInPropertyTranslateUIDToBox:   *outDataSize = sizeof(AudioObjectID); return 0;
            default: return kAudioHardwareUnknownPropertyError;
        }

    /* ---------------------------------------------------------------- Device */
    case kObjectID_Device:
        switch (sel) {
            case kAudioObjectPropertyBaseClass:           *outDataSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass:               *outDataSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner:               *outDataSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyName:                *outDataSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyManufacturer:        *outDataSize = sizeof(CFStringRef); return 0;
            case kAudioObjectPropertyOwnedObjects:        *outDataSize = 2 * sizeof(AudioObjectID); return 0;
            case kAudioDevicePropertyDeviceUID:           *outDataSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyModelUID:            *outDataSize = sizeof(CFStringRef); return 0;
            case kAudioDevicePropertyTransportType:       *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyRelatedDevices:      *outDataSize = 1 * sizeof(AudioObjectID); return 0;
            case kAudioDevicePropertyClockDomain:         *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceIsAlive:       *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceIsRunning:     *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:       *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyLatency:             *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyStreams:
                if (scope == kAudioObjectPropertyScopeInput ||
                    scope == kAudioObjectPropertyScopeOutput)
                    *outDataSize = 1 * sizeof(AudioObjectID);
                else
                    *outDataSize = 2 * sizeof(AudioObjectID);
                return 0;
            case kAudioObjectPropertyControlList:         *outDataSize = 0; return 0;
            case kAudioDevicePropertySafetyOffset:        *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyNominalSampleRate:   *outDataSize = sizeof(Float64); return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); return 0;
            case kAudioDevicePropertyIsHidden:            *outDataSize = sizeof(UInt32); return 0;
            case kAudioDevicePropertyPreferredChannelsForStereo: *outDataSize = 2 * sizeof(UInt32); return 0;
            case kAudioDevicePropertyPreferredChannelLayout:
                /* AudioChannelLayout with zero channel descriptions */
                *outDataSize = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions[0]);
                return 0;
            case kAudioDevicePropertyZeroTimeStampPeriod: *outDataSize = sizeof(UInt32); return 0;
            default: return kAudioHardwareUnknownPropertyError;
        }

    /* ---------------------------------------------------------------- Streams */
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        if (!IsStreamObject(inObjectID)) return kAudioHardwareBadObjectError;
        switch (sel) {
            case kAudioObjectPropertyBaseClass:                  *outDataSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyClass:                      *outDataSize = sizeof(AudioClassID); return 0;
            case kAudioObjectPropertyOwner:                      *outDataSize = sizeof(AudioObjectID); return 0;
            case kAudioObjectPropertyOwnedObjects:               *outDataSize = 0; return 0;
            case kAudioStreamPropertyIsActive:                   *outDataSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyDirection:                  *outDataSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyTerminalType:               *outDataSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyStartingChannel:            *outDataSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyLatency:                    *outDataSize = sizeof(UInt32); return 0;
            case kAudioStreamPropertyVirtualFormat:              *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
            case kAudioStreamPropertyAvailableVirtualFormats:    *outDataSize = sizeof(AudioStreamRangedDescription); return 0;
            case kAudioStreamPropertyPhysicalFormat:             *outDataSize = sizeof(AudioStreamBasicDescription); return 0;
            case kAudioStreamPropertyAvailablePhysicalFormats:   *outDataSize = sizeof(AudioStreamRangedDescription); return 0;
            default: return kAudioHardwareUnknownPropertyError;
        }

    default:
        return kAudioHardwareBadObjectError;
    }
}

/* ─────────────────────────────────────────────────────────────────
 * GetPropertyData
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_GetPropertyData(AudioServerPlugInDriverRef        inDriver,
                                            AudioObjectID                     inObjectID,
                                            pid_t                             inClientProcessID,
                                            const AudioObjectPropertyAddress *inAddress,
                                            UInt32                            inQualifierDataSize,
                                            const void                       *inQualifierData,
                                            UInt32                            inDataSize,
                                            UInt32                           *outDataSize,
                                            void                             *outData)
{
    if (inAddress == NULL || outData == NULL || outDataSize == NULL)
        return kAudioHardwareIllegalOperationError;

    if (!AtmosDriver_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress))
        return kAudioHardwareUnknownPropertyError;

    AudioObjectPropertySelector sel   = inAddress->mSelector;
    AudioObjectPropertyScope    scope = inAddress->mScope;

#define NEED(sz)  do { if (inDataSize < (sz)) return kAudioHardwareBadPropertySizeError; } while(0)
#define STRRET(s) do { NEED(sizeof(CFStringRef)); CFStringRef _s = (s); CFRetain(_s); *(CFStringRef *)outData = _s; *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError; } while(0)
#define U32RET(v) do { NEED(sizeof(UInt32));     *(UInt32 *)outData = (UInt32)(v);   *outDataSize = sizeof(UInt32);     return kAudioHardwareNoError; } while(0)
#define OIDRET(v) do { NEED(sizeof(AudioObjectID)); *(AudioObjectID *)outData = (v); *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError; } while(0)
#define CLSRET(v) do { NEED(sizeof(AudioClassID)); *(AudioClassID *)outData = (v);   *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError; } while(0)

    switch (inObjectID) {

    /* ================================================================ Plugin */
    case kObjectID_PlugIn:
        switch (sel) {
            case kAudioObjectPropertyBaseClass:       CLSRET(kAudioObjectClassID);
            case kAudioObjectPropertyClass:           CLSRET(kAudioPlugInClassID);
            case kAudioObjectPropertyOwner:           OIDRET(kAudioObjectUnknown);
            case kAudioObjectPropertyManufacturer:    STRRET(CFSTR(kDevice_Manufacturer));
            case kAudioObjectPropertyOwnedObjects:
                NEED(sizeof(AudioObjectID));
                ((AudioObjectID *)outData)[0] = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyBundleID:        STRRET(CFSTR(kDriver_BundleID));
            case kAudioPlugInPropertyDeviceList:
                NEED(sizeof(AudioObjectID));
                ((AudioObjectID *)outData)[0] = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                NEED(sizeof(AudioObjectID));
                AudioObjectID result = kAudioObjectUnknown;
                if (inQualifierDataSize >= sizeof(CFStringRef)) {
                    CFStringRef reqUID = *(CFStringRef *)inQualifierData;
                    if (reqUID && CFEqual(reqUID, CFSTR(kDevice_UID)))
                        result = kObjectID_Device;
                }
                *(AudioObjectID *)outData = result;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            }
            case kAudioPlugInPropertyBoxList:
                *outDataSize = 0;
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToBox:
                OIDRET(kAudioObjectUnknown);
            default:
                return kAudioHardwareUnknownPropertyError;
        }

    /* ================================================================ Device */
    case kObjectID_Device:
        switch (sel) {
            case kAudioObjectPropertyBaseClass:       CLSRET(kAudioObjectClassID);
            case kAudioObjectPropertyClass:           CLSRET(kAudioDeviceClassID);
            case kAudioObjectPropertyOwner:           OIDRET(kObjectID_PlugIn);
            case kAudioObjectPropertyName:            STRRET(CFSTR(kDevice_Name));
            case kAudioObjectPropertyManufacturer:    STRRET(CFSTR(kDevice_Manufacturer));
            case kAudioObjectPropertyOwnedObjects: {
                UInt32 capacity = inDataSize / sizeof(AudioObjectID);
                if (capacity == 0) return kAudioHardwareBadPropertySizeError;
                AudioObjectID *ids = (AudioObjectID *)outData;
                UInt32 n = 0;
                if (n < capacity) ids[n++] = kObjectID_Stream_Input;
                if (n < capacity) ids[n++] = kObjectID_Stream_Output;
                *outDataSize = n * sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyDeviceUID:       STRRET(CFSTR(kDevice_UID));
            case kAudioDevicePropertyModelUID:        STRRET(CFSTR(kDevice_ModelUID));
            case kAudioDevicePropertyTransportType:   U32RET(kAudioDeviceTransportTypeVirtual);
            case kAudioDevicePropertyRelatedDevices:
                NEED(sizeof(AudioObjectID));
                ((AudioObjectID *)outData)[0] = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyClockDomain:     U32RET(0);
            case kAudioDevicePropertyDeviceIsAlive:   U32RET(1);
            case kAudioDevicePropertyDeviceIsRunning: {
                NEED(sizeof(UInt32));
                pthread_mutex_lock(&gStateMutex);
                UInt32 running = (gIORunCount > 0) ? 1 : 0;
                pthread_mutex_unlock(&gStateMutex);
                *(UInt32 *)outData = running;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                /* Can be input or output default */
                U32RET(1);
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                /* System output (alerts): only offer for output scope */
                U32RET((scope == kAudioObjectPropertyScopeOutput) ? 1 : 0);
            case kAudioDevicePropertyLatency:         U32RET(0);
            case kAudioDevicePropertyStreams: {
                AudioObjectID *ids = (AudioObjectID *)outData;
                if (scope == kAudioObjectPropertyScopeInput) {
                    NEED(sizeof(AudioObjectID));
                    ids[0] = kObjectID_Stream_Input;
                    *outDataSize = sizeof(AudioObjectID);
                } else if (scope == kAudioObjectPropertyScopeOutput) {
                    NEED(sizeof(AudioObjectID));
                    ids[0] = kObjectID_Stream_Output;
                    *outDataSize = sizeof(AudioObjectID);
                } else {
                    NEED(2 * sizeof(AudioObjectID));
                    ids[0] = kObjectID_Stream_Input;
                    ids[1] = kObjectID_Stream_Output;
                    *outDataSize = 2 * sizeof(AudioObjectID);
                }
                return kAudioHardwareNoError;
            }
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                return kAudioHardwareNoError;
            case kAudioDevicePropertySafetyOffset:    U32RET(0);
            case kAudioDevicePropertyNominalSampleRate: {
                NEED(sizeof(Float64));
                *(Float64 *)outData = kDevice_SampleRate;
                *outDataSize = sizeof(Float64);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                NEED(sizeof(AudioValueRange));
                AudioValueRange *r = (AudioValueRange *)outData;
                r->mMinimum = kDevice_SampleRate;
                r->mMaximum = kDevice_SampleRate;
                *outDataSize = sizeof(AudioValueRange);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyIsHidden:        U32RET(0);
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                NEED(2 * sizeof(UInt32));
                ((UInt32 *)outData)[0] = 1;
                ((UInt32 *)outData)[1] = 2;
                *outDataSize = 2 * sizeof(UInt32);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                UInt32 sz = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions[0]);
                NEED(sz);
                AudioChannelLayout *l = (AudioChannelLayout *)outData;
                l->mChannelLayoutTag          = kAudioChannelLayoutTag_Stereo;
                l->mChannelBitmap             = 0;
                l->mNumberChannelDescriptions = 0;
                *outDataSize = sz;
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyZeroTimeStampPeriod:
                U32RET(kDevice_RingBufferFrames);
            default:
                return kAudioHardwareUnknownPropertyError;
        }

    /* ================================================================ Streams */
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output: {
        Boolean isInput = (inObjectID == kObjectID_Stream_Input);
        switch (sel) {
            case kAudioObjectPropertyBaseClass:       CLSRET(kAudioObjectClassID);
            case kAudioObjectPropertyClass:           CLSRET(kAudioStreamClassID);
            case kAudioObjectPropertyOwner:           OIDRET(kObjectID_Device);
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = 0;
                return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:        U32RET(1);
            case kAudioStreamPropertyDirection:
                /* 1 = input stream, 0 = output stream */
                U32RET(isInput ? 1 : 0);
            case kAudioStreamPropertyTerminalType:
                U32RET(isInput ? kAudioStreamTerminalTypeMicrophone
                               : kAudioStreamTerminalTypeSpeaker);
            case kAudioStreamPropertyStartingChannel: U32RET(1);
            case kAudioStreamPropertyLatency:         U32RET(0);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                NEED(sizeof(AudioStreamBasicDescription));
                FillStreamFormat((AudioStreamBasicDescription *)outData);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                NEED(sizeof(AudioStreamRangedDescription));
                AudioStreamRangedDescription *d = (AudioStreamRangedDescription *)outData;
                FillStreamFormat(&d->mFormat);
                d->mSampleRateRange.mMinimum = kDevice_SampleRate;
                d->mSampleRateRange.mMaximum = kDevice_SampleRate;
                *outDataSize = sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    default:
        return kAudioHardwareBadObjectError;
    }

#undef NEED
#undef STRRET
#undef U32RET
#undef OIDRET
#undef CLSRET
}

/* ─────────────────────────────────────────────────────────────────
 * SetPropertyData — all properties are read-only
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_SetPropertyData(AudioServerPlugInDriverRef        inDriver,
                                            AudioObjectID                     inObjectID,
                                            pid_t                             inClientProcessID,
                                            const AudioObjectPropertyAddress *inAddress,
                                            UInt32                            inQualifierDataSize,
                                            const void                       *inQualifierData,
                                            UInt32                            inDataSize,
                                            const void                       *inData)
{
    (void)inDriver; (void)inClientProcessID;
    (void)inQualifierDataSize; (void)inQualifierData;

    if (inAddress == NULL || inData == NULL)
        return kAudioHardwareIllegalOperationError;

    /* Fixed-format device (48 kHz / stereo / 32-bit float). We honor only NO-OP
     * "sets" that match the current value — which clients issue while opening the
     * device — and reject any actual change. This is the NullAudio/BlackHole-
     * compatible behavior; a fully read-only SetPropertyData makes some clients
     * (and AUHAL) fail to open the device. A matching set needs no reconfiguration,
     * so we never call the host's RequestDeviceConfigurationChange. */
    switch (inAddress->mSelector) {

        case kAudioDevicePropertyNominalSampleRate: {
            if (inObjectID != kObjectID_Device)
                return kAudioHardwareUnsupportedOperationError;
            if (inDataSize < sizeof(Float64))
                return kAudioHardwareBadPropertySizeError;
            return (*(const Float64 *)inData == kDevice_SampleRate)
                ? kAudioHardwareNoError
                : kAudioHardwareUnsupportedOperationError;
        }

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (!IsStreamObject(inObjectID))
                return kAudioHardwareUnsupportedOperationError;
            if (inDataSize < sizeof(AudioStreamBasicDescription))
                return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *req =
                (const AudioStreamBasicDescription *)inData;
            if (req->mSampleRate       == kDevice_SampleRate     &&
                req->mFormatID         == kAudioFormatLinearPCM   &&
                req->mChannelsPerFrame == kDevice_ChannelsPerFrame &&
                req->mBitsPerChannel   == 32)
                return kAudioHardwareNoError;
            return kAudioHardwareUnsupportedOperationError;
        }

        case kAudioStreamPropertyIsActive: {
            if (!IsStreamObject(inObjectID))
                return kAudioHardwareUnsupportedOperationError;
            if (inDataSize < sizeof(UInt32))
                return kAudioHardwareBadPropertySizeError;
            /* Stream is always active; accept the set as a no-op. */
            return kAudioHardwareNoError;
        }

        default:
            return kAudioHardwareUnsupportedOperationError;
    }
}

/* ─────────────────────────────────────────────────────────────────
 * StartIO / StopIO
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_StartIO(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID              inDeviceObjectID,
                                    UInt32                     inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    pthread_mutex_lock(&gStateMutex);
    if (gIORunCount == 0) {
        /* Establish clock anchor on first StartIO */
        gAnchorSampleTime = 0.0;
        gAnchorHostTime   = mach_absolute_time();
    }
    ++gIORunCount;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus AtmosDriver_StopIO(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID              inDeviceObjectID,
                                   UInt32                     inClientID)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    pthread_mutex_lock(&gStateMutex);
    if (gIORunCount > 0) --gIORunCount;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

/* ─────────────────────────────────────────────────────────────────
 * GetZeroTimeStamp
 *
 * Pattern (NullAudio-faithful):
 *   We keep a fixed anchor (sample_time=0, host_time=StartIO time).
 *   Each call computes which "period" the current mach time falls in:
 *
 *     period_ticks = (kDevice_RingBufferFrames * 1e9 / sampleRate)
 *                    * timebase.denom / timebase.numer
 *     current_period = (now - anchor_host_time) / period_ticks
 *
 *   Then returns:
 *     outSampleTime = anchor_sample_time + current_period * kDevice_RingBufferFrames
 *     outHostTime   = anchor_host_time   + current_period * period_ticks
 *     outSeed       = 1  (constant seed = stable timeline, no resync)
 *
 *   The host subtracts consecutive zero timestamps to measure the device's
 *   true sample rate and uses the host time for scheduling.  Because we
 *   derive period_ticks from the same timebase, the implied rate is always
 *   exactly 48 kHz from the host's perspective.
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID              inDeviceObjectID,
                                             UInt32                     inClientID,
                                             Float64                   *outSampleTime,
                                             UInt64                    *outHostTime,
                                             UInt64                    *outSeed)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    pthread_mutex_lock(&gStateMutex);

    uint64_t now = mach_absolute_time();

    /*
     * period_ns = kDevice_RingBufferFrames / kDevice_SampleRate * 1e9
     *           = 65536 / 48000 * 1e9 ≈ 1365333333 ns
     *
     * period_ticks = period_ns * timebase.denom / timebase.numer
     * On Apple Silicon: numer=125, denom=3 → 1 tick = 125/3 ns = ~41.667 ns
     * period_ticks = 1365333333 * 3 / 125 = 32768000
     */
    /* Guard against an uninitialised timebase (numer/denom == 0) — Initialize()
     * always runs first, but a divide-by-zero here would be a SIGFPE crash
     * inside coreaudiod.  Bail with a benign timestamp instead. */
    if (gTimebaseInfo.numer == 0 || gTimebaseInfo.denom == 0) {
        if (outSampleTime) *outSampleTime = gAnchorSampleTime;
        if (outHostTime)   *outHostTime   = gAnchorHostTime;
        if (outSeed)       *outSeed       = 1;
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareNoError;
    }

    uint64_t period_ns    = (uint64_t)((double)kDevice_RingBufferFrames * 1.0e9 /
                                        kDevice_SampleRate);
    uint64_t period_ticks = period_ns * (uint64_t)gTimebaseInfo.denom /
                            (uint64_t)gTimebaseInfo.numer;
    if (period_ticks == 0) period_ticks = 1;   /* never divide by zero below */

    uint64_t elapsed       = now - gAnchorHostTime;
    uint64_t current_period = elapsed / period_ticks;

    *outSampleTime = gAnchorSampleTime +
                     (Float64)(current_period * (uint64_t)kDevice_RingBufferFrames);
    *outHostTime   = gAnchorHostTime + current_period * period_ticks;
    *outSeed       = 1;   /* constant → host never resynchronises */

    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

/* ─────────────────────────────────────────────────────────────────
 * WillDoIOOperation
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID              inDeviceObjectID,
                                              UInt32                     inClientID,
                                              UInt32                     inOperationID,
                                              Boolean                   *outWillDo,
                                              Boolean                   *outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            *outWillDo        = true;
            *outWillDoInPlace = true;
            break;
        default:
            *outWillDo        = false;
            *outWillDoInPlace = false;
    }
    return kAudioHardwareNoError;
}

/* ─────────────────────────────────────────────────────────────────
 * BeginIOOperation / EndIOOperation — nothing to do
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_BeginIOOperation(AudioServerPlugInDriverRef        inDriver,
                                             AudioObjectID                     inDeviceObjectID,
                                             UInt32                            inClientID,
                                             UInt32                            inOperationID,
                                             UInt32                            inIOBufferFrameSize,
                                             const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus AtmosDriver_EndIOOperation(AudioServerPlugInDriverRef        inDriver,
                                           AudioObjectID                     inDeviceObjectID,
                                           UInt32                            inClientID,
                                           UInt32                            inOperationID,
                                           UInt32                            inIOBufferFrameSize,
                                           const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

/* ─────────────────────────────────────────────────────────────────
 * DoIOOperation — the loopback core
 *
 * Ring buffer layout:
 *   gRingBuffer[0 … kDevice_RingBufferSamples-1]
 *   frame F occupies samples at index: (F % kDevice_RingBufferFrames) * kDevice_ChannelsPerFrame
 *
 * WriteMix:  host has finished mixing all clients into ioMainBuffer.
 *            Copy from the mix buffer into the ring buffer at the frame
 *            position derived from mOutputTime.mSampleTime.
 *
 * ReadInput: copy from the ring buffer (at the position derived from
 *            mInputTime.mSampleTime) into ioMainBuffer for the recording client.
 *
 * Wrap-around: if the run of frames straddles the ring buffer boundary,
 * split into two memcpy calls.
 *
 * Thread safety: the HAL serialises IO operations per stream, so no
 * additional lock is needed here (same approach as NullAudio).
 * ───────────────────────────────────────────────────────────────── */

static OSStatus AtmosDriver_DoIOOperation(AudioServerPlugInDriverRef        inDriver,
                                          AudioObjectID                     inDeviceObjectID,
                                          AudioObjectID                     inStreamObjectID,
                                          UInt32                            inClientID,
                                          UInt32                            inOperationID,
                                          UInt32                            inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                          void                             *ioMainBuffer,
                                          void                             *ioSecondaryBuffer)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID;
    (void)inClientID; (void)ioSecondaryBuffer;

    if (!ioMainBuffer || inIOBufferFrameSize == 0 || inIOCycleInfo == NULL)
        return kAudioHardwareNoError;

    /* Defensive: a buffer larger than the ring would overrun the wrap-around
     * copy below.  The HAL never requests this (IO buffers are far smaller than
     * the ZTS period), but bail rather than corrupt coreaudiod's heap. */
    if (inIOBufferFrameSize > kDevice_RingBufferFrames)
        return kAudioHardwareNoError;

    /* Choose the right timestamp: output time for write, input time for read */
    const AudioTimeStamp *ts =
        (inOperationID == kAudioServerPlugInIOOperationWriteMix)
            ? &inIOCycleInfo->mOutputTime
            : &inIOCycleInfo->mInputTime;

    /* Map sample time → ring frame offset (power-of-2 modulo) */
    uint64_t sampleTime  = (uint64_t)ts->mSampleTime;
    uint32_t frameOff    = (uint32_t)(sampleTime % kDevice_RingBufferFrames);
    uint32_t sampleOff   = frameOff * kDevice_ChannelsPerFrame;

    /* How many frames fit before the ring wraps? */
    uint32_t framesBeforeWrap = kDevice_RingBufferFrames - frameOff;

    Float32 *ring = gRingBuffer;
    Float32 *buf  = (Float32 *)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        /* Mix buffer → ring buffer */
        if (inIOBufferFrameSize <= framesBeforeWrap) {
            memcpy(&ring[sampleOff], buf,
                   inIOBufferFrameSize * kDevice_BytesPerFrame);
        } else {
            uint32_t first  = framesBeforeWrap;
            uint32_t second = inIOBufferFrameSize - first;
            memcpy(&ring[sampleOff], buf,
                   first * kDevice_BytesPerFrame);
            memcpy(&ring[0], &buf[first * kDevice_ChannelsPerFrame],
                   second * kDevice_BytesPerFrame);
        }
    } else {
        /* Ring buffer → capture buffer  (kAudioServerPlugInIOOperationReadInput) */
        if (inIOBufferFrameSize <= framesBeforeWrap) {
            memcpy(buf, &ring[sampleOff],
                   inIOBufferFrameSize * kDevice_BytesPerFrame);
        } else {
            uint32_t first  = framesBeforeWrap;
            uint32_t second = inIOBufferFrameSize - first;
            memcpy(buf, &ring[sampleOff],
                   first * kDevice_BytesPerFrame);
            memcpy(&buf[first * kDevice_ChannelsPerFrame], &ring[0],
                   second * kDevice_BytesPerFrame);
        }
    }

    return kAudioHardwareNoError;
}
