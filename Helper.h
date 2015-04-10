//
//  Helper.h
//  Monolingual
//
//  Created by Ingmar Stein on 08.04.15.
//
//

@import Foundation;
#import "HelperRequest.h"

@protocol HelperProtocol

- (void)connectWithEndpointReply:(void(^)(NSXPCListenerEndpoint * endpoint))reply;
- (void)getVersionWithReply:(void(^)(NSString * version))reply;
- (void)uninstall;
- (void)exitWithCode:(NSNumber *)exitCode;
- (void)processRequest:(HelperRequest *)request reply:(void(^)(NSNumber *))reply;

@end

@interface Helper : NSObject <HelperProtocol>

- (NSString *)version;
- (void)run;

@end