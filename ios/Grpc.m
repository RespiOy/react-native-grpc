#import "Grpc.h"
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <ProtoRPC/ProtoRPC.h>
#import <RxLibrary/GRXWritable.h>
#import <RxLibrary/GRXWriter.h>

@interface Grpc : RCTEventEmitter <RCTBridgeModule>

@property (nonatomic, copy) NSString* grpcHost;
@property (nonatomic, copy) NSNumber* grpcResponseSizeLimit;
@property (nonatomic, assign) BOOL grpcInsecure;

@end

@implementation Grpc {
    bool hasListeners;
    NSMutableDictionary<NSNumber *, id> *calls;
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

RCT_EXPORT_METHOD(getHost:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    resolve(self.grpcHost);
}

RCT_EXPORT_METHOD(getIsInsecure:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    resolve([NSNumber numberWithBool:self.grpcInsecure]);
}

RCT_EXPORT_METHOD(setHost:(NSString *)host) {
    self.grpcHost = host;
}

RCT_EXPORT_METHOD(setInsecure:(nonnull NSNumber*)insecure) {
    self.grpcInsecure = [insecure boolValue];
}

RCT_EXPORT_METHOD(setResponseSizeLimit:(nonnull NSNumber*)limit) {
    self.grpcResponseSizeLimit = limit;
}

RCT_EXPORT_METHOD(unaryCall:
    (nonnull NSNumber*)callId
        path:(NSString*)path
        obj:(NSDictionary*)obj
        headers:(NSDictionary*)headers
        resolver:(RCTPromiseResolveBlock)resolve
        rejecter:(RCTPromiseRejectBlock)reject) {

    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:[obj valueForKey:@"data"] options:NSDataBase64DecodingIgnoreUnknownCharacters];

    ProtoRPC *rpc = [self createProtoRpcWithId:callId path:path headers:headers requestData:requestData];

    [calls setObject:rpc forKey:callId];

    resolve([NSNull null]);
}

RCT_EXPORT_METHOD(serverStreamingCall:
    (nonnull NSNumber*)callId
        path:(NSString*)path
        obj:(NSDictionary*)obj
        headers:(NSDictionary*)headers
        resolver:(RCTPromiseResolveBlock)resolve
        rejecter:(RCTPromiseRejectBlock)reject) {

    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:[obj valueForKey:@"data"] options:NSDataBase64DecodingIgnoreUnknownCharacters];

    ProtoRPC *rpc = [self createProtoRpcWithId:callId path:path headers:headers requestData:requestData];

    [calls setObject:rpc forKey:callId];

    resolve([NSNull null]);
}

RCT_EXPORT_METHOD(clientStreamingCall:
    (nonnull NSNumber*)callId
        path:(NSString*)path
        obj:(NSDictionary*)obj
        headers:(NSDictionary*)headers
        resolver:(RCTPromiseResolveBlock)resolve
        rejecter:(RCTPromiseRejectBlock)reject) {

    NSData *requestData = [[NSData alloc] initWithBase64EncodedString:[obj valueForKey:@"data"] options:NSDataBase64DecodingIgnoreUnknownCharacters];

    GRXMutableWriter *writer = [calls objectForKey:[NSString stringWithFormat:@"writer_%@", callId]];

    if (writer == nil) {
        writer = [[GRXMutableWriter alloc] init];

        ProtoRPC *rpc = [self createProtoRpcWithId:callId path:path headers:headers requestWriter:writer];

        [calls setObject:rpc forKey:callId];
        [calls setObject:writer forKey:[NSString stringWithFormat:@"writer_%@", callId]];
    }

    [writer writeValue:requestData];

    resolve([NSNull null]);
}

RCT_EXPORT_METHOD(finishClientStreaming:
    (nonnull NSNumber*)callId
        resolver:(RCTPromiseResolveBlock)resolve
        rejecter:(RCTPromiseRejectBlock)reject) {

    NSString *writerKey = [NSString stringWithFormat:@"writer_%@", callId];
    GRXMutableWriter *writer = [calls objectForKey:writerKey];

    if (writer != nil) {
        [writer writesFinishedWithError:nil];
        resolve([NSNumber numberWithBool:true]);
    } else {
        resolve([NSNumber numberWithBool:false]);
    }
}

RCT_EXPORT_METHOD(cancelGrpcCall:
    (nonnull NSNumber*)callId
        resolver:(RCTPromiseResolveBlock)resolve
        rejecter:(RCTPromiseRejectBlock)reject) {

    ProtoRPC *rpc = [calls objectForKey:callId];

    if (rpc != nil) {
        [rpc cancel];
        [calls removeObjectForKey:callId];

        NSString *writerKey = [NSString stringWithFormat:@"writer_%@", callId];
        [calls removeObjectForKey:writerKey];

        resolve([NSNumber numberWithBool:true]);
    } else {
        resolve([NSNumber numberWithBool:false]);
    }
}

- (ProtoRPC *)createProtoRpcWithId:(NSNumber *)callId
                              path:(NSString *)path
                           headers:(NSDictionary *)headers
                       requestData:(NSData *)requestData {

    id<GRXWriter> requestWriter = [GRXWriter writerWithValue:requestData];

    return [self createProtoRpcWithId:callId path:path headers:headers requestWriter:requestWriter];
}

- (ProtoRPC *)createProtoRpcWithId:(NSNumber *)callId
                              path:(NSString *)path
                           headers:(NSDictionary *)headers
                      requestWriter:(id<GRXWriter>)requestWriter {

    NSMutableDictionary *mutableHeaders = [[NSMutableDictionary alloc] initWithDictionary:headers];

    if (![mutableHeaders objectForKey:@"content-type"]) {
        [mutableHeaders setObject:@"application/grpc+proto" forKey:@"content-type"];
    }

    ProtoRPC *rpc = [[ProtoRPC alloc] initWithHost:self.grpcHost
                                              path:path
                                      requestsWriter:requestWriter];

    rpc.responseMessageClass = [NSData class];
    rpc.requestDispatchQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    if (self.grpcResponseSizeLimit != nil) {
        rpc.responseSizeLimit = self.grpcResponseSizeLimit.unsignedLongValue;
    }

    id<GRXWriteable> responseSink = [self createWriteableForCallId:callId];
    [rpc startWithWriteable:responseSink];

    return rpc;
}

- (id<GRXWriteable>)createWriteableForCallId:(NSNumber *)callId {
    return [[GRXWriteable alloc] initWithValueHandler:^(id value) {
        if (self->hasListeners) {
            NSData *data = (NSData *)value;
            NSDictionary *event = @{
                @"id": callId,
                @"type": @"response",
                @"payload": [data base64EncodedStringWithOptions:0],
            };
            [self sendEventWithName:@"grpc-call" body:event];
        }
    } completionHandler:^(NSError *error) {
        [self->calls removeObjectForKey:callId];
        NSString *writerKey = [NSString stringWithFormat:@"writer_%@", callId];
        [self->calls removeObjectForKey:writerKey];

        if (self->hasListeners) {
            if (error != nil) {
                NSDictionary *event = @{
                    @"id": callId,
                    @"type": @"error",
                    @"error": error.localizedDescription,
                    @"code": [NSNumber numberWithLong:error.code],
                };
                [self sendEventWithName:@"grpc-call" body:event];
            } else {
                NSDictionary *event = @{
                    @"id": callId,
                    @"type": @"complete",
                };
                [self sendEventWithName:@"grpc-call" body:event];
            }
        }
    }];
}

RCT_EXPORT_MODULE()

@end
