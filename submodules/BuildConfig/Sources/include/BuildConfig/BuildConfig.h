#import <Foundation/Foundation.h>
#import <BuildConfig/NanogramKeyVault.h>

@interface DeviceSpecificEncryptionParameters : NSObject

@property (nonatomic, strong) NSData * _Nonnull key;
@property (nonatomic, strong) NSData * _Nonnull salt;

@end


@interface AppEncryptionParameters : NSObject

+(BOOL)enableKeychainWrappingWithAccessGroup:(NSString * _Nonnull)accessGroup;
+(void)setSharedWrapKeyStore:(id<NanogramWrapKeyStore> _Nullable)store;
-(id _Nonnull)initWithPath:(NSString * _Nonnull)path;
-(id _Nonnull)initWithPath:(NSString * _Nonnull)path wrapKeyStore:(id<NanogramWrapKeyStore> _Nullable)store iterations:(uint32_t)iterations;
-(void)applyPasscode:(NSString * _Nonnull)passcode;
-(BOOL)change:(NSString * _Nonnull)passcode;
-(BOOL)remove;
-(DeviceSpecificEncryptionParameters * _Nullable)decrypt;

-(NSData * _Nullable)encryptData:(NSData * _Nonnull)data;
-(NSData * _Nullable)decryptData:(NSData * _Nonnull)data;
-(BOOL)hasPasscode;
/// YES when a key vault exists but the Keychain could not be reached. Not a passcode problem: the caller must offer Retry, never a passcode prompt or logout.
-(BOOL)keychainUnavailable;
@end

@interface LocalPrivateKey : NSObject {
    SecKeyRef _privateKey;
    SecKeyRef _publicKey;
}
+ (NSString * _Nonnull)defaultKey;
- (NSData * _Nullable)encrypt:(NSData * _Nonnull)data;
- (NSData * _Nullable)decrypt:(NSData * _Nonnull)data cancelled:(bool *)cancelled;

@end

@interface BuildConfig : NSObject

+ (DeviceSpecificEncryptionParameters * _Nonnull)deviceSpecificEncryptionParameters:(NSString * _Nonnull)rootPath baseAppBundleId:(NSString * _Nonnull)baseAppBundleId;

+ (LocalPrivateKey * _Nullable)createApplicationSecretKey;

@end
