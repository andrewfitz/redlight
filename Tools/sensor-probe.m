// Read-only probe: what can this Mac tell an app about ambient light, True Tone and
// Night Shift? It changes nothing. Run it on a MacBook (or a Mac with an Apple display),
// cover and uncover the sensor beside the camera while it samples, and keep the output:
//
//     clang -fobjc-arc -framework Foundation -framework IOKit Tools/sensor-probe.m -o /tmp/sensor-probe
//     /tmp/sensor-probe
//
// Everything here is private API (IOHID event system, CoreBrightness). Nothing in Redlight
// reads the sensor yet; this is to find out what a MacBook reports before anything does.

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t field);

// IOHIDEventTypes.h: the ambient light event and its fields (type << 16 | index).
enum { kAmbientLightEvent = 12 };
static const char *const kAmbientLightFields[] = {
    "level (lux)", "raw channel 0", "raw channel 1", "raw channel 2", "raw channel 3",
    "brightness", "color space", "color component 0", "color component 1", "color component 2",
    "color temperature (K)", "illuminance (lux)",
};

static NSString *oneLine(id value) {
    if (!value) return @"(none)";
    NSString *text = [[value description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return text.length > 400 ? [[text substringToIndex:400] stringByAppendingString:@"…"] : text;
}

static NSArray *ambientLightServices(IOHIDEventSystemClientRef client) {
    NSMutableArray *found = [NSMutableArray array];
    // Apple's vendor page, usage 4, is the built-in sensor; the HID sensor page's 0x41 is
    // the standard ambient light usage an external display may use.
    for (NSDictionary *match in @[@{@"PrimaryUsagePage": @0xFF00, @"PrimaryUsage": @4},
                                  @{@"PrimaryUsagePage": @0x20, @"PrimaryUsage": @0x41}]) {
        IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)match);
        NSArray *services = CFBridgingRelease(IOHIDEventSystemClientCopyServices(client));
        if (services) [found addObjectsFromArray:services];
    }
    return found;
}

static void printBool(id object, const char *owner, const char *name) {
    SEL selector = sel_registerName(name);
    if (![object respondsToSelector:selector]) { printf("  %s.%s: (no such method)\n", owner, name); return; }
    printf("  %s.%s: %s\n", owner, name, ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) ? "yes" : "no");
}

int main(void) { @autoreleasepool {
    NSProcessInfo *info = NSProcessInfo.processInfo;
    char model[128] = "?"; size_t size = sizeof model;
    sysctlbyname("hw.model", model, &size, NULL, 0);
    printf("Redlight sensor probe: %s, macOS %s\n\n", model, info.operatingSystemVersionString.UTF8String);

    printf("== Ambient light sensors (IOHID event system)\n");
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    NSArray *services = client ? ambientLightServices(client) : @[];
    if (services.count == 0) printf("  none: this Mac and its displays report no ambient light sensor\n");
    for (id service in services) {
        IOHIDServiceClientRef ref = (__bridge IOHIDServiceClientRef)service;
        printf("  service: %s\n", oneLine(service).UTF8String);
        for (NSString *key in @[@"Product", @"Manufacturer", @"Built-In", @"Transport", @"PrimaryUsagePage",
                                @"PrimaryUsage", @"ReportInterval", @"LocationID"]) {
            id value = CFBridgingRelease(IOHIDServiceClientCopyProperty(ref, (__bridge CFStringRef)key));
            if (value) printf("    %s = %s\n", key.UTF8String, oneLine(value).UTF8String);
        }
    }

    if (services.count > 0) {
        printf("\n== Samples, one a second for 8 s: cover the sensor, then shine a light on it\n");
        for (int second = 0; second < 8; second++) {
            for (id service in services) {
                IOHIDEventRef event = IOHIDServiceClientCopyEvent((__bridge IOHIDServiceClientRef)service, kAmbientLightEvent, 0, 0);
                if (!event) { printf("  t=%d s: no ambient light event from this service\n", second); continue; }
                if (second == 0) {
                    // The whole event as the system describes it, so nothing depends on
                    // the field names above being right for this macOS.
                    printf("  first event: %s\n", oneLine((__bridge id)event).UTF8String);
                    for (int field = 0; field < (int)(sizeof kAmbientLightFields / sizeof *kAmbientLightFields); field++) {
                        printf("    field %2d %-24s %.4f\n", field, kAmbientLightFields[field],
                               IOHIDEventGetFloatValue(event, (kAmbientLightEvent << 16) | field));
                    }
                }
                printf("  t=%d s: level %.2f  illuminance %.2f  colour temperature %.0f\n", second,
                       IOHIDEventGetFloatValue(event, (kAmbientLightEvent << 16) | 0),
                       IOHIDEventGetFloatValue(event, (kAmbientLightEvent << 16) | 11),
                       IOHIDEventGetFloatValue(event, (kAmbientLightEvent << 16) | 10));
                CFRelease(event);
            }
            [NSThread sleepForTimeInterval:1];
        }
    }

    printf("\n== CoreBrightness (True Tone, Night Shift, auto-brightness)\n");
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)) {
        printf("  CoreBrightness did not load\n");
        return 0;
    }
    Class trueTone = objc_getClass("CBTrueToneClient");
    if (trueTone) {
        id object = [[trueTone alloc] init];
        printBool(object, "True Tone", "supported");
        printBool(object, "True Tone", "available");
        printBool(object, "True Tone", "enabled");
    } else printf("  CBTrueToneClient: absent\n");

    Class nightShift = objc_getClass("CBBlueLightClient");
    Method status = nightShift ? class_getInstanceMethod(nightShift, sel_registerName("getBlueLightStatus:")) : NULL;
    if (status) {
        const char *encoding = method_getTypeEncoding(status);
        printf("  Night Shift status signature: %s\n", encoding);
        // Redlight's "Keep Night Shift off" needs exactly this signature.
        if (strcmp(encoding, "B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16") == 0) {
            unsigned char buffer[64] = {0};
            id object = [[nightShift alloc] init];
            BOOL ok = ((BOOL (*)(id, SEL, void *))objc_msgSend)(object, sel_registerName("getBlueLightStatus:"), buffer);
            printf("  Night Shift: read %s, on now %s, schedule mode %d (0 off, 1 sunset to sunrise, 2 custom)\n",
                   ok ? "ok" : "failed", buffer[1] ? "yes" : "no", *(int *)(buffer + 4));
        } else printf("  Night Shift: signature differs, so Redlight hides its switch here\n");
    } else printf("  CBBlueLightClient: absent\n");

    Class brightness = objc_getClass("BrightnessSystemClient");
    if (brightness) {
        id object = [[brightness alloc] init];
        printBool(object, "BrightnessSystemClient", "isAlsSupported");
        SEL copy = sel_registerName("copyPropertyForKey:");
        if ([object respondsToSelector:copy]) {
            // Guesses at key names, printed only to show which of them this macOS answers.
            for (NSString *key in @[@"TrustedLux", @"AggregatedLux", @"Lux", @"ALSColor", @"CBAmbientLux",
                                    @"DisplayBrightnessAuto", @"ColorAdaptationEnabled", @"ColorAdaptationAvailable",
                                    @"DisplayBrightness", @"BlueLightStatus", @"CBBlueLightReductionCCTTarget"]) {
                id value = ((id (*)(id, SEL, id))objc_msgSend)(object, copy, key);
                printf("  BrightnessSystemClient[%s] = %s\n", key.UTF8String, oneLine(value).UTF8String);
            }
        }
    } else printf("  BrightnessSystemClient: absent\n");

    printf("\nAlso useful, from Terminal:  ioreg -l -w0 | grep -iE 'lux|ambient|\"als'\n");
}
    return 0;
}
