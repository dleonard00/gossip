//
//  GSAccount.m
//  Gossip
//
//  Created by Chakrit Wichian on 7/6/12.
//

#import "GSAccount.h"
#import "GSAccount+Private.h"
#import "GSCall.h"
#import "GSDispatch.h"
#import "GSUserAgent.h"
// #import "PJSIP.h"
#import "Util.h"

void NSString2PjStr(pj_str_t *p, NSString* text)
{
    char *buf = (char *)malloc(128 * sizeof(char));
    p->ptr = buf;
    p->slen = 0;
    pj_bzero(buf, sizeof(buf));
    pj_strcpy2(p, text.UTF8String);
    p->ptr[p->slen] = '\0';
}

static pjsip_transport *acc_transport;

@implementation GSAccount {
    long *_desc;
    NSDictionary *connectDict;
    
    GSAccountConfiguration *_config;
    NSDate *_registrationExpiration;
    BOOL isChangingIP;
    int transportReferenceCount;
}

- (id)init {
    if (self = [super init]) {
        _accountId = PJSUA_INVALID_ID;
        _status = GSAccountStatusOffline;
        _registrationExpiration = nil;
        _config = nil;
        
        isChangingIP = NO;
        _delegate = nil;
        _desc = malloc(sizeof(long)*PJ_THREAD_DESC_SIZE);
        transportReferenceCount = 0;
        
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(didReceiveIncomingCall:)
                       name:GSSIPIncomingCallNotification
                     object:[GSDispatch class]];
        [center addObserver:self
                   selector:@selector(registrationDidStart:)
                       name:GSSIPRegistrationDidStartNotification
                     object:[GSDispatch class]];
        [center addObserver:self
                   selector:@selector(registrationStateDidChange:)
                       name:GSSIPRegistrationStateDidChangeNotification
                     object:[GSDispatch class]];
        [center addObserver:self
                   selector:@selector(transportStateDidChange:)
                       name:GSSIPTransportStateDidChangeNotification
                     object:[GSDispatch class]];
    }
    return self;
}

- (void)dealloc {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self];
    
    GSUserAgent *agent = [GSUserAgent sharedAgent];
    if (_accountId != PJSUA_INVALID_ID && [agent status] != GSUserAgentStateDestroyed) {
        GSLogIfFails(pjsua_acc_del(_accountId));
        _accountId = PJSUA_INVALID_ID;
    }
    
    _accountId = PJSUA_INVALID_ID;
    _config = nil;
}


- (GSAccountConfiguration *)configuration {
    return _config;
}

- (NSDate*)registrationExpiration{
    return _registrationExpiration;
}

- (BOOL)configure:(GSAccountConfiguration *)configuration {
    //_config = [configuration copy];
    _config = configuration;
    
    // prepare account config
    pjsua_acc_config accConfig;
    pjsua_acc_config_default(&accConfig);
    
    accConfig.id = [GSPJUtil PJAddressWithString:_config.address];
    
    if ([GSUserAgent sharedAgent].config.transportType == GSTCPTransportType) {
        accConfig.reg_uri = [GSPJUtil PJAddressWithString:[_config.domain stringByAppendingString:@";transport=tcp"]];
    } else {
        accConfig.reg_uri = [GSPJUtil PJAddressWithString:_config.domain];
    }
    accConfig.register_on_acc_add = PJ_FALSE; // connect manually
    accConfig.publish_enabled = _config.enableStatusPublishing ? PJ_TRUE : PJ_FALSE;
    
    if (!_config.proxyServer) {
        accConfig.proxy_cnt = 0;
    } else {
        accConfig.proxy_cnt = 1;
        accConfig.proxy[0] = [GSPJUtil PJAddressWithString:_config.proxyServer];
    }
    
    // adds credentials info
    pjsip_cred_info creds;
    creds.scheme = [GSPJUtil PJStringWithString:_config.authScheme];
    creds.realm = [GSPJUtil PJStringWithString:_config.authRealm];
    creds.username = [GSPJUtil PJStringWithString:_config.username];
    creds.data = [GSPJUtil PJStringWithString:_config.password];
    creds.data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    
    accConfig.cred_count = 1;
    accConfig.cred_info[0] = creds;
    accConfig.reg_timeout = [configuration.registrationTimeout intValue];
    
    // finish
    GSReturnNoIfFails(pjsua_acc_add(&accConfig, PJ_TRUE, &_accountId));
    return YES;
}

static const NSString *keyAccount = @"account";
static const NSString *keyBlock = @"block";

