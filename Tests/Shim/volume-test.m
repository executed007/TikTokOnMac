// Checks that RunnerShim scales the volume an app sets on its AudioQueues. build.sh runs this
// from inside a .app folder, because the helper only rebinds code that lives in an app bundle.
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <stdio.h>
#import <math.h>

static int failures;
static void check(int ok, const char *name) { printf("%s %s\n", ok ? "ok  " : "FAIL", name); if (!ok) failures++; }
static void callback(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {}

static OSStatus fullScale(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                          UInt32 bus, UInt32 frames, AudioBufferList *data) {
    for (UInt32 index = 0; index < data->mNumberBuffers; index++) {
        float *samples = data->mBuffers[index].mData;
        for (UInt32 frame = 0; frame < frames; frame++) samples[frame] = 1.0f;
    }
    return noErr;
}

static float volumeOf(AudioQueueRef queue) {
    AudioQueueParameterValue value = -1;
    AudioQueueGetParameter(queue, kAudioQueueParam_Volume, &value);
    return value;
}

int main(int argc, char **argv) {
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!shim) { printf("FAIL dlopen: %s\n", dlerror()); return 1; }
    void (*setVolume)(float) = (void (*)(float))dlsym(shim, "RSTestSetVolume");
    check(setVolume != NULL, "volume hook exported");
    if (!setVolume) return 1;

    AudioStreamBasicDescription format = { 44100, kAudioFormatLinearPCM,
        kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
    setVolume(0.5);
    AudioQueueRef queue = NULL;
    check(AudioQueueNewOutput(&format, callback, NULL, NULL, NULL, 0, &queue) == noErr, "queue created");
    check(fabsf(volumeOf(queue) - 0.5f) < 0.001f, "new queue starts at the app volume (50%)");
    AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 0.8f);
    check(fabsf(volumeOf(queue) - 0.4f) < 0.001f, "app's own 80% becomes 40%");
    setVolume(0.25);
    check(fabsf(volumeOf(queue) - 0.2f) < 0.001f, "changing the volume updates live queues");
    setVolume(0);
    check(volumeOf(queue) == 0, "mute");
    AudioQueueSetParameter(queue, kAudioQueueParam_Pan, 0.5f);   // other parameters pass through untouched
    check(fabsf(volumeOf(queue)) < 0.001f, "other parameters leave the volume alone");
    AudioQueueDispose(queue, true);
    setVolume(1);
    check(1, "dispose and later volume changes do not touch the freed queue");
    // An output AudioUnit fed by a render callback, the way video players do it.
    AudioComponentDescription description = { kAudioUnitType_Output, kAudioUnitSubType_GenericOutput, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioUnit unit = NULL;
    AudioComponentInstanceNew(AudioComponentFindNext(NULL, &description), &unit);
    AudioStreamBasicDescription floats = { 44100, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 1, 32, 0 };
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &floats, sizeof floats);
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &floats, sizeof floats);
    AURenderCallbackStruct source = { fullScale, NULL };
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &source, sizeof source);
    check(AudioUnitInitialize(unit) == noErr, "audio unit ready");
    setVolume(0.5);
    float rendered[64] = {0};
    AudioBufferList list = { 1, {{ 1, sizeof rendered, rendered }} };
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time = { .mSampleTime = 0, .mFlags = kAudioTimeStampSampleTimeValid };
    check(AudioUnitRender(unit, &flags, &time, 0, 64, &list) == noErr, "audio unit rendered");
    check(fabsf(rendered[10] - 0.5f) < 0.001f, "audio unit output scaled to 50%");
    setVolume(0);
    time.mSampleTime = 64;
    AudioUnitRender(unit, &flags, &time, 0, 64, &list);
    check(rendered[10] == 0, "audio unit muted");
    AudioUnitUninitialize(unit);
    AudioComponentInstanceDispose(unit);
    setVolume(1);

    printf(failures ? "%d test(s) failed\n" : "All volume tests passed\n", failures);
    return failures ? 1 : 0;
}
