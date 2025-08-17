#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LLamaCppWrapper : NSObject

- (void)loadModel:(NSString *)modelPath completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)generateText:(NSString *)prompt completion:(void (^)(NSString * _Nullable response, NSError * _Nullable error))completion;
- (void)unloadModel;

@end

NS_ASSUME_NONNULL_END