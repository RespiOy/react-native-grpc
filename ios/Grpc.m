#import "Grpc.h"
#import <GRPCClient/GRPCTransport.h>
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

RCT_EXPORT_METHOD(setHost:(NSString *)host) {
    self.grpcHost = host;
}

RCT_EXPORT_METHOD(setInsecure:(nonnull NSNumber *)insecure) {
    self.grpcInsecure = [insecure boolValue];
}

RCT_EXPORT_METHOD(setResponseSizeLimit:(nonnull NSNumber *)limit) {
    self.grpcResponseSizeLimit = limit;
}

- (GRPCProtoCall *)startGrpcCallWithId:(NSNumber *)callId path:(NSString *)path headers:(NSDictionary *)headers {
    NSAssert(self.grpcHost != nil, @"gRPC host must be set");

    GrpcWriteable *writeable = [[GrpcWriteable alloc] init];
    writeable.callId = callId;
    writeable.module = self;

    // Placeholder empty writer – we will use requestsWriter directly for writes
    GRXWriter *requestsWriter = [GRXWriter writerWithValue:[NSData data]];

    GRPCProtoCall *call = [[GRPCProtoCall alloc] initWithHost:self.grpcHost
                                                        path:path
                                              requestsWriter:requestsWriter
                                               responseClass:[NSData class]
                                           responseWriteable:writeable];

    call.callOptions = [self getCallOptionsWithHeaders:headers];

    [call start];

    [calls setObject:call forKey:callId];

    return call;
}

RCT_EXPORT_METHOD(unaryCall:(nonnull NSNumber *)callId
                   path:(NSString *)path
                    obj:(NSDictionary *)obj
                headers:(NSDictionary *)headers
               resolver:(RCTPromiseResolveBlock)resolve
               rejecter:(RCTPromiseRejectBlock)reject)
{
    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:obj[@"data"] options:0];

    GRPCProtoCall *call = [self startGrpcCallWithId:callId path:path headers:headers];

    [call.requestsWriter writeValue:requestData];
    [call.requestsWriter finish];

    resolve([NSNull null]);
}

RCT_EXPORT_METHOD(serverStreamingCall:(nonnull NSNumber *)callId
                   path:(NSString *)path
                    obj:(NSDictionary *)obj
                headers:(NSDictionary *)headers
               resolver:(RCTPromiseResolveBlock)resolve
               rejecter:(RCTPromiseRejectBlock)reject)
{
    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:obj[@"data"] options:0];

    GRPCProtoCall *call = [self startGrpcCallWithId:callId path:path headers:headers];

    [call.requestsWriter writeValue:requestData];
    [call.requestsWriter finish];

    resolve([NSNull null]);
}

RCT_EXPORT_METHOD(clientStreamingCall:(nonnull NSNumber *)callId
                   path:(NSString *)path
                    obj:(NSDictionary *)obj
                headers:(NSDictionary *)headers
               resolver:(RCTPromiseResolveBlock)resolve
               rejecter:(RCTPromiseRejectBlock)reject)
{
    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:obj[@"data"] options:0];

    GRPCProtoCall *call = [calls objectForKey:callId];
    if (!call) {
        call = [self startGrpcCallWithId:callId path:path headers:headers];
    }

    [call.requestsWriter writeValue:requestData];

    resolve([NSNull null]);
}

RCT_EXPORT_METHOD(finishClientStreaming:(nonnull NSNumber *)callId
               resolver:(RCTPromiseResolveBlock)resolve
               rejecter:(RCTPromiseRejectBlock)reject)
{
    GRPCProtoCall *call = [calls objectForKey:callId];
    if (call) {
        [call.requestsWriter finish];
        resolve(@YES);
    } else {
        resolve(@NO);
    }
}

RCT_EXPORT_METHOD(cancelGrpcCall:(nonnull NSNumber *)callId
               resolver:(RCTPromiseResolveBlock)resolve
               rejecter:(RCTPromiseRejectBlock)reject)
{
    GRPCProtoCall *call = [calls objectForKey:callId];
    if (call) {
        [call cancel];
        resolve(@YES);
    } else {
        resolve(@NO);
    }
}

RCT_EXPORT_MODULE()

@end
