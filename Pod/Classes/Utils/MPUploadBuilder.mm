//
//  MPUploadBuilder.mm
//  mParticle
//
//  Created by Dalmo Cirne on 5/7/15.
//  Copyright (c) 2015 mParticle. All rights reserved.
//

#import "MPUploadBuilder.h"
#include <vector>
#import "MPMessage.h"
#import "MPSession.h"
#import "MPUpload.h"
#import "MPStateMachine.h"
#import "MPConstants.h"
#import "NSUserDefaults+mParticle.h"
#import "MPPersistenceController.h"
#import "MPCustomModule.h"
#import "MPStandaloneUpload.h"
#import "MPConsumerInfo.h"
#import "MPApplication.h"
#import "MPDevice.h"
#import "MPBags.h"
#import "MPBags+Internal.h"
#import "MPForwardRecord.h"

using namespace std;

@interface MPUploadBuilder() {
    NSMutableDictionary *uploadDictionary;
}

@end

@implementation MPUploadBuilder

- (instancetype)initWithSession:(MPSession *)session messages:(NSArray *)messages sessionTimeout:(NSTimeInterval)sessionTimeout uploadInterval:(NSTimeInterval)uploadInterval {
    NSAssert(messages, @"Messages cannot be nil.");
    
    self = [super init];
    if (!self || !messages) {
        return nil;
    }
    
    _session = session;
    
    NSUInteger numberOfMessages = messages.count;
    NSMutableArray *messageDictionariess = [[NSMutableArray alloc] initWithCapacity:numberOfMessages];
    
    __block vector<int64_t> prepMessageIds;
    prepMessageIds.reserve(numberOfMessages);
    
    for (NSUInteger i = 0; i < numberOfMessages; ++i) {
        [messageDictionariess addObject:[NSNull null]];
    }
    
    [messages enumerateObjectsWithOptions:NSEnumerationConcurrent
                               usingBlock:^(MPMessage *message, NSUInteger idx, BOOL *stop) {
                                   prepMessageIds[idx] = message.messageId;
                                   messageDictionariess[idx] = [message dictionaryRepresentation];
                               }];
    
    _preparedMessageIds = [[NSMutableArray alloc] initWithCapacity:numberOfMessages];
    for (NSUInteger i = 0; i < numberOfMessages; ++i) {
        [_preparedMessageIds addObject:@(prepMessageIds[i])];
    }
    
    NSNumber *ltv;
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    ltv = userDefaults[kMPLifeTimeValueKey];
    if (!ltv) {
        ltv = @0;
    }
    
    MPStateMachine *stateMachine = [MPStateMachine sharedInstance];
    
    uploadDictionary = [@{kMPOptOutKey:@(stateMachine.optOut),
                          kMPUploadIntervalKey:@(uploadInterval),
                          kMPLifeTimeValueKey:ltv}
                        mutableCopy];

    if (messageDictionariess) {
        uploadDictionary[kMPMessagesKey] = messageDictionariess;
    }

    if (sessionTimeout > 0) {
        uploadDictionary[kMPSessionTimeoutKey] = @(sessionTimeout);
    }
    
    if (stateMachine.customModules) {
        NSMutableDictionary *customModulesDictionary = [[NSMutableDictionary alloc] initWithCapacity:stateMachine.customModules.count];
        
        for (MPCustomModule *customModule in stateMachine.customModules) {
            customModulesDictionary[[customModule.customModuleId stringValue]] = [customModule dictionaryRepresentation];
        }
        
        uploadDictionary[kMPRemoteConfigCustomModuleSettingsKey] = customModulesDictionary;
    }
    
    uploadDictionary[kMPRemoteConfigMPIDKey] = stateMachine.consumerInfo.mpId;
    
    return self;
}

- (NSString *)description {
    NSString *description;
    
    if (_session) {
        description = [NSString stringWithFormat:@"MPUploadBuilder\n Session Id: %lld\n UploadDictionary: %@", self.session.sessionId, uploadDictionary];
    } else {
        description = [NSString stringWithFormat:@"MPUploadBuilder\n UploadDictionary: %@", uploadDictionary];
    }
    
    return description;
}

#pragma mark Public class methods
+ (MPUploadBuilder *)newBuilderWithMessages:(NSArray *)messages uploadInterval:(NSTimeInterval)uploadInterval {
    MPUploadBuilder *uploadBuilder = [[MPUploadBuilder alloc] initWithSession:nil messages:messages sessionTimeout:0 uploadInterval:uploadInterval];
    return uploadBuilder;
}

+ (MPUploadBuilder *)newBuilderWithSession:(MPSession *)session messages:(NSArray *)messages sessionTimeout:(NSTimeInterval)sessionTimeout uploadInterval:(NSTimeInterval)uploadInterval {
    MPUploadBuilder *uploadBuilder = [[MPUploadBuilder alloc] initWithSession:session messages:messages sessionTimeout:sessionTimeout uploadInterval:uploadInterval];
    return uploadBuilder;
}

