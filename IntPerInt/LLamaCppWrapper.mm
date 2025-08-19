#import "LLamaCppWrapper.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <sys/types.h>
#import <sys/wait.h>
// #import "llama.h" // Uncomment when llama.cpp is properly linked

@implementation LLamaCppWrapper {
    // void *_model; // llama_model * when properly linked
    // void *_context; // llama_context * when properly linked
    NSString *_modelPath; // persisted for CLI invocation until lib API is wired
}

static NSString *EnsureManagedRuntimeAndInstall(NSString *execSrcPath) {
    if (execSrcPath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSURL *> *appSup = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    if (appSup.count == 0) return nil;
    NSURL *base = [[appSup.firstObject URLByAppendingPathComponent:@"IntPerInt/runtime" isDirectory:YES] URLByStandardizingPath];
    NSURL *bin = [base URLByAppendingPathComponent:@"bin" isDirectory:YES];
    NSURL *share = [[base URLByAppendingPathComponent:@"share/llama.cpp" isDirectory:YES] URLByStandardizingPath];
    NSURL *libdir = [[base URLByAppendingPathComponent:@"lib" isDirectory:YES] URLByStandardizingPath];
    NSError *err = nil;
    [fm createDirectoryAtURL:bin withIntermediateDirectories:YES attributes:nil error:&err];
    [fm createDirectoryAtURL:share withIntermediateDirectories:YES attributes:nil error:&err];
    [fm createDirectoryAtURL:libdir withIntermediateDirectories:YES attributes:nil error:&err];
    NSString *basename = [execSrcPath lastPathComponent];
    if (![basename isEqualToString:@"llama"] && ![basename isEqualToString:@"llama-cli"]) {
        basename = @"llama"; // normalize
    }
    NSURL *dst = [bin URLByAppendingPathComponent:basename];
    // Copy exec
    @try {
        if ([fm fileExistsAtPath:dst.path]) { [fm removeItemAtURL:dst error:nil]; }
        [fm copyItemAtPath:execSrcPath toPath:dst.path error:&err];
        if (err) return nil;
        // ensure executable perms
        NSDictionary *attrs = @{ NSFilePosixPermissions: @(0755) };
        [fm setAttributes:attrs ofItemAtPath:dst.path error:nil];
    } @catch(NSException *e) { return nil; }

    // Try copy metallib
    NSArray<NSString *> *metals = @[
        [[[execSrcPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"default.metallib"] stringByStandardizingPath],
        [[[[execSrcPath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"share/llama.cpp/default.metallib"] stringByStandardizingPath],
        @"/opt/homebrew/opt/llama.cpp/share/llama.cpp/default.metallib",
        @"/usr/local/opt/llama.cpp/share/llama.cpp/default.metallib"
    ];
    for (NSString *m in metals) {
        if ([fm fileExistsAtPath:m]) {
            NSURL *target = [share URLByAppendingPathComponent:@"default.metallib"];
            @try {
                if ([fm fileExistsAtPath:target.path]) { [fm removeItemAtURL:target error:nil]; }
                [fm copyItemAtPath:m toPath:target.path error:nil];
            } @catch(NSException *e) {}
            break;
        }
    }

    // Copy dependent dylibs into managed runtime: libllama.dylib and libggml*.dylib
    NSMutableArray<NSString *> *libDirs = [NSMutableArray array];
    NSString *execDir = [execSrcPath stringByDeletingLastPathComponent];
    NSString *prefix = [execDir stringByDeletingLastPathComponent];
    if (prefix.length) { [libDirs addObject:[prefix stringByAppendingPathComponent:@"lib"]]; }
    [libDirs addObject:@"/opt/homebrew/opt/llama.cpp/lib"];
    [libDirs addObject:@"/usr/local/opt/llama.cpp/lib"];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^libggml.*\\.dylib$" options:0 error:nil];
    for (NSString *d in libDirs) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:d isDirectory:&isDir] || !isDir) continue;
        NSError *dirErr = nil;
        NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:d error:&dirErr];
        for (NSString *name in contents) {
            if ([name isEqualToString:@"libllama.dylib"]) {
                NSString *src = [d stringByAppendingPathComponent:name];
                NSURL *dstlib = [libdir URLByAppendingPathComponent:name];
                @try {
                    if ([fm fileExistsAtPath:dstlib.path]) { [fm removeItemAtURL:dstlib error:nil]; }
                    [fm copyItemAtPath:src toPath:dstlib.path error:nil];
                    [fm setAttributes:@{ NSFilePosixPermissions: @(0755) } ofItemAtPath:dstlib.path error:nil];
                } @catch(NSException *e) {}
                continue;
            }
            NSTextCheckingResult *m = [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
            if (m) {
                NSString *src = [d stringByAppendingPathComponent:name];
                NSURL *dstlib = [libdir URLByAppendingPathComponent:name];
                @try {
                    if ([fm fileExistsAtPath:dstlib.path]) { [fm removeItemAtURL:dstlib error:nil]; }
                    [fm copyItemAtPath:src toPath:dstlib.path error:nil];
                    [fm setAttributes:@{ NSFilePosixPermissions: @(0755) } ofItemAtPath:dstlib.path error:nil];
                } @catch(NSException *e) {}
            }
        }
    }
    return dst.path;
}

- (void)loadModel:(NSString *)modelPath completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // TODO: Implement actual llama.cpp model loading
    // For now, just validate path and persist for CLI usage, then return success to test the UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Simulate loading time
        sleep(1);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // TODO: Replace with actual llama.cpp implementation
            /*
            struct llama_model_params model_params = llama_model_default_params();
            struct llama_context_params ctx_params = llama_context_default_params();
            
            const char *model_path_c = [modelPath UTF8String];
            _model = llama_load_model_from_file(model_path_c, model_params);
            
            if (_model == NULL) {
                NSError *error = [NSError errorWithDomain:@"LLamaCpp" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to load model"}];
                completion(NO, error);
                return;
            }
            
            _context = llama_new_context_with_model(_model, ctx_params);
            if (_context == NULL) {
                llama_free_model(_model);
                _model = NULL;
                NSError *error = [NSError errorWithDomain:@"LLamaCpp" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create context"}];
                completion(NO, error);
                return;
            }
            */

            // Validate model file exists
            if (modelPath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
                NSError *error = [NSError errorWithDomain:@"LLamaCpp" code:404 userInfo:@{NSLocalizedDescriptionKey: @"Model file not found"}];
                completion(NO, error);
                return;
            }
            _modelPath = [modelPath copy];
            completion(YES, nil);
        });
    });
}

