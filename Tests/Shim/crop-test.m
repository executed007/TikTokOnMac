// Loads RunnerShim.dylib and checks the portrait crop and the delegate stand-in. Run by build.sh.
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static int failures;
static void check(BOOL ok, const char *name) { printf("%s %s\n", ok ? "ok  " : "FAIL", name); if (!ok) failures++; }

// A frame whose every pixel encodes its own column, so a crop can be checked exactly.
static CMSampleBufferRef makeFrame(OSType format, size_t width, size_t height) {
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(NULL, width, height, format, (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &buffer);
    CVPixelBufferLockBaseAddress(buffer, 0);
    if (format == kCVPixelFormatType_32BGRA) {
        uint8_t *base = CVPixelBufferGetBaseAddress(buffer); size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
            uint8_t *p = base + y * stride + x * 4; p[0] = x & 0xff; p[1] = x >> 8; p[2] = y & 0xff; p[3] = 0xff;
        }
    } else {
        uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0); size_t ls = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1); size_t cs = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) luma[y * ls + x] = (x + y) & 0xff;
        for (size_t y = 0; y < height / 2; y++) for (size_t x = 0; x < width / 2; x++) { chroma[y * cs + x * 2] = x & 0xff; chroma[y * cs + x * 2 + 1] = y & 0xff; }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CMVideoFormatDescriptionRef description = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, buffer, &description);
    CMSampleTimingInfo timing = { CMTimeMake(1, 30), CMTimeMake(42, 30), kCMTimeInvalid };
    CMSampleBufferRef sample = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(NULL, buffer, description, &timing, &sample);
    CFRelease(description); CVPixelBufferRelease(buffer);
    return sample;
}

@interface Receiver : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property size_t width, height;
@end
@implementation Receiver
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    CVPixelBufferRef b = CMSampleBufferGetImageBuffer(s); self.width = CVPixelBufferGetWidth(b); self.height = CVPixelBufferGetHeight(b);
}
@end

int main(int argc, char **argv) {
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!shim) { printf("FAIL dlopen: %s\n", dlerror()); return 1; }
    CMSampleBufferRef (*crop)(CMSampleBufferRef) = dlsym(shim, "RSCreatePortraitCrop");
    check(crop != NULL, "crop function exported");

    for (NSNumber *format in @[@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_32BGRA)]) {
        OSType type = format.unsignedIntValue; BOOL bgra = type == kCVPixelFormatType_32BGRA;
        CMSampleBufferRef frame = makeFrame(type, 1920, 1080), out = crop(frame);
        CVPixelBufferRef b = out ? CMSampleBufferGetImageBuffer(out) : NULL;
        check(b && CVPixelBufferGetWidth(b) == 606 && CVPixelBufferGetHeight(b) == 1080, bgra ? "BGRA 1920x1080 -> 606x1080" : "420f 1920x1080 -> 606x1080");
        size_t left = 656; BOOL exact = b != NULL;
        if (b) {
            CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
            if (bgra) {
                uint8_t *base = CVPixelBufferGetBaseAddress(b); size_t stride = CVPixelBufferGetBytesPerRow(b);
                for (size_t y = 0; y < 1080 && exact; y += 97) for (size_t x = 0; x < 606; x += 5) {
                    uint8_t *p = base + y * stride + x * 4; size_t sx = x + left;
                    if (p[0] != (sx & 0xff) || p[1] != (sx >> 8) || p[2] != (y & 0xff)) { exact = NO; break; }
                }
            } else {
                uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(b, 0); size_t ls = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
                uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(b, 1); size_t cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1);
                for (size_t y = 0; y < 1080 && exact; y += 97) for (size_t x = 0; x < 606; x += 5) if (luma[y * ls + x] != ((x + left + y) & 0xff)) { exact = NO; break; }
                for (size_t y = 0; y < 540 && exact; y += 53) for (size_t x = 0; x < 303; x += 3)
                    if (chroma[y * cs + x * 2] != ((x + left / 2) & 0xff) || chroma[y * cs + x * 2 + 1] != (y & 0xff)) { exact = NO; break; }
            }
            CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
        }
        check(exact, bgra ? "BGRA pixels are the centre strip" : "420f luma and chroma are the centre strip");
        check(out && CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(out), CMTimeMake(42, 30)) == 0, "timestamp kept");
        if (out) CFRelease(out);
        CFRelease(frame);
    }
    CMSampleBufferRef portrait = makeFrame(kCVPixelFormatType_32BGRA, 720, 1280);
    check(crop(portrait) == NULL, "portrait frame left alone");
    CFRelease(portrait);

    AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
    Receiver *receiver = [Receiver new];
    dispatch_queue_t queue = dispatch_queue_create("test", NULL);
    [output setSampleBufferDelegate:receiver queue:queue];
    check(output.sampleBufferDelegate == receiver, "app still sees its own delegate");
    // The stand-in the helper installs between the camera and the app's delegate.
    id standIn = [NSClassFromString(@"RSCropDelegate") alloc];
    ((void (*)(id, SEL, id))objc_msgSend)(standIn, NSSelectorFromString(@"setTarget:"), receiver);
    CMSampleBufferRef frame = makeFrame(kCVPixelFormatType_32BGRA, 1280, 720);
    [standIn captureOutput:output didOutputSampleBuffer:frame fromConnection:(AVCaptureConnection *)NSNull.null];
    check(receiver.width == 404 && receiver.height == 720, "delegate receives the cropped 404x720 frame");
    CFRelease(frame);
    printf(failures ? "%d test(s) failed\n" : "All shim tests passed\n", failures);
    return failures ? 1 : 0;
}
