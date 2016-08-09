//
//  GSOutgoingCall.h
//  Gossip
//
//  Created by Chakrit Wichian on 7/12/12.
//

#import "GSCall.h"


@interface GSOutgoingCall : GSCall

@property (nonatomic, copy, readonly) NSString *remoteUri;

- (instancetype)initWithRemoteUri:(NSString *)remoteUri
            fromAccount:(GSAccount *)account;

@end
