#import "ExceptionCatcher.h"

NSError *_Nullable YapRunCatchingExceptions(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"com.frigade.Yap.AudioException"
                                   code:1
                               userInfo:@{
                                   NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                                   @"ExceptionName": exception.name,
                               }];
    }
}
