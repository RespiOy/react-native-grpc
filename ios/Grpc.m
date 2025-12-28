#import "Grpc.h"
#import <ProtoRPC/ProtoRPC.h>
#import <RxLibrary/GRXWriteable.h>

@interface GrpcWriteable : NSObject <GRXWriteable>

@property (nonatomic, copy) NSNumber *callId;
@property (nonatomic, weak) Grpc *module;

@end

@implementation GrpcWriteable

- (void)writeValue:(id)value {
    NSData *data = (NSData *)value;
    if (self.module->hasListeners) {
        NSDictionary *event = @{
            @"id": self.callId,
            @"type": @"response",
            @"payload": [data base64EncodedStringWithOptions:0]
        };
        [self.module sendEventWithName:@"grpc-call" body:event];
    }
}

- (void)didReceiveInitialMetadata:(NSDictionary *)headers {
    if (self.module->hasListeners) {
        NSMutableDictionary *responseHeaders = [NSMutableDictionary dictionaryWithDictionary:headers];
        [responseHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if ([obj isKindOfClass:[NSData class]]) {
                [responseHeaders setValue:[obj base64EncodedStringWithOptions:0] forKey:key];
            }
        }];
        NSDictionary *event = @{
            @"id": self.callId,
            @"type": @"headers",
            @"payload": responseHeaders
        };
        [self.module sendEventWithName:@"grpc-call" body:event];
    }
}

- (void)didCloseWithTrailingMetadata:(NSDictionary *)trailers error:(NSError *)error {
    [self.module.calls removeObjectForKey:self.callId];

    NSMutableDictionary *responseTrailers = [NSMutableDictionary dictionaryWithDictionary:trailers];
    [responseTrailers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([obj isKindOfClass:[NSData class]]) {
            [responseTrailers setValue:[obj base64EncodedStringWithOptions:0] forKey:key];
        }
    }];

    if (self.module->hasListeners) {
        if (error) {
            NSDictionary *event = @{
                @"id": self.callId,
                @"type": @"error",
                @"error": error.localizedDescription ?: @"Unknown error",
                @"code": @(error.code),
                @"trailers": responseTrailers
            };
            [self.module sendEventWithName:@"grpc-call" body:event];
        } else {
            NSDictionary *event = @{
                @"id": self.callId,
                @"type": @"trailers",
                @"payload": responseTrailers
            };
            [self.module sendEventWithName:@"grpc-call" body:event];
        }
    }
}

@end

@implementation Grpc {
    bool hasListeners;
    NSMutableDictionary<NSNumber *, GRPCProtoCall *> *calls;
}

- (instancetype)init {
    if (self = [super init]) {
        calls = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)startObserving {
    hasListeners = YES;
}

- (void)stopObserving {
    hasListeners = NO;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"grpc-call"];
}

- (GRPCMutableCallOptions *)getCallOptionsWithHeaders:(NSDictionary *)headers {
    GRPCMutableCallOptions *options = [[GRPCMutableCallOptions alloc] init];
    options.initialMetadata = headers;
    options.transport = self.grpcInsecure ? GRPCDefaultTransportImplList.core_insecure : GRPCDefaultTransportImplList.core_secure;
    if (self.grpcResponseSizeLimit != nil) {
        options.responseSizeLimit = self.grpcResponseSizeLimit.unsignedLongValue;
    }
    return options;
}

RCT_EXPORT_METHOD(getHost:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    resolve(self.grpcHost);
}

RCT_EXPORT_METHOD(getIsInsecure:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    resolve(@(self.grpcInsecure));
}

RCT_EXPORT_METHOD(setHost:(
