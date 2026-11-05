#import "ContextTrace.h"
#import <objc/runtime.h>

static KPTraceSink traceSink;
static NSInteger depth;
static void (*originalActivate)(id, SEL);
static void (*originalDeactivate)(id, SEL);
static BOOL (*originalHandle)(id, SEL, NSEvent *);
static void (*originalKeyDown)(id, SEL, NSEvent *);

static void emit(const char *name, id object, id client, NSEvent *event, NSInteger result) {
    traceSink(name, (uintptr_t)(__bridge void *)object,
              (uintptr_t)(__bridge void *)client, event, result, depth);
}

static void activate(NSTextInputContext *context, SEL selector) {
    ++depth;
    emit("contextActivateBegin", context, context.client, nil, -1);
    originalActivate(context, selector);
    emit("contextActivateEnd", context, context.client, nil, -1);
    --depth;
}

static void deactivate(NSTextInputContext *context, SEL selector) {
    ++depth;
    emit("contextDeactivateBegin", context, context.client, nil, -1);
    originalDeactivate(context, selector);
    emit("contextDeactivateEnd", context, context.client, nil, -1);
    --depth;
}

static BOOL handle(NSTextInputContext *context, SEL selector, NSEvent *event) {
    ++depth;
    emit("contextHandleBegin", context, context.client, event, -1);
    BOOL result = originalHandle(context, selector, event);
    emit("contextHandleEnd", context, context.client, event, result);
    --depth;
    return result;
}

static void keyDown(NSTextView *view, SEL selector, NSEvent *event) {
    ++depth;
    emit("textViewKeyDownBegin", view, view, event, -1);
    originalKeyDown(view, selector, event);
    emit("textViewKeyDownEnd", view, view, event, -1);
    --depth;
}

void KPInstallContextTrace(KPTraceSink sink) {
    traceSink = sink;
    originalActivate = (void *)method_setImplementation(
        class_getInstanceMethod(NSTextInputContext.class, @selector(activate)), (IMP)activate);
    originalDeactivate = (void *)method_setImplementation(
        class_getInstanceMethod(NSTextInputContext.class, @selector(deactivate)), (IMP)deactivate);
    originalHandle = (void *)method_setImplementation(
        class_getInstanceMethod(NSTextInputContext.class, @selector(handleEvent:)), (IMP)handle);
    originalKeyDown = (void *)method_setImplementation(
        class_getInstanceMethod(NSTextView.class, @selector(keyDown:)), (IMP)keyDown);
}
