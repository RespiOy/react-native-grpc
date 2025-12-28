#import "Grpc.h"
#import <GRPCClient/GRPCCall+Options.h>
#import <GRPCClient/GRPCTransport.h>

#pragma mark - Response Handler Interface

@interface GrpcResponseHandler : NSObject <GRPCResponseHandler>
- (instancetype)initWithId:(NSNumber *)callId emitter:(Grpc *)emitter calls:(NSMutableDictionary *)calls;
@end

#pragma mark - Main Module Implementation

@implementation Grpc {
    bool hasListeners;
    NSMutableDictionary<NSNumber *, GRPCCall2 *> *calls;
}

RCT_EXPORT_MODULE()

- (instancetype)init {
    if (self = [super init]) {
        calls = [[NSMutableDictionary alloc] init];
    }
    return self;
}

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"grpc-call"];
}

- (void)startObserving { hasListeners = YES; }
- (void)stopObserving { hasListeners = NO; }

#pragma mark - Configuration Methods

RCT_EXPORT_METHOD(setHost:(NSString *)host) {
    self.grpcHost = host;
}

RCT_EXPORT_METHOD(setInsecure:(nonnull NSNumber*)insecure) {
    self.grpcInsecure = [insecure boolValue];
}

RCT_EXPORT_METHOD(setResponseSizeLimit:(nonnull NSNumber*)limit) {
    self.grpcResponseSizeLimit = limit;
}

#pragma mark - RPC Methods

RCT_EXPORT_METHOD(unaryCall:(nonnull NSNumber*)callId
                  path:(NSString*)path
                  obj:(NSDictionary*)obj
                  headers:(NSDictionary*)headers)
{
    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:[obj valueForKey:@"data"]
                                                              options:NSDataBase64DecodingIgnoreUnknownCharacters];

    GRPCCall2 *call = [self createCallWithId:callId path:path headers:headers];
    [call writeData:requestData];
    [call finish];
}

RCT_EXPORT_METHOD(serverStreamingCall:(nonnull NSNumber*)callId
                  path:(NSString*)path
                  obj:(NSDictionary*)obj
                  headers:(NSDictionary*)headers)
{
    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:[obj valueForKey:@"data"]
                                                              options:NSDataBase64DecodingIgnoreUnknownCharacters];

    GRPCCall2 *call = [self createCallWithId:callId path:path headers:headers];
    [call writeData:requestData];
    [call finish];
}

RCT_EXPORT_METHOD(clientStreamingCall:(nonnull NSNumber*)callId
                  path:(NSString*)path
                  obj:(NSDictionary*)obj
                  headers:(NSDictionary*)headers)
{
    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:[obj valueForKey:@"data"]
                                                              options:NSDataBase64DecodingIgnoreUnknownCharacters];

    GRPCCall2 *call = calls[callId];
    if (call == nil) {
        call = [self createCallWithId:callId path:path headers:headers];
    }
    [call writeData:requestData];
}

RCT_EXPORT_METHOD(finishClientStreaming:(nonnull NSNumber*)callId) {
    GRPCCall2 *call = calls[callId];
    if (call) {
        [call finish];
    }
}

RCT_EXPORT_METHOD(cancelGrpcCall:(nonnull NSNumber*)callId) {
    GRPCCall2 *call = calls[callId];
    if (call) {
        [call cancel];
        [calls removeObjectForKey:callId];
    }
}

#pragma mark - Private Helper

- (GRPCCall2 *)createCallWithId:(NSNumber *)callId path:(NSString *)path headers:(NSDictionary *)headers {
    GRPCRequestOptions *requestOptions = [[GRPCRequestOptions alloc] initWithHost:self.grpcHost
                                                                             path:path
                                                                           safety:GRPCCallSafetyDefault];

    GRPCMutableCallOptions *callOptions = [[GRPCMutableCallOptions alloc] init];
    callOptions.initialMetadata = headers;
    callOptions.transport = self.grpcInsecure ? GRPCDefaultTransportImplList.core_insecure : GRPCDefaultTransportImplList.core_secure;

    if (self.grpcResponseSizeLimit != nil) {
        callOptions.responseSizeLimit = self.grpcResponseSizeLimit.unsignedLongValue;
    }

    GrpcResponseHandler *handler = [[GrpcResponseHandler alloc] initWithId:callId emitter:self calls:calls];

    GRPCCall2 *call = [[GRPCCall2 alloc] initWithRequestOptions:requestOptions
                                                responseHandler:handler
                                                    callOptions:callOptions];

    calls[callId] = call;
    [call start];
    return call;
}

@end

#pragma mark - Response Handler Implementation

@implementation GrpcResponseHandler {
    NSNumber *_callId;
    __weak Grpc *_emitter;
    __weak NSMutableDictionary *_calls;
    dispatch_queue_t _dispatchQueue;
}

- (instancetype)initWithId:(NSNumber *)callId emitter:(Grpc *)emitter calls:(NSMutableDictionary *)calls {
    if (self = [super init]) {
        _callId = callId;
        _emitter = emitter;
        _calls = calls;
        _dispatchQueue = dispatch_queue_create(nil, DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)didReceiveInitialMetadata:(NSDictionary *)initialMetadata {
    [self sendEventByType:@"headers" payload:[self processMetadata:initialMetadata]];
}

- (void)didReceiveRawMessage:(id)message {
    if ([message isKindOfClass:[NSData class]]) {
        NSString *base64String = [(NSData *)message base64EncodedStringWithOptions:0];
        [self sendEventByType:@"response" payload:base64String];
    }
}

- (void)didCloseWithTrailingMetadata:(NSDictionary *)trailingMetadata error:(NSError *)error {
    if (error) {
        NSDictionary *body = @{
            @"id": _callId,
            @"type": @"error",
            @"error": error.localizedDescription,
            @"code": @(error.code),
            @"trailers": [self processMetadata:trailingMetadata]
        };
        [_emitter sendEventWithName:@"grpc-call" body:body];
    } else {
        [self sendEventByType:@"trailers" payload:[self processMetadata:trailingMetadata]];
    }
    [_calls removeObjectForKey:_callId];
}

- (void)sendEventByType:(NSString *)type payload:(id)payload {
    NSDictionary *body = @{ @"id": _callId, @"type": type, @"payload": payload };
    [_emitter sendEventWithName:@"grpc-call" body:body];
}

- (NSDictionary *)processMetadata:(NSDictionary *)metadata {
    if (!metadata) return @{};
    NSMutableDictionary *processed = [metadata mutableCopy];
    [metadata enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([obj isKindOfClass:[NSData class]]) {
            [processed setObject:[obj base64EncodedStringWithOptions:0] forKey:key];
        }
    }];
    return processed;
}

- (dispatch_queue_t)dispatchQueue {
    return _dispatchQueue;
}

@end