#define GS_BLOCK_SAFE_RUN(block, ...) { if (block) (block)(__VA_ARGS__); }
#define GS_BLOCK_SAFE_RUN_MAINTHREAD(block, ...) { dispatch_async(dispatch_get_main_queue(), ^(void) { if (block) (block)(__VA_ARGS__); }); }

- (void)connectWithCompletion:(void (^)(BOOL success))block {
    NSAssert(!!_config, @"GSAccount not configured.");
    
    // Spawn new thread for SIP connection. Because doing so in main thread may cause 10 sec
    // freeze when waiting for server response. All the work below is just to prepare
    // for `pj_thread_register()`.
    pj_caching_pool cach_pool;
    pj_caching_pool_init(&cach_pool, &pj_pool_factory_default_policy, 0);
    pj_pool_factory *mem = &cach_pool.factory;
    pj_pool_t *pool = pj_pool_create(mem, NULL, 4000, 4000, NULL);
    if (pool == NULL) {
        NSLog(@"failed creating a caching pool for thread");
        GS_BLOCK_SAFE_RUN(block, NO);
    }
    
    pj_thread_t *thread;
    const char *thread_name = "fingi_sip_thread";
    
    // WARNING!! connectDict needs to be retained during the function execution, else it will
    // crash when running on device!!! Also setting a dictionary key with nill will crash.
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSNumber *numAccId = @(_accountId);
    if (numAccId) m[keyAccount] = numAccId;
    if (block) m[keyBlock] = block;
    
    connectDict = [NSDictionary dictionaryWithDictionary:m];
    pj_status_t status_create = pj_thread_create(pool, thread_name,
                                                 (pj_thread_proc*)&connectInBackground,
                                                 (__bridge void *)(connectDict),
                                                 PJ_THREAD_DEFAULT_STACK_SIZE,
                                                 0, &thread);
    if (status_create != PJ_SUCCESS) {
        NSLog(@"failed creating thread");
        GS_BLOCK_SAFE_RUN(block, NO);
    }
    
    // execute `-connectInBackground:`
    pj_status_t status_reg = pj_thread_register(thread_name, _desc, &thread);
    if (status_reg != PJ_SUCCESS) {
        NSLog(@"failed registering thread");
        GS_BLOCK_SAFE_RUN(block, NO);
    }
    
    NSLog(@"background thread registered");
    
    /*
     // this may freeze main thread
     GSReturnNoIfFails(pjsua_acc_set_registration(_accountId, PJ_TRUE));
     GSReturnNoIfFails(pjsua_acc_set_online_status(_accountId, PJ_TRUE));
     return YES;
     */
}

// NOTE: cannot use `self` in here
// NOTE2: block callbacks need to be run on main thread
static void connectInBackground(NSDictionary *dict) {
    if ([dict isKindOfClass:[NSDictionary class]] == NO) {
        NSLog(@"dict is missing");
        return;
    }
    
    int accId = [dict[keyAccount] intValue];
    void (^block)(BOOL success) = dict[keyBlock];
    
    pj_status_t status_reg = pjsua_acc_set_registration(accId, PJ_TRUE);
    if (status_reg != PJ_SUCCESS) {
        GS_BLOCK_SAFE_RUN_MAINTHREAD(block, NO);
        return;
    }
    pj_status_t status_online = pjsua_acc_set_online_status(accId, PJ_TRUE);
    if (status_online != PJ_SUCCESS) {
        GS_BLOCK_SAFE_RUN_MAINTHREAD(block, NO);
        return;
    }
    
    pjsua_acc_info info;
    pjsua_acc_get_info(accId, &info);
    
    while (info.status == PJSIP_SC_TRYING) {
        //        NSLog(@"Status: %u", info.status);
        pjsua_acc_get_info(accId, &info);
    }
    
    if (info.status == PJSIP_SC_OK || info.status == PJSIP_SC_ACCEPTED) {
        GS_BLOCK_SAFE_RUN_MAINTHREAD(block, YES);
    } else {
        GS_BLOCK_SAFE_RUN_MAINTHREAD(block, NO);
    }
}

- (BOOL)disconnect {
    NSAssert(!!_config, @"GSAccount not configured.");
    
    GSReturnNoIfFails(pjsua_acc_set_online_status(_accountId, PJ_FALSE));
    GSReturnNoIfFails(pjsua_acc_set_registration(_accountId, PJ_FALSE));
    return YES;
}

