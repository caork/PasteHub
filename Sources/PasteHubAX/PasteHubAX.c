#include "PasteHubAX.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>

bool PasteHubAXIsTrusted(bool prompt) {
    CFDictionaryRef options = NULL;
    if (prompt) {
        const void *keys[] = { kAXTrustedCheckOptionPrompt };
        const void *values[] = { kCFBooleanTrue };
        options = CFDictionaryCreate(
            kCFAllocatorDefault,
            keys,
            values,
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
    }
    bool trusted = AXIsProcessTrustedWithOptions(options);
    if (options != NULL) {
        CFRelease(options);
    }
    return trusted;
}