- (void)generateText:(NSString *)prompt
        temperature:(double)temperature
          maxTokens:(NSInteger)maxTokens
               seed:(NSNumber * _Nullable)seed
               stop:(NSArray<NSString *> * _Nullable)stop
          completion:(void (^)(NSString * _Nullable response, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            // Resolve llama-cli from preferred bundled runtime, then managed, then system locations
            NSMutableArray<NSString *> *candidates = [NSMutableArray array];
            NSURL *resURL = [NSBundle mainBundle].resourceURL;
            // 0) Bundled runtime inside app Resources and Contents/MacOS (prefer)
            if (resURL) {
                NSMutableArray<NSString *> *bundled = [NSMutableArray array];
                [bundled addObject:[[resURL URLByAppendingPathComponent:@"runtime/bin/llama-cli"] path]];
                [bundled addObject:[[resURL URLByAppendingPathComponent:@"runtime/bin/llama"] path]];
                [bundled addObject:[[resURL URLByAppendingPathComponent:@"BundledRuntime/runtime/bin/llama-cli"] path]];
                [bundled addObject:[[resURL URLByAppendingPathComponent:@"BundledRuntime/runtime/bin/llama"] path]];
                NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
                [bundled addObject:[bundlePath stringByAppendingPathComponent:@"Contents/MacOS/llama-cli"]];
                [bundled addObject:[bundlePath stringByAppendingPathComponent:@"Contents/MacOS/llama"]];
                [candidates addObjectsFromArray:bundled];
            }
            // 1) Managed runtime under Application Support
            NSArray<NSURL *> *appSup = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
            if (appSup.count > 0) {
                NSURL *rt = [[appSup.firstObject URLByAppendingPathComponent:@"IntPerInt/runtime/bin" isDirectory:YES] URLByStandardizingPath];
                NSArray<NSString *> *managed = @[
                    [[rt URLByAppendingPathComponent:@"llama-cli"] path],
                    [[rt URLByAppendingPathComponent:@"llama"] path]
                ];
                [candidates addObjectsFromArray:managed];
            }

            // 2) Homebrew/system locations
            [candidates addObjectsFromArray:@[
                @"/opt/homebrew/opt/llama.cpp/bin/llama-cli",
                @"/opt/homebrew/opt/llama.cpp/bin/llama",
                @"/usr/local/opt/llama.cpp/bin/llama-cli",
                @"/usr/local/opt/llama.cpp/bin/llama",
                @"/opt/homebrew/bin/llama-cli",
                @"/opt/homebrew/bin/llama",
                @"/usr/local/bin/llama-cli",
                @"/usr/local/bin/llama"
            ]];
            NSString *cli = nil;
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSString *p in candidates) {
                if ([fm isExecutableFileAtPath:p]) { cli = p; break; }
            }
            if (!cli) {
                // which fallback
                NSTask *which = [[NSTask alloc] init];
                which.launchPath = @"/usr/bin/which";
                which.arguments = @[ @"llama-cli" ];
                NSPipe *out = [NSPipe pipe]; which.standardOutput = out;
                @try { [which launch]; [which waitUntilExit]; } @catch(NSException *e) {}
                if (which.terminationStatus == 0) {
                    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
                    NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    cli = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
            }
            if (!cli) {
                // try generic "llama" via which
                NSTask *which2 = [[NSTask alloc] init];
                which2.launchPath = @"/usr/bin/which";
                which2.arguments = @[ @"llama" ];
                NSPipe *out2 = [NSPipe pipe]; which2.standardOutput = out2;
                @try { [which2 launch]; [which2 waitUntilExit]; } @catch(NSException *e) {}
                if (which2.terminationStatus == 0) {
                    NSData *data = [[out2 fileHandleForReading] readDataToEndOfFile];
                    NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    NSString *trim = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trim.length) cli = trim;
                }
            }
            if (!cli) {
                // As a last resort, auto-provision into managed runtime from system locations
                NSArray<NSString *> *sysCands = @[
                    @"/opt/homebrew/opt/llama.cpp/bin/llama-cli",
                    @"/opt/homebrew/opt/llama.cpp/bin/llama",
                    @"/usr/local/opt/llama.cpp/bin/llama-cli",
                    @"/usr/local/opt/llama.cpp/bin/llama",
                    @"/opt/homebrew/bin/llama-cli",
                    @"/opt/homebrew/bin/llama",
                    @"/usr/local/bin/llama-cli",
                    @"/usr/local/bin/llama"
                ];
                for (NSString *p in sysCands) {
                    BOOL isDir = NO;
                    if ([fm fileExistsAtPath:p isDirectory:&isDir] && !isDir) {
                        NSString *installed = EnsureManagedRuntimeAndInstall(p);
                        if (installed.length) { cli = installed; break; }
                    }
                }
            }
            // Note: do not force rerouting to managed runtime; prefer launching bundled when available.
            if (!cli) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *err = [NSError errorWithDomain:@"LLamaCpp" code:404 userInfo:@{NSLocalizedDescriptionKey: @"llama-cli not found"}];
                    completion(nil, err);
                });
                return;
            }

            // Side-effect: ensure managed runtime has required dylibs (libggml*, libllama)
            // Keep launching the originally chosen cli (prefer bundled), do not reroute
            (void)EnsureManagedRuntimeAndInstall(cli);

            // Build arguments
            NSMutableArray<NSString *> *args = [NSMutableArray array];
            // Ensure model path provided by loadModel
            NSString *modelPath = _modelPath;
            if (modelPath.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *err = [NSError errorWithDomain:@"LLamaCpp" code:400 userInfo:@{NSLocalizedDescriptionKey: @"Model not loaded"}];
                    completion(nil, err);
                });
                return;
            }

            // Pass model, prompt and generation params
            [args addObjectsFromArray:@[ @"-m", modelPath ]];
            [args addObjectsFromArray:@[ @"-p", prompt ?: @"", @"-n", [NSString stringWithFormat:@"%ld", (long)MAX(1, (long)maxTokens)] ]];
            [args addObjectsFromArray:@[ @"--temp", [NSString stringWithFormat:@"%g", temperature] ]];
            if (seed) { [args addObjectsFromArray:@[ @"--seed", seed.stringValue ]]; }
            for (NSString *s in (stop ?: @[])) { if (s.length) [args addObjectsFromArray:@[@"--stop", s]]; }

            // Launch task
            NSLog(@"[IntPerInt] Launching llama exec: %@", cli);
            NSLog(@"[IntPerInt] Command arguments: %@", [args componentsJoinedByString:@" "]);
            NSTask *task = [[NSTask alloc] init];
            task.launchPath = cli;
            task.currentDirectoryPath = [cli stringByDeletingLastPathComponent];
            task.arguments = args;
            NSPipe *stdoutPipe = [NSPipe pipe];
            NSPipe *stderrPipe = [NSPipe pipe];
            task.standardOutput = stdoutPipe;
            task.standardError = stderrPipe;

            // Set GGML Metal env to help GPU path if available
            NSMutableDictionary<NSString *, NSString *> *env = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
            // Ensure dyld can locate libllama.dylib when using copied execs
            NSMutableArray<NSString *> *dyldPaths = [NSMutableArray array];
            if (resURL) {
                NSURL *libA = [resURL URLByAppendingPathComponent:@"runtime/lib"];
                if ([fm fileExistsAtPath:libA.path]) [dyldPaths addObject:libA.path];
                NSURL *libB = [resURL URLByAppendingPathComponent:@"BundledRuntime/runtime/lib"];
                if ([fm fileExistsAtPath:libB.path]) [dyldPaths addObject:libB.path];
            }
            NSString *bundleBase = [[NSBundle mainBundle] bundlePath];
            NSString *fw = [bundleBase stringByAppendingPathComponent:@"Contents/Frameworks"];
            if ([fm fileExistsAtPath:fw]) [dyldPaths addObject:fw];
            NSString *libin = [bundleBase stringByAppendingPathComponent:@"Contents/lib"];
            if ([fm fileExistsAtPath:libin]) [dyldPaths addObject:libin];
            if (appSup.count > 0) {
                NSURL *libC = [[appSup.firstObject URLByAppendingPathComponent:@"IntPerInt/runtime/lib" isDirectory:YES] URLByStandardizingPath];
                if ([fm fileExistsAtPath:libC.path]) [dyldPaths addObject:libC.path];
            }
            NSString *execLib = [[cli stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../lib"];
            if ([fm fileExistsAtPath:execLib]) [dyldPaths addObject:[execLib stringByStandardizingPath]];
            // Known brew lib locations as fallback
            for (NSString *bp in @[@"/opt/homebrew/opt/llama.cpp/lib", @"/usr/local/opt/llama.cpp/lib"]) {
                if ([fm fileExistsAtPath:bp]) [dyldPaths addObject:bp];
            }
            if (dyldPaths.count) {
                NSString *joined = [dyldPaths componentsJoinedByString:@":"];
                NSString *existing = env[@"DYLD_LIBRARY_PATH"];
                env[@"DYLD_LIBRARY_PATH"] = existing.length ? [@[existing, joined] componentsJoinedByString:@":"] : joined;
                NSLog(@"[IntPerInt] DYLD_LIBRARY_PATH=%@", env[@"DYLD_LIBRARY_PATH"]);
                NSString *existingFB = env[@"DYLD_FALLBACK_LIBRARY_PATH"];
                env[@"DYLD_FALLBACK_LIBRARY_PATH"] = existingFB.length ? [@[existingFB, joined] componentsJoinedByString:@":"] : joined;
            }
            NSString *(^findMetallibDir)(void) = ^NSString *{
                // Check bundled share first
                if (resURL) {
                    NSURL *a = [resURL URLByAppendingPathComponent:@"runtime/share/llama.cpp/default.metallib"];
                    if ([fm fileExistsAtPath:a.path]) { return a.URLByDeletingLastPathComponent.path; }
                    NSURL *b = [resURL URLByAppendingPathComponent:@"BundledRuntime/runtime/share/llama.cpp/default.metallib"];
                    if ([fm fileExistsAtPath:b.path]) { return b.URLByDeletingLastPathComponent.path; }
                }
                // Managed runtime share
                if (appSup.count > 0) {
                    NSURL *c = [[[appSup.firstObject URLByAppendingPathComponent:@"IntPerInt/runtime/share/llama.cpp" isDirectory:YES] URLByAppendingPathComponent:@"default.metallib"] URLByStandardizingPath];
                    if ([fm fileExistsAtPath:c.path]) { return c.URLByDeletingLastPathComponent.path; }
                }
                // Exec dir
                NSString *execDir = [cli stringByDeletingLastPathComponent];
                NSString *execMetallib = [execDir stringByAppendingPathComponent:@"default.metallib"];
                if ([fm fileExistsAtPath:execMetallib]) { return execDir; }
                // Homebrew share
                NSArray<NSString *> *brew = @[@"/opt/homebrew/opt/llama.cpp/share/llama.cpp/default.metallib",
                                              @"/usr/local/opt/llama.cpp/share/llama.cpp/default.metallib"];
                for (NSString *p in brew) { if ([fm fileExistsAtPath:p]) { return [p stringByDeletingLastPathComponent]; } }
                return nil;
            };
            NSString *resDir = findMetallibDir();
            BOOL hasMetal = NO;
            if (resDir.length > 0) {
                env[@"GGML_METAL_PATH_RESOURCES"] = resDir;
                NSString *file = [resDir stringByAppendingPathComponent:@"default.metallib"];
                if ([fm fileExistsAtPath:file]) { env[@"GGML_METAL_PATH"] = file; hasMetal = YES; }
            }
            // If default.metallib is not available, force CPU fallback to avoid runtime error
            if (!hasMetal) {
                // llama.cpp uses -ngl to control GPU layers; 0 disables Metal
                [args addObjectsFromArray:@[@"-ngl", @"0"]];
                NSLog(@"[IntPerInt] default.metallib not found; forcing CPU fallback (-ngl 0)");
            }
            task.environment = env;
            NSLog(@"[IntPerInt] Starting task execution...");
            BOOL launchFailed = NO;
            @try { 
                [task launch]; 
                NSLog(@"[IntPerInt] Task launched successfully, waiting for completion...");
                [task waitUntilExit]; 
                NSLog(@"[IntPerInt] Task completed with status: %d", task.terminationStatus);
            }
            @catch (NSException *e) { 
                NSLog(@"[IntPerInt] Task launch failed with exception: %@", e.reason);
                launchFailed = YES; 
            }

            NSData *outData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
            NSData *errData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
            NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
            NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";

            NSLog(@"[IntPerInt] stdout length: %lu bytes", (unsigned long)outData.length);
            NSLog(@"[IntPerInt] stderr length: %lu bytes", (unsigned long)errData.length);
            if (outStr.length > 0) NSLog(@"[IntPerInt] stdout preview: %@", [outStr length] > 200 ? [[outStr substringToIndex:200] stringByAppendingString:@"..."] : outStr);
            if (errStr.length > 0) NSLog(@"[IntPerInt] stderr content: %@", errStr);

            if (!launchFailed && task.terminationStatus == 0) {
                NSLog(@"[IntPerInt] Task succeeded, returning output");
                dispatch_async(dispatch_get_main_queue(), ^{ completion(outStr, nil); });
                return;
            }

            // Fallback: if bundled exec failed, try system Homebrew llama-cli
            BOOL isBundledExec = [cli containsString:@".app/Contents/Resources/runtime/bin/"];
            if ((launchFailed || task.terminationStatus != 0) && isBundledExec) {
                NSArray<NSString *> *sysExecs = @[ @"/opt/homebrew/opt/llama.cpp/bin/llama-cli",
                                                  @"/opt/homebrew/opt/llama.cpp/bin/llama",
                                                  @"/usr/local/opt/llama.cpp/bin/llama-cli",
                                                  @"/usr/local/opt/llama.cpp/bin/llama",
                                                  @"/opt/homebrew/bin/llama-cli",
                                                  @"/opt/homebrew/bin/llama",
                                                  @"/usr/local/bin/llama-cli",
                                                  @"/usr/local/bin/llama" ];
                NSString *sysCli = nil;
                for (NSString *p in sysExecs) { if ([fm isExecutableFileAtPath:p]) { sysCli = p; break; } }
                if (sysCli.length) {
                    NSLog(@"[IntPerInt] Bundled exec failed (status=%d). Retrying with system exec: %@", task.terminationStatus, sysCli);
                    NSTask *task2 = [[NSTask alloc] init];
                    task2.launchPath = sysCli;
                    task2.currentDirectoryPath = [sysCli stringByDeletingLastPathComponent];
                    task2.arguments = args;
                    NSPipe *out2 = [NSPipe pipe];
                    NSPipe *err2 = [NSPipe pipe];
                    task2.standardOutput = out2;
                    task2.standardError = err2;
                    // Clean env, keep only Metal/CPU hints
                    NSMutableDictionary *env2 = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
                    if (env[@"GGML_METAL_PATH"]) env2[@"GGML_METAL_PATH"] = env[@"GGML_METAL_PATH"];
                    if (env[@"GGML_METAL_PATH_RESOURCES"]) env2[@"GGML_METAL_PATH_RESOURCES"] = env[@"GGML_METAL_PATH_RESOURCES"];
                    task2.environment = env2;
                    @try { [task2 launch]; [task2 waitUntilExit]; }
                    @catch (NSException *e2) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSString *msg = errStr.length ? errStr : (e2.reason ?: @"launch failed");
                            completion(nil, [NSError errorWithDomain:@"LLamaCpp" code:500 userInfo:@{NSLocalizedDescriptionKey: msg}]);
                        });
                        return;
                    }
                    NSData *outData2 = [[out2 fileHandleForReading] readDataToEndOfFile];
                    NSString *outStr2 = [[NSString alloc] initWithData:outData2 encoding:NSUTF8StringEncoding] ?: @"";
                    if (task2.terminationStatus != 0) {
                        NSData *errData2 = [[err2 fileHandleForReading] readDataToEndOfFile];
                        NSString *errStr2 = [[NSString alloc] initWithData:errData2 encoding:NSUTF8StringEncoding] ?: @"unknown error";
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, [NSError errorWithDomain:@"LLamaCpp" code:task2.terminationStatus userInfo:@{NSLocalizedDescriptionKey: errStr2}]); });
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(outStr2, nil); });
                    }
                    return;
                }
            }

            // No fallback path succeeded
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger code = launchFailed ? 500 : task.terminationStatus;
                NSString *msg = errStr.length ? errStr : (launchFailed ? @"launch failed" : @"unknown error");
                completion(nil, [NSError errorWithDomain:@"LLamaCpp" code:code userInfo:@{NSLocalizedDescriptionKey: msg}]);
            });
        }
    });
}

- (void)unloadModel {
    // TODO: Implement actual cleanup
    /*
    if (_context) {
        llama_free(_context);
        _context = NULL;
    }
    if (_model) {
        llama_free_model(_model);
        _model = NULL;
    }
    */
}

- (void)dealloc {
    [self unloadModel];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end