#pragma mark Public instance methods
- (void)build:(void (^)(MPDataModelAbstract *upload))completionHandler {
    uploadDictionary[kMPMessageTypeKey] = kMPMessageTypeRequestHeader;
    uploadDictionary[kMPmParticleSDKVersionKey] = kMParticleSDKVersion;
    uploadDictionary[kMPMessageIdKey] = [[NSUUID UUID] UUIDString];
    uploadDictionary[kMPTimestampKey] = MPMilliseconds([[NSDate date] timeIntervalSince1970]);

    MPApplication *application = [[MPApplication alloc] init];
    uploadDictionary[kMPApplicationInformationKey] = [application dictionaryRepresentation];
    
    MPDevice *device = [[MPDevice alloc] init];
    uploadDictionary[kMPDeviceInformationKey] = [device dictionaryRepresentation];
    
    MPStateMachine *stateMachine = [MPStateMachine sharedInstance];
    
    NSDictionary *cookies = [stateMachine.consumerInfo cookiesDictionaryRepresentation];
    if (cookies) {
        uploadDictionary[kMPRemoteConfigCookiesKey] = cookies;
    }

    NSDictionary *productBags = [stateMachine.bags dictionaryRepresentation];
    if (productBags) {
        uploadDictionary[kMPProductBagKey] = productBags;
    }
    
    MPPersistenceController *persistence = [MPPersistenceController sharedInstance];
    NSArray  *forwardRecords = [persistence fetchForwardRecords];
    NSMutableArray *forwardRecordsIds = nil;
    
    if (forwardRecords) {
        NSUInteger numberOfRecords = forwardRecords.count;
        NSMutableArray *fsr = [[NSMutableArray alloc] initWithCapacity:numberOfRecords];
        forwardRecordsIds = [[NSMutableArray alloc] initWithCapacity:numberOfRecords];
        
        for (MPForwardRecord *forwardRecord in forwardRecords) {
            if (forwardRecord.dataDictionary) {
                [fsr addObject:forwardRecord.dataDictionary];
                [forwardRecordsIds addObject:@(forwardRecord.forwardRecordId)];
            }
        }
        
        if (fsr.count > 0) {
            uploadDictionary[kMPForwardStatsRecord] = fsr;
        }
    }
    
#ifdef SERVER_ECHO
    uploadDictionary[@"echo"] = @true;
#endif

    if (_session) { // MPUpload
        [persistence fetchUserNotificationCampaignHistory:^(NSArray *userNotificationCampaignHistory) {
            if (userNotificationCampaignHistory) {
                NSMutableDictionary *userNotificationCampaignHistoryDictionary = [[NSMutableDictionary alloc] initWithCapacity:userNotificationCampaignHistory.count];
                
                for (MParticleUserNotification *userNotification in userNotificationCampaignHistory) {
                    if (userNotification.campaignId && userNotification.contentId) {
                        userNotificationCampaignHistoryDictionary[[userNotification.campaignId stringValue]] = @{kMPRemoteNotificationContentIdHistoryKey:userNotification.contentId,
                                                                                                                 kMPRemoteNotificationTimestampHistoryKey:MPMilliseconds([userNotification.receiptTime timeIntervalSince1970])};
                    }
                }
                
                if (userNotificationCampaignHistoryDictionary.count > 0) {
                    uploadDictionary[kMPRemoteNotificationCampaignHistoryKey] = userNotificationCampaignHistoryDictionary;
                }
            }
            
            MPUpload *upload = [[MPUpload alloc] initWithSession:_session uploadDictionary:uploadDictionary];
            
            completionHandler(upload);
            
            if (forwardRecordsIds.count > 0) {
                [persistence deleteForwardRecodsIds:forwardRecordsIds];
            }
        }];
    } else { // MPStandaloneUpload
        MPStandaloneUpload *standaloneUpload = [[MPStandaloneUpload alloc] initWithUploadDictionary:uploadDictionary];
        
        completionHandler(standaloneUpload);
    }
}

- (MPUploadBuilder *)withUserAttributes:(NSDictionary *)userAttributes deletedUserAttributes:(NSSet *)deletedUserAttributes {
    NSUInteger numberOfUserAttributes = userAttributes.count;
    
    if (numberOfUserAttributes > 0) {
        NSMutableDictionary *attributesDictionary = [[NSMutableDictionary alloc] initWithCapacity:numberOfUserAttributes];
        NSEnumerator *attributeEnumerator = [userAttributes keyEnumerator];
        NSString *key;
        id value;
        Class NSNumberClass = [NSNumber class];
        
        while ((key = [attributeEnumerator nextObject])) {
            value = userAttributes[key];
            attributesDictionary[key] = [value isKindOfClass:NSNumberClass] ? [(NSNumber *)value stringValue] : value;
        }
        
        uploadDictionary[kMPUserAttributeKey] = attributesDictionary;
    }
    
    if (deletedUserAttributes && _session) {
        uploadDictionary[kMPUserAttributeDeletedKey] = [deletedUserAttributes allObjects];
    }
    
    return self;
}

- (MPUploadBuilder *)withUserIdentities:(NSArray *)userIdentities {
    if (userIdentities.count > 0) {
        uploadDictionary[kMPUserIdentityArrayKey] = userIdentities;
    }
    
    return self;
}

@end