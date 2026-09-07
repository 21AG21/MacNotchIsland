// MediaRemoteAdapter — a tiny helper that runs inside an Apple-signed host process
// (/usr/bin/perl) so MediaRemote keeps answering on macOS 15.4 and later, where the
// framework stops delivering Now Playing data to third-party apps.
//
// Protocol: one JSON object per line on stdout for every Now Playing change (plus a
// periodic refresh); single-word commands on stdin ("play", "pause", "toggle", "next",
// "previous", "seek <seconds>", "refresh"). The process exits when stdin closes.
//
// Built by Scripts/build.sh into Contents/Resources/MediaRemoteAdapter.dylib and loaded
// through perl's DynaLoader (see AdapterBackend.swift).

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn sGetInfo;
static MRGetPIDFn sGetPID;
static MRSendCommandFn sSendCommand;
static MRSetElapsedFn sSetElapsed;
static unsigned long long sLastArtworkHash = 0;

static unsigned long long fnv1a(NSData *data) {
    unsigned long long h = 1469598103934665603ULL;
    const unsigned char *p = data.bytes;
    NSUInteger n = data.length;
    for (NSUInteger i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h ^ n;
}

static void writeLine(NSDictionary *dict) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emit(void) {
    if (!sGetInfo) return;
    sGetInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *key in info) {
            id value = info[key];
            if ([value isKindOfClass:[NSData class]]) {
                if ([key isEqualToString:@"kMRMediaRemoteNowPlayingInfoArtworkData"]) {
                    unsigned long long h = fnv1a((NSData *)value);
                    out[@"artworkHash"] = [NSString stringWithFormat:@"%llx", h];
                    if (h != sLastArtworkHash) {
                        sLastArtworkHash = h;
                        out[@"artworkBase64"] = [(NSData *)value base64EncodedStringWithOptions:0];
                    }
                }
            } else if ([value isKindOfClass:[NSDate class]]) {
                out[key] = @([(NSDate *)value timeIntervalSince1970]);
            } else if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
                out[key] = value;
            }
        }
        if (info.count == 0) sLastArtworkHash = 0;
        if (sGetPID) {
            sGetPID(dispatch_get_main_queue(), ^(int pid) {
                out[@"pid"] = @(pid);
                writeLine(out);
            });
        } else {
            writeLine(out);
        }
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject ?: @"";
    if ([cmd isEqualToString:@"play"] && sSendCommand) sSendCommand(0, nil);
    else if ([cmd isEqualToString:@"pause"] && sSendCommand) sSendCommand(1, nil);
    else if ([cmd isEqualToString:@"toggle"] && sSendCommand) sSendCommand(2, nil);
    else if ([cmd isEqualToString:@"next"] && sSendCommand) sSendCommand(4, nil);
    else if ([cmd isEqualToString:@"previous"] && sSendCommand) sSendCommand(5, nil);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && sSetElapsed) sSetElapsed([parts[1] doubleValue]);
    else if ([cmd isEqualToString:@"refresh"]) emit();
    else if ([cmd isEqualToString:@"quit"]) exit(0);
    if (![cmd isEqualToString:@"refresh"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ emit(); });
    }
}

__attribute__((visibility("default")))
void MRAdapterMain(void) {
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!handle) {
            fprintf(stderr, "MediaRemoteAdapter: cannot load MediaRemote\n");
            exit(2);
        }
        MRRegisterFn registerFn = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        sGetInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        sGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        sSendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        sSetElapsed = (MRSetElapsedFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
        if (!registerFn || !sGetInfo) {
            fprintf(stderr, "MediaRemoteAdapter: missing symbols\n");
            exit(3);
        }

        registerFn(dispatch_get_main_queue());
        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) { emit(); }];
        }

        // Commands from the host app. EOF means the host is gone: exit so no perl lingers.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char buffer[512];
            while (fgets(buffer, sizeof buffer, stdin)) {
                NSString *raw = [NSString stringWithUTF8String:buffer] ?: @"";
                NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length == 0) continue;
                dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
            }
            exit(0);
        });

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(timer, ^{ emit(); });
        dispatch_resume(timer);

        emit();
        CFRunLoopRun();
    }
}