- (void)disconnectWithCompletion:(void (^)(BOOL success))block {
    NSAssert(!!_config, @"GSAccount not configured.");
    
    // Spawn new thread for SIP connection. Because doing so in main thread may cause 10 sec
    // freeze when waiting for server response. All the work below is just to prepare
    // for `pj_thread_register()`.
    pj_caching_pool cach_pool;
    pj_caching_pool_init(&cach_pool, &pj_pool_factory_default_policy, 0);
    pj_pool_factory *mem = &cach_pool.factory;
    pj_pool_t *pool = pj_pool_create(mem, NULL, 4000, 4000, NULL);
    if (pool == NULL) {
        NSLog(@"failed creating a caching pool for thread");
        GS_BLOCK_SAFE_RUN(block, NO);
    }
    
    pj_thread_t *thread;
    const char *thread_name = "fingi_sip_thread";
    
    // WARNING!! connectDict needs to be retained during the function execution, else it will
    // crash when running on device!!! Also setting a dictionary key with nill will crash.
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    NSNumber *numAccId = @(_accountId);
    if (numAccId) m[keyAccount] = numAccId;
    if (block) m[keyBlock] = block;
    
    connectDict = [NSDictionary dictionaryWithDictionary:m];
    pj_status_t status_create = pj_thread_create(pool, thread_name,
                                                 (pj_thread_proc*)&disconnectInBackground,
                                                 (__bridge void *)(connectDict),
                                                 PJ_THREAD_DEFAULT_STACK_SIZE,
                                                 0, &thread);
    if (status_create != PJ_SUCCESS) {
        NSLog(@"failed creating thread");
        GS_BLOCK_SAFE_RUN(block, NO);
    }
    
    // execute `-connectInBackground:`
    pj_status_t status_reg = pj_thread_register(thread_name, _desc, &thread);
    if (status_reg != PJ_SUCCESS) {
        NSLog(@"failed registering thread");
        GS_BLOCK_SAFE_RUN(block, NO);
    }
    
    NSLog(@"background thread registered");
    
    /*
     // this may freeze main thread
     GSReturnNoIfFails(pjsua_acc_set_registration(_accountId, PJ_TRUE));
     GSReturnNoIfFails(pjsua_acc_set_online_status(_accountId, PJ_TRUE));
     return YES;
     */
}

// NOTE: cannot use `self` in here
// NOTE2: block callbacks need to be run on main thread
static void disconnectInBackground(NSDictionary *dict) {
    if ([dict isKindOfClass:[NSDictionary class]] == NO) {
        NSLog(@"dict is missing");
        return;
    }
    
    int accId = [dict[keyAccount] intValue];
    void (^block)(BOOL success) = dict[keyBlock];
    
    pj_status_t status_reg = pjsua_acc_set_registration(accId, PJ_FALSE);
    if (status_reg != PJ_SUCCESS) {
        GS_BLOCK_SAFE_RUN_MAINTHREAD(block, NO);
        return;
    }
    pj_status_t status_online = pjsua_acc_set_online_status(accId, PJ_FALSE);
    if (status_online != PJ_SUCCESS) {
        GS_BLOCK_SAFE_RUN_MAINTHREAD(block, NO);
        return;
    }
    GS_BLOCK_SAFE_RUN_MAINTHREAD(block, YES);
}

- (void)startKeepAlive{
    pjsua_acc_set_online_status(_accountId, PJ_TRUE);
    
}

-(void)performKeepAlive{
    pj_thread_sleep(5000);
}


- (void)setStatus:(GSAccountStatus)newStatus {
    if (_status == newStatus) // don't send KVO notices unless it really changes.
        return;
    
    _status = newStatus;
}


- (void)didReceiveIncomingCall:(NSNotification *)notif {
    pjsua_acc_id accountId = GSNotifGetInt(notif, GSSIPAccountIdKey);
    pjsua_call_id callId = GSNotifGetInt(notif, GSSIPCallIdKey);
    pjsip_rx_data * data = GSNotifGetPointer(notif, GSSIPDataKey);
    
    if (accountId == PJSUA_INVALID_ID || accountId != _accountId)
        return;
    
    __block GSAccount *self_ = self;
    __block id delegate_ = _delegate;
    dispatch_async(dispatch_get_main_queue(), ^{
        GSCall *call = [GSCall incomingCallWithId:callId toAccount:self];
        if (![delegate_ respondsToSelector:@selector(account:didReceiveIncomingCall:withMessage:)])
            return; // call is disposed/hungup on dealloc
        NSString *msgString = nil;
        if (data->msg_info.msg_buf) {
            msgString = [NSString stringWithUTF8String:data->msg_info.msg_buf];
        }
        [delegate_ account:self didReceiveIncomingCall:call withMessage:msgString];
    });
}

