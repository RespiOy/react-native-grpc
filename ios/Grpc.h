#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface Grpc : RCTEventEmitter <RCTBridgeModule>

@property (nonatomic, copy, nullable) NSString *grpcHost;

@property (nonatomic, copy, nullable) NSNumber *grpcResponseSizeLimit;

@property (nonatomic, assign) BOOL grpcInsecure;

@end
