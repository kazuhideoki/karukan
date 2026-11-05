#import <AppKit/AppKit.h>

typedef void (*KPTraceSink)(const char * _Nonnull event, uintptr_t object, uintptr_t client,
                            NSEvent * _Nullable keyEvent, NSInteger result, NSInteger depth);

// Instruments public methods in this disposable app only. Each implementation
// forwards to the original exactly once; it never activates or obtains a context.
void KPInstallContextTrace(KPTraceSink _Nonnull sink);
