#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NanogramVaultOutcome) {
    NanogramVaultOutcomeOK = 0,
    NanogramVaultOutcomeMissing = 1,
    NanogramVaultOutcomeLocked = 2,
    NanogramVaultOutcomeKeychainUnavailable = 3,
    NanogramVaultOutcomeKeyLost = 4,
    NanogramVaultOutcomeCorrupt = 5,
    NanogramVaultOutcomeInterrupted = 6,
    NanogramVaultOutcomeUnreadable = 7,
};

typedef NS_ENUM(NSInteger, NanogramWrapKeyStatus) {
    NanogramWrapKeyStatusFound = 0,
    NanogramWrapKeyStatusNotFound = 1,
    NanogramWrapKeyStatusUnavailable = 2,
};

@protocol NanogramWrapKeyStore <NSObject>
- (NanogramWrapKeyStatus)readWrapKeyWithId:(NSString *)keyId data:(NSData * _Nullable * _Nonnull)data;
- (BOOL)writeWrapKey:(NSData *)key withId:(NSString *)keyId;
- (void)deleteWrapKeyWithId:(NSString *)keyId;
@end

@interface NanogramMemoryWrapKeyStore : NSObject <NanogramWrapKeyStore>
@property (nonatomic) BOOL unavailable;
@property (nonatomic) BOOL failWrites;
@property (nonatomic, readonly) NSArray<NSString *> *keyIds;
@end

@interface NanogramKeychainWrapKeyStore : NSObject <NanogramWrapKeyStore>
- (instancetype)initWithService:(NSString *)service accessGroup:(nullable NSString *)accessGroup;
- (BOOL)probe;
@end

@interface NanogramKeyVaultResult : NSObject
@property (nonatomic, readonly) NanogramVaultOutcome outcome;
@property (nonatomic, readonly, nullable) NSData *payload;
@property (nonatomic, readonly) BOOL migrated;
@end

@interface NanogramKeyVault : NSObject

@property (nonatomic, readonly) NSString *path;
@property (nonatomic, nullable, copy) BOOL (^faultInjector)(NSString *step);

+ (uint32_t)defaultIterations;

- (instancetype)initWithPath:(NSString *)path store:(id<NanogramWrapKeyStore>)store;
- (instancetype)initWithPath:(NSString *)path store:(id<NanogramWrapKeyStore>)store iterations:(uint32_t)iterations;

- (BOOL)fileExists;
- (BOOL)hasPasscode;
- (NanogramKeyVaultResult *)openWithPasscode:(nullable NSString *)passcode;
- (NanogramVaultOutcome)writePayload:(NSData *)payload passcode:(nullable NSString *)passcode;
- (NanogramKeyVaultResult *)resolveWithPasscode:(nullable NSString *)passcode
                                   legacyExists:(nullable BOOL (^)(void))legacyExists
                                  legacyPayload:(nullable NSData * _Nullable (^)(void))legacyPayload
                                   removeLegacy:(nullable void (^)(void))removeLegacy
                                         create:(BOOL)create;

+ (NSData *)deviceKeyPayloadInRootPath:(NSString *)rootPath store:(nullable id<NanogramWrapKeyStore>)store;
+ (NanogramKeyVaultResult *)resolvePlainKeyFileAtPath:(NSString *)legacyPath vault:(NanogramKeyVault *)vault create:(BOOL)create;

@end

NS_ASSUME_NONNULL_END
