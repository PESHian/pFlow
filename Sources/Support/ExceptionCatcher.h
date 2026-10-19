#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and turns any Objective-C exception it raises into a returned
/// NSError (nil when it completes normally).
///
/// AVFoundation raises ObjC exceptions for some audio states — notably an input
/// format mismatch from `installTap(onBus:...)` when a device changes — that
/// Swift's `try`/`catch` cannot intercept. Left unhandled they unwind through
/// Swift, corrupt the concurrency runtime, and the app dies on a later
/// main-thread access (a button tap) rather than at the throw. Wrapping the
/// risky call keeps the failure local and recoverable.
NSError *_Nullable YapRunCatchingExceptions(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
