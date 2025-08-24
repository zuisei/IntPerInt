#import "LLamaCppWrapper.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <Metal/Metal.h>
// #import "llama.h" // Uncomment when llama.cpp is properly linked

@implementation LLamaCppWrapper {
    // void *_model; // llama_model * when properly linked
    // void *_context; // llama_context * when properly linked
    NSString *_modelPath; // persisted for CLI invocation until lib API is wired
}
// Split marker to reliably separate prompt from model output
static NSString * const kResponseSentinel = @"<|OUTPUT|>";

// Helper: detect if a given llama CLI supports a specific flag by checking --help output
static BOOL LlamaCliSupportsFlag(NSString *cliPath, NSString *flag) {
    if (cliPath.length == 0 || flag.length == 0) return NO;
    @try {
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = cliPath;
        t.arguments = @[ @"--help" ];
        NSPipe *p = [NSPipe pipe];
        t.standardOutput = p; t.standardError = p;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        t.terminationHandler = ^(NSTask *tt){ dispatch_semaphore_signal(sem); };
        [t launch];
        // wait up to ~800ms; help is fast and avoids blocking
        (void)dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)));
        NSData *d = [[p fileHandleForReading] readDataToEndOfFile];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        return [s containsString:flag];
    } @catch(NSException *e) { return NO; }
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
            self->_modelPath = [modelPath copy];
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
    // 即座にメインスレッドに制御を返し、UI フリーズを防ぐ
    dispatch_async(dispatch_get_main_queue(), ^{
        // UI を即座に「生成中」状態に更新（ここで呼び出し元に制御が戻る）
        NSLog(@"[IntPerInt] Starting generation (UI will update immediately)");
    });
    
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
            NSString *modelPath = self->_modelPath;
            if (modelPath.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *err = [NSError errorWithDomain:@"LLamaCpp" code:400 userInfo:@{NSLocalizedDescriptionKey: @"Model not loaded"}];
                    completion(nil, err);
                });
                return;
            }

            // Append a sentinel so we can surgically strip any echoed prompt
            NSString *basicPrompt = [NSString stringWithFormat:@"%@\n\n%@\n", (prompt ?: @"こんにちは"), kResponseSentinel];
            
            // 最小限のオプションのみ
            [args addObjectsFromArray:@[ @"-m", modelPath ]];
            [args addObjectsFromArray:@[ @"-p", basicPrompt ]];
            NSInteger tok = (maxTokens > 0 ? maxTokens : 50);
            [args addObjectsFromArray:@[ @"-n", [@(tok) stringValue] ]];  // 応答トークン数
            
            if (seed) { [args addObjectsFromArray:@[ @"--seed", seed.stringValue ]]; }

            // Respect user-provided stop sequences (each becomes --stop <seq>)
            if (stop.count > 0) {
                for (NSString *s in stop) {
                    if (s.length > 0) {
                        [args addObjectsFromArray:@[@"--stop", s]];
                    }
                }
            }

            // Keep llama.cpp quiet and do not echo the prompt, but only add flags if supported
            NSMutableArray<NSString *> *quiet = [NSMutableArray array];
            if (LlamaCliSupportsFlag(cli, @"--log-disable"))        [quiet addObject:@"--log-disable"];
            if (LlamaCliSupportsFlag(cli, @"--no-display-prompt"))  [quiet addObject:@"--no-display-prompt"];
            if (LlamaCliSupportsFlag(cli, @"--simple-io"))          [quiet addObject:@"--simple-io"];
            if (quiet.count) [args addObjectsFromArray:quiet];

            // Launch task
            NSLog(@"[IntPerInt] DEBUG: Launching llama exec: %@", cli);
            NSLog(@"[IntPerInt] DEBUG: Command arguments: %@", [args componentsJoinedByString:@" "]);
            NSLog(@"[IntPerInt] DEBUG: Working directory: %@", [cli stringByDeletingLastPathComponent]);
            NSLog(@"[IntPerInt] DEBUG: Model path exists: %@", [[NSFileManager defaultManager] fileExistsAtPath:modelPath] ? @"YES" : @"NO");
            
            NSTask *task = [[NSTask alloc] init];
            task.launchPath = cli;
            task.currentDirectoryPath = [cli stringByDeletingLastPathComponent];
            task.arguments = args;
            NSPipe *stdoutPipe = [NSPipe pipe];
            NSPipe *stderrPipe = [NSPipe pipe];
            task.standardOutput = stdoutPipe;
            task.standardError = stderrPipe;

            // --- BEGIN: async drain stdout/stderr to avoid pipe deadlock ---
            __block NSMutableData *outBuf = [NSMutableData data];
            __block NSMutableData *errBuf = [NSMutableData data];
            __block BOOL stdoutClosed = NO;
            __block BOOL stderrClosed = NO;

            NSFileHandle *outFH = [stdoutPipe fileHandleForReading];
            NSFileHandle *errFH = [stderrPipe fileHandleForReading];

            outFH.readabilityHandler = ^(NSFileHandle *h) {
                @autoreleasepool {
                    NSData *d = [h availableData];
                    if (d.length > 0) {
                        [outBuf appendData:d];
                    } else {
                        // EOF
                        stdoutClosed = YES;
                        h.readabilityHandler = nil;
                    }
                }
            };

            errFH.readabilityHandler = ^(NSFileHandle *h) {
                @autoreleasepool {
                    NSData *d = [h availableData];
                    if (d.length > 0) {
                        [errBuf appendData:d];
                    } else {
                        // EOF
                        stderrClosed = YES;
                        h.readabilityHandler = nil;
                    }
                }
            };

            // termination group instead of waitUntilExit + semaphore
            __block BOOL launchFailed = NO;
            __block int  termStatus = -1;
            dispatch_group_t termGroup = dispatch_group_create();
            dispatch_group_enter(termGroup);
            // Removed unused weakTask (was only for earlier debug)
            task.terminationHandler = ^(NSTask *t){
                termStatus = (int)t.terminationStatus;
                dispatch_group_leave(termGroup);
            };
            // --- END: async drain stdout/stderr ---

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
            // Modern Metal GPU detection - check system capabilities instead of metallib files
            BOOL hasMetal = NO;
            
            // Check if Metal GPU acceleration is supported on this system
            // Modern llama.cpp versions don't require default.metallib
            if (@available(macOS 10.13, *)) {
                // Check for Metal-capable devices
                id<MTLDevice> device = MTLCreateSystemDefaultDevice();
                if (device != nil) {
                    hasMetal = YES;
                    NSLog(@"[IntPerInt] Metal GPU detected: %@", device.name);
                    
                    // Set Metal environment variables for optimal performance
                    env[@"GGML_METAL_ENABLE"] = @"1";
                    env[@"GGML_METAL_PERFORMANCE_LOGGING"] = @"0";
                } else {
                    NSLog(@"[IntPerInt] No Metal-capable GPU found");
                }
            } else {
                NSLog(@"[IntPerInt] macOS version too old for Metal support");
            }
            // If default.metallib is not available, force CPU fallback to avoid runtime error
            if (!hasMetal) {
                // llama.cpp uses -ngl to control GPU layers; 0 disables Metal
                [args addObjectsFromArray:@[@"-ngl", @"0"]];
                NSLog(@"[IntPerInt] default.metallib not found; forcing CPU fallback (-ngl 0)");
            } else {
                // Metal GPU is available - use maximum GPU acceleration
                [args addObjectsFromArray:@[@"-ngl", @"-1"]];  // All layers on GPU
                NSLog(@"[IntPerInt] Metal GPU available; using maximum GPU acceleration (-ngl -1)");
            }
            task.environment = env;
            NSLog(@"[IntPerInt] Starting task execution...");
            @try {
                [task launch];
                NSLog(@"[IntPerInt] Task launched successfully; waiting with timeout...");

                // 30s timeout
                dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC));
                long r = dispatch_group_wait(termGroup, timeout);
                if (r != 0) {
                    NSLog(@"[IntPerInt] Task timed out; sending terminate...");
                    [task terminate];
                    // give it a moment, then SIGKILL if still running
                    usleep(500 * 1000);
                    if (task.isRunning) {
                        NSLog(@"[IntPerInt] Still running; SIGKILL pid=%d", task.processIdentifier);
                        kill(task.processIdentifier, SIGKILL);
                    }
                    // wait unbounded after kill
                    (void)dispatch_group_wait(termGroup, DISPATCH_TIME_FOREVER);
                }
            }
            @catch (NSException *e) {
                NSLog(@"[IntPerInt] Task launch failed with exception: %@", e.reason);
                launchFailed = YES;
            }

            // Final drain (defensive): if handlers already hit EOF these will be empty
            if (!stdoutClosed) {
                NSData *d = [outFH availableData];
                if (d.length) [outBuf appendData:d];
                outFH.readabilityHandler = nil;
            }
            if (!stderrClosed) {
                NSData *d = [errFH availableData];
                if (d.length) [errBuf appendData:d];
                errFH.readabilityHandler = nil;
            }

            NSString *outStr = [[NSString alloc] initWithData:outBuf encoding:NSUTF8StringEncoding] ?: @"";
            NSString *errStr = [[NSString alloc] initWithData:errBuf encoding:NSUTF8StringEncoding] ?: @"";

            // 安定した出力クリーニング
            outStr = [self cleanModelOutput:outStr];

            NSLog(@"[IntPerInt] stdout length: %lu bytes", (unsigned long)outBuf.length);
            NSLog(@"[IntPerInt] stderr length: %lu bytes", (unsigned long)errBuf.length);
            if (outStr.length > 0) {
                NSString *preview = [outStr length] > 200 ? [[outStr substringToIndex:200] stringByAppendingString:@"..."] : outStr;
                NSLog(@"[IntPerInt] cleaned output preview: %@", preview);
            }
            if (errStr.length > 0) NSLog(@"[IntPerInt] stderr content: %@", errStr);

            if (!launchFailed && task.terminationStatus == 0) {
                NSLog(@"[IntPerInt] Task succeeded, returning output (%lu characters)", (unsigned long)outStr.length);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(outStr, nil); });
                return;
            } else if (task.terminationStatus != 0) {
                NSLog(@"[IntPerInt] Task failed with exit code: %d", task.terminationStatus);
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

//  1) strips llama/ggml logs,
//  2) drops ANSI escape codes,
//  3) cuts everything before the sentinel if present,
//  4) otherwise tries to remove a verbatim echoed prompt prefix,
//  5) trims surrounding whitespace.
- (NSString *)cleanModelOutput:(NSString *)rawOutput {
    if (!rawOutput || rawOutput.length == 0) return @"";

    NSMutableString *s = [rawOutput mutableCopy];

    // Drop trailing markers such as "EOF by user" that some models print
    NSRegularExpression *eofLine = [NSRegularExpression regularExpressionWithPattern:@"(?mi)^.*\\bEOF by user\\b.*$" options:0 error:nil];
    [eofLine replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];

    // 1) Strip known system log lines (llama_, ggml_, main: )
    NSArray *systemPrefixes = @[@"llama_", @"ggml_", @"main: "];
    for (NSString *prefix in systemPrefixes) {
        NSString *pattern = [NSString stringWithFormat:@"(?m)^.*%@.*\\n?", [NSRegularExpression escapedPatternForString:prefix]];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        [re replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    }

    // 2) Remove ANSI escape sequences (colors, cursor controls)
    NSRegularExpression *ansi = [NSRegularExpression regularExpressionWithPattern:@"\\x1B\\[[0-9;]*[A-Za-z]" options:0 error:nil];
    [ansi replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];

    // Prefer the assistant final channel if the model uses multi-channel tags
    NSString *cleaned = nil;
    NSRegularExpression *reFinal = [NSRegularExpression regularExpressionWithPattern:@"<\\|start\\|>\\s*assistant\\s*<\\|channel\\|>\\s*final\\s*<\\|message\\|>([\\s\\S]*?)(?:<\\|end\\|>|$)" options:0 error:nil];
    NSTextCheckingResult *mFinal = [reFinal firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (mFinal && mFinal.numberOfRanges > 1) {
        cleaned = [s substringWithRange:[mFinal rangeAtIndex:1]];
    } else {
        // If analysis blocks exist, drop them entirely
        NSRegularExpression *reAnalysis = [NSRegularExpression regularExpressionWithPattern:@"<\\|start\\|>\\s*assistant\\s*<\\|channel\\|>\\s*analysis\\s*<\\|message\\|>[\\s\\S]*?(?=(<\\|start\\|>|$))" options:0 error:nil];
        NSMutableString *tmp = [s mutableCopy];
        [reAnalysis replaceMatchesInString:tmp options:0 range:NSMakeRange(0, tmp.length) withTemplate:@""];
        cleaned = tmp;
    }

    // 3) If our sentinel exists, keep only the text after it
    NSRange sentinelRange = [cleaned rangeOfString:kResponseSentinel];
    if (sentinelRange.location != NSNotFound) {
        NSUInteger start = NSMaxRange(sentinelRange);
        if (start < cleaned.length) {
            cleaned = [cleaned substringFromIndex:start];
        } else {
            cleaned = @"";
        }
    } else {
        // 4) Heuristic: drop a verbatim echo of the prompt if present at the beginning
        // We look for the first occurrence of the sentinel we *intended* to send in the prompt build path
        // and, if not found, try to remove the original prompt itself (up to a safe length)
        // Note: original prompt with sentinel appended lives in `basicPrompt` at generation time; here we conservatively
        // strip only if the very beginning matches until a double newline.
        NSRange delim = [cleaned rangeOfString:@"\n\n" options:0 range:NSMakeRange(0, MIN((NSUInteger)2048, cleaned.length))];
        if (delim.location != NSNotFound && delim.location < 1024) {
            // If the text starts by repeating what looks like our prompt header, drop it
            // (common when models echo input before answering)
            cleaned = [cleaned substringFromIndex:NSMaxRange(delim)];
        }
    }

    // 5) Final trim and length guard
    // Remove any remaining chat/template tags like <|start|> ... <|end|>
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"<\\|[^|>]+(?:\\|[^|>]+)*\\|>" options:0 error:nil];
    NSMutableString *cleanNoTags = [cleaned mutableCopy];
    [tags replaceMatchesInString:cleanNoTags options:0 range:NSMakeRange(0, cleanNoTags.length) withTemplate:@""];
    cleaned = cleanNoTags;

    cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleaned.length > 100000) { // hard guard to avoid huge accidental dumps in UI
        cleaned = [[cleaned substringToIndex:100000] stringByAppendingString:@"…"];
    }

    return cleaned.length > 0 ? cleaned : @"（応答を生成できませんでした）";
}

- (void)dealloc {
    [self unloadModel];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end