- (void)registrationDidStart:(NSNotification *)notif {
    pjsua_acc_id accountId = GSNotifGetInt(notif, GSSIPAccountIdKey);
    pj_bool_t renew = GSNotifGetBool(notif, GSSIPRenewKey);
    if (accountId == PJSUA_INVALID_ID || accountId != _accountId)
        return;
    
    GSAccountStatus accStatus = 0;
    accStatus = renew ? GSAccountStatusConnecting : GSAccountStatusDisconnecting;
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setStatus:accStatus]; });
}

- (void)registrationStateDidChange:(NSNotification *)notif {
    pjsua_acc_id accountId = GSNotifGetInt(notif, GSSIPAccountIdKey);
    pjsua_reg_info * regInfo = GSNotifGetPointer(notif, GSSIPRegInfoKey);
    struct pjsip_regc_cbparam *rp = regInfo->cbparam;
    
    if (accountId == PJSUA_INVALID_ID || accountId != _accountId)
        return;
    
    GSAccountStatus accStatus;
    
    pjsua_acc_info info;
    GSReturnIfFails(pjsua_acc_get_info(accountId, &info));
    
    if (info.reg_last_err != PJ_SUCCESS) {
        accStatus = GSAccountStatusInvalid;
        
    } else {
        pjsip_status_code code = info.status;
        if (code == 0 || (info.online_status == PJ_FALSE)) {
            accStatus = GSAccountStatusOffline;
            if (isChangingIP) {
                isChangingIP = NO;
                dispatch_after(1, dispatch_get_main_queue(), ^{
                    [self connectWithCompletion:nil];
                });
            }
        } else if (PJSIP_IS_STATUS_IN_CLASS(code, 100) || PJSIP_IS_STATUS_IN_CLASS(code, 300)) {
            accStatus = GSAccountStatusConnecting;
        } else if (PJSIP_IS_STATUS_IN_CLASS(code, 200)) {
            accStatus = GSAccountStatusConnected;
            
        } else {
            if (code == 408) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self connectWithCompletion:nil];
                });
            }
            accStatus = GSAccountStatusInvalid;
        }
    }
    
    if (rp->code/100 == 2 && rp->expiration > 0 && rp->contact_cnt > 0) {
        /* Registration success */
        if (acc_transport) {
            // Prevent crash when log out and login in new account
            // pjsip_transport_dec_ref(acc_transport);
            acc_transport = NULL;
        }
        /* Save transport instance so that we can close it later when
         * new IP address is detected.
         */
        _registrationExpiration = [NSDate dateWithTimeIntervalSinceNow:rp->expiration];
        acc_transport = rp->rdata->tp_info.transport;
        pjsip_transport_add_ref(acc_transport);
    } else {
        if (acc_transport) {
            pjsip_transport_dec_ref(acc_transport);
            acc_transport = NULL;
        }
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setStatus:accStatus]; });
}

- (BOOL)sendMessage:(NSString*)message toFriend:(GSAccountConfiguration *)friend;
{
    pj_str_t tmp_uri = [GSPJUtil PJStringWithString:[NSString stringWithFormat:@"sip:%@", friend.address]];
    pj_str_t tmp_content = [GSPJUtil PJStringWithString:[NSString stringWithFormat:@"sip:%@", friend.address]];
    return  (PJ_SUCCESS == pjsua_im_send(pjsua_acc_get_default(), &tmp_uri, NULL, &tmp_content, NULL, NULL));
}

- (BOOL)handleIPChange{
    
    if (self.status == GSAccountStatusOffline) {
        return NO;
    }
    
    pj_status_t status;
    
    if (acc_transport) {
        status = pjsip_transport_shutdown(acc_transport);
        if (status != PJ_SUCCESS){
            return NO;
        }
        pjsip_transport_dec_ref(acc_transport);
        acc_transport = NULL;
    }
    
    isChangingIP = YES;
    
    BOOL success = [self disconnect];
    
    if (!success){
        isChangingIP = NO;
        return NO;
    }
    
    return YES;
    
}

- (void)transportStateDidChange:(NSNotification *)notif {
    pjsip_transport_state state = GSNotifGetInt(notif, GSSIPTransportStateKey);
    pjsip_transport *tp = GSNotifGetPointer(notif, GSSIPTransportKey);
    
    if (state == PJSIP_TP_STATE_DISCONNECTED && acc_transport == tp) {
        pjsip_transport_dec_ref(acc_transport);
        acc_transport = NULL;
    }
}

@end
