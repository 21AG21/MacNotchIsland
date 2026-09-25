// MediaRemoteAdapter — a tiny helper that runs inside an Apple-signed host process
// (/usr/bin/perl) so MediaRemote keeps answering on macOS 15.4 and later, where the
// framework stops delivering Now Playing data to third-party apps.
//
// Protocol: one JSON object per line on stdout for every Now Playing change (plus a
// periodic refresh); single-word commands on stdin ("play", "pause", "toggle", "next",
// "previous", "seek <seconds>", "refresh"). The process exits when stdin closes.
//
// Added later, and ignored by nothing: an older app sends none of them, and a command this
// helper does not know is dropped without a word, so either side can be newer.
//   "shuffle"          advance the shuffle mode (MRMediaRemoteCommand 6)
//   "shuffle <mode>"   set it: 1 off, 3 songs (MRMediaRemoteSetShuffleMode, else command 6)
//   "repeat"           advance the repeat mode (command 7)
//   "repeat <mode>"    set it: 1 off, 2 one, 3 all (MRMediaRemoteSetRepeatMode, else command 7)
//   "like"             like / favourite the track (command 21)
// Seeking by fifteen seconds is not here: the app knows where the playhead is and sends an
// absolute "seek".
//
// The payload carries every string and number MediaRemote hands over, under its own keys —
// which is how the shuffle and repeat modes arrive, as kMRMediaRemoteNowPlayingInfoShuffleMode
// and kMRMediaRemoteNowPlayingInfoRepeatMode, wherever the player reports them. One key is the
// helper's own: "supportedCommands", the MRMediaRemoteCommand numbers the player says it
// takes, present only where MediaRemote will list them. Readers ignore keys they do not know.
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
typedef void (*MRSetModeFn)(int);
typedef void *(*MRGetLocalOriginFn)(void);
typedef void (*MRGetSupportedCommandsFn)(void *, dispatch_queue_t, void (^)(NSArray *));
typedef int (*MRCommandInfoGetCommandFn)(id);
typedef Boolean (*MRCommandInfoGetEnabledFn)(id);

static MRGetInfoFn sGetInfo;
static MRGetPIDFn sGetPID;
static MRSendCommandFn sSendCommand;
static MRSetElapsedFn sSetElapsed;
static MRSetModeFn sSetShuffle;
static MRSetModeFn sSetRepeat;
static MRGetLocalOriginFn sGetLocalOrigin;
static MRGetSupportedCommandsFn sGetSupported;
static MRCommandInfoGetCommandFn sInfoCommand;
static MRCommandInfoGetEnabledFn sInfoEnabled;
static unsigned long long sLastArtworkHash = 0;
/// The last list of supported commands MediaRemote gave, sorted; nil until it has given one.
static NSArray<NSNumber *> *sSupported = nil;
/// When the last request for that list went out, so one that never comes back does not stop
/// the next from being asked.
static CFAbsoluteTime sSupportedAskedAt = 0;

// MRMediaRemoteCommand numbers this helper sends.
enum {
    kAdvanceShuffle = 6,
    kAdvanceRepeat = 7,
    kLikeTrack = 21,
};

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

static void emit(void);

/// One entry of MediaRemote's supported-command list as a number, or nil for one that is
/// switched off or cannot be read. The entries are MRCommandInfo objects; the C accessors are
/// used where the framework still exports them and the object's own properties otherwise.
static NSNumber *commandNumber(id info) {
    if (!info) return nil;
    if (sInfoEnabled && !sInfoEnabled(info)) return nil;
    if (sInfoCommand) return @(sInfoCommand(info));
    @try {
        if ([info respondsToSelector:NSSelectorFromString(@"isEnabled")] || [info respondsToSelector:NSSelectorFromString(@"enabled")]) {
            id enabled = [info valueForKey:@"enabled"];
            if ([enabled isKindOfClass:[NSNumber class]] && ![(NSNumber *)enabled boolValue]) return nil;
        }
        if ([info respondsToSelector:NSSelectorFromString(@"command")]) {
            id command = [info valueForKey:@"command"];
            if ([command isKindOfClass:[NSNumber class]]) return (NSNumber *)command;
        }
    } @catch (NSException *exception) {
        // A shape this helper does not know: no list, rather than a helper that dies.
    }
    return nil;
}

/// Asks for the player's supported commands, at most once a second, and speaks again only when
/// the list has changed. The answer arrives on its own time, so it never holds up a payload:
/// each payload carries the last list there was.
static void refreshSupported(void) {
    if (!sGetSupported || !sGetLocalOrigin) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (sSupportedAskedAt > 0 && now - sSupportedAskedAt < 1.0) return;
    sSupportedAskedAt = now;
    void *origin = sGetLocalOrigin();
    if (!origin) return;
    sGetSupported(origin, dispatch_get_main_queue(), ^(NSArray *infos) {
        NSMutableSet<NSNumber *> *numbers = [NSMutableSet set];
        if ([infos isKindOfClass:[NSArray class]]) {
            for (id info in infos) {
                NSNumber *number = commandNumber(info);
                if (number) [numbers addObject:number];
            }
        }
        NSArray<NSNumber *> *sorted = [numbers.allObjects sortedArrayUsingSelector:@selector(compare:)];
        if (sSupported && [sSupported isEqualToArray:sorted]) return;
        sSupported = sorted;
        emit();
    });
}

static void emit(void) {
    if (!sGetInfo) return;
    refreshSupported();
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
        if (info.count > 0 && sSupported) out[@"supportedCommands"] = sSupported;
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
    else if ([cmd isEqualToString:@"shuffle"]) {
        int mode = parts.count > 1 ? [parts[1] intValue] : 0;
        if (mode >= 1 && mode <= 3 && sSetShuffle) sSetShuffle(mode);
        else if (sSendCommand) sSendCommand(kAdvanceShuffle, nil);
    }
    else if ([cmd isEqualToString:@"repeat"]) {
        int mode = parts.count > 1 ? [parts[1] intValue] : 0;
        if (mode >= 1 && mode <= 3 && sSetRepeat) sSetRepeat(mode);
        else if (sSendCommand) sSendCommand(kAdvanceRepeat, nil);
    }
    else if ([cmd isEqualToString:@"like"] && sSendCommand) sSendCommand(kLikeTrack, nil);
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
        // Each of these is optional: a macOS that has renamed or dropped one loses that one
        // button's shortcut, never the helper.
        sSetShuffle = (MRSetModeFn)dlsym(handle, "MRMediaRemoteSetShuffleMode");
        sSetRepeat = (MRSetModeFn)dlsym(handle, "MRMediaRemoteSetRepeatMode");
        sGetLocalOrigin = (MRGetLocalOriginFn)dlsym(handle, "MRMediaRemoteGetLocalOrigin");
        sGetSupported = (MRGetSupportedCommandsFn)dlsym(handle, "MRMediaRemoteGetSupportedCommandsForOrigin");
        sInfoCommand = (MRCommandInfoGetCommandFn)dlsym(handle, "MRMediaRemoteCommandInfoGetCommand");
        sInfoEnabled = (MRCommandInfoGetEnabledFn)dlsym(handle, "MRMediaRemoteCommandInfoGetEnabled");
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
