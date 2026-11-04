#import <BuildConfig/NanogramKeyVault.h>

#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <Security/Security.h>

#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

static const uint8_t kVaultMagic[4] = {'N', 'G', 'K', 'V'};
static const uint8_t kVaultVersion = 1;
static const uint8_t kVaultFlagPasscode = 1;
static const NSUInteger kKeyIdLength = 16;
static const NSUInteger kSaltLength = 16;
static const NSUInteger kIVLength = 16;
static const NSUInteger kTagLength = 32;
static const NSUInteger kHeaderLength = 4 + 1 + 1 + kKeyIdLength + kSaltLength + 4;
static const NSUInteger kPayloadLength = 48;

static NSData *RandomData(NSUInteger length) {
    NSMutableData *data = [[NSMutableData alloc] initWithLength:length];
    if (SecRandomCopyBytes(kSecRandomDefault, length, data.mutableBytes) != errSecSuccess) {
        arc4random_buf(data.mutableBytes, length);
    }
    return data;
}

static NSData *HMACSHA256(NSData *key, NSData *message) {
    NSMutableData *mac = [[NSMutableData alloc] initWithLength:CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, mac.mutableBytes);
    return mac;
}

static BOOL ConstantTimeEqual(NSData *a, NSData *b) {
    if (a.length != b.length) {
        return NO;
    }
    const uint8_t *x = a.bytes;
    const uint8_t *y = b.bytes;
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < a.length; i++) {
        difference |= x[i] ^ y[i];
    }
    return difference == 0;
}

static NSString *HexString(NSData *data) {
    NSMutableString *result = [[NSMutableString alloc] initWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [result appendFormat:@"%02x", bytes[i]];
    }
    return result;
}

static NSData *AESCBC(BOOL encrypt, NSData *key, NSData *iv, NSData *input) {
    size_t capacity = input.length + kCCBlockSizeAES128;
    NSMutableData *output = [[NSMutableData alloc] initWithLength:capacity];
    size_t produced = 0;
    CCCryptorStatus status = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, key.length, iv.bytes, input.bytes, input.length, output.mutableBytes, capacity, &produced);
    if (status != kCCSuccess) {
        return nil;
    }
    output.length = produced;
    return output;
}

@implementation NanogramMemoryWrapKeyStore {
    NSMutableDictionary<NSString *, NSData *> *_items;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _items = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (NSArray<NSString *> *)keyIds {
    @synchronized (self) {
        return [_items.allKeys sortedArrayUsingSelector:@selector(compare:)];
    }
}

- (NanogramWrapKeyStatus)readWrapKeyWithId:(NSString *)keyId data:(NSData * _Nullable *)data {
    @synchronized (self) {
        if (self.unavailable) {
            return NanogramWrapKeyStatusUnavailable;
        }
        NSData *value = _items[keyId];
        if (value == nil) {
            return NanogramWrapKeyStatusNotFound;
        }
        *data = value;
        return NanogramWrapKeyStatusFound;
    }
}

- (BOOL)writeWrapKey:(NSData *)key withId:(NSString *)keyId {
    @synchronized (self) {
        if (self.unavailable || self.failWrites) {
            return NO;
        }
        _items[keyId] = [key copy];
        return YES;
    }
}

- (void)deleteWrapKeyWithId:(NSString *)keyId {
    @synchronized (self) {
        [_items removeObjectForKey:keyId];
    }
}

@end

@implementation NanogramKeychainWrapKeyStore {
    NSString *_service;
    NSString *_accessGroup;
}

- (instancetype)initWithService:(NSString *)service accessGroup:(NSString *)accessGroup {
    self = [super init];
    if (self != nil) {
        _service = [service copy];
        _accessGroup = [accessGroup copy];
    }
    return self;
}

- (NSMutableDictionary *)baseQueryForKeyId:(NSString *)keyId {
    NSMutableDictionary *query = [@{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: _service,
        (id)kSecAttrAccount: keyId,
        (id)kSecAttrSynchronizable: @NO,
    } mutableCopy];
    if (_accessGroup.length != 0) {
        query[(id)kSecAttrAccessGroup] = _accessGroup;
    }
#if TARGET_OS_OSX
    query[(id)kSecUseDataProtectionKeychain] = @YES;
#endif
    return query;
}

- (NanogramWrapKeyStatus)readWrapKeyWithId:(NSString *)keyId data:(NSData * _Nullable *)data {
    NSMutableDictionary *query = [self baseQueryForKeyId:keyId];
    query[(id)kSecReturnData] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result != NULL) {
        NSData *value = CFBridgingRelease(result);
        if (value.length == 0) {
            return NanogramWrapKeyStatusUnavailable;
        }
        *data = value;
        return NanogramWrapKeyStatusFound;
    }
    if (status == errSecItemNotFound) {
        return NanogramWrapKeyStatusNotFound;
    }
    return NanogramWrapKeyStatusUnavailable;
}

- (BOOL)writeWrapKey:(NSData *)key withId:(NSString *)keyId {
    NSMutableDictionary *add = [self baseQueryForKeyId:keyId];
    add[(id)kSecValueData] = key;
    add[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status == errSecDuplicateItem) {
        NSDictionary *update = @{
            (id)kSecValueData: key,
            (id)kSecAttrAccessible: (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        };
        status = SecItemUpdate((__bridge CFDictionaryRef)[self baseQueryForKeyId:keyId], (__bridge CFDictionaryRef)update);
    }
    return status == errSecSuccess;
}

- (void)deleteWrapKeyWithId:(NSString *)keyId {
    SecItemDelete((__bridge CFDictionaryRef)[self baseQueryForKeyId:keyId]);
}

- (BOOL)probe {
    NSString *probeId = [@"probe-" stringByAppendingString:HexString(RandomData(8))];
    NSData *value = RandomData(32);
    if (![self writeWrapKey:value withId:probeId]) {
        return NO;
    }
    NSData *read = nil;
    NanogramWrapKeyStatus status = [self readWrapKeyWithId:probeId data:&read];
    [self deleteWrapKeyWithId:probeId];
    return status == NanogramWrapKeyStatusFound && [read isEqualToData:value];
}

@end

@interface NanogramKeyVaultResult ()
- (instancetype)initWithOutcome:(NanogramVaultOutcome)outcome payload:(NSData *)payload migrated:(BOOL)migrated;
@end

@implementation NanogramKeyVaultResult

- (instancetype)initWithOutcome:(NanogramVaultOutcome)outcome payload:(NSData *)payload migrated:(BOOL)migrated {
    self = [super init];
    if (self != nil) {
        _outcome = outcome;
        _payload = payload;
        _migrated = migrated;
    }
    return self;
}

@end

static NanogramKeyVaultResult *Result(NanogramVaultOutcome outcome, NSData *payload, BOOL migrated) {
    return [[NanogramKeyVaultResult alloc] initWithOutcome:outcome payload:payload migrated:migrated];
}

typedef struct {
    BOOL valid;
    BOOL hasPasscode;
    NSData *keyId;
    NSData *salt;
    uint32_t iterations;
} VaultHeader;

static VaultHeader ParseHeader(NSData *file) {
    VaultHeader header = {NO, NO, nil, nil, 0};
    if (file.length < kHeaderLength + kIVLength + kCCBlockSizeAES128 + kTagLength) {
        return header;
    }
    const uint8_t *bytes = file.bytes;
    if (memcmp(bytes, kVaultMagic, 4) != 0 || bytes[4] != kVaultVersion) {
        return header;
    }
    if ((file.length - kHeaderLength - kIVLength - kTagLength) % kCCBlockSizeAES128 != 0) {
        return header;
    }
    header.hasPasscode = (bytes[5] & kVaultFlagPasscode) != 0;
    header.keyId = [file subdataWithRange:NSMakeRange(6, kKeyIdLength)];
    header.salt = [file subdataWithRange:NSMakeRange(6 + kKeyIdLength, kSaltLength)];
    uint32_t iterations = 0;
    [file getBytes:&iterations range:NSMakeRange(6 + kKeyIdLength + kSaltLength, 4)];
    header.iterations = CFSwapInt32BigToHost(iterations);
    header.valid = header.iterations != 0 && header.iterations <= 100000000;
    return header;
}

static NSData *MasterKey(NSData *wrapKey, NSString *passcode, NSData *salt, uint32_t iterations) {
    if (passcode == nil) {
        return wrapKey;
    }
    NSData *password = [passcode dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *derived = [[NSMutableData alloc] initWithLength:32];
    int status = CCKeyDerivationPBKDF(kCCPBKDF2, password.bytes, password.length, salt.bytes, salt.length, kCCPRFHmacAlgSHA256, iterations, derived.mutableBytes, derived.length);
    if (status != kCCSuccess) {
        return nil;
    }
    return HMACSHA256(wrapKey, derived);
}

static NSData *SubKey(NSData *master, NSString *label) {
    return HMACSHA256(master, [label dataUsingEncoding:NSUTF8StringEncoding]);
}

@implementation NanogramKeyVault {
    id<NanogramWrapKeyStore> _store;
    uint32_t _iterations;
}

+ (uint32_t)defaultIterations {
    return 600000;
}

- (instancetype)initWithPath:(NSString *)path store:(id<NanogramWrapKeyStore>)store {
    return [self initWithPath:path store:store iterations:[NanogramKeyVault defaultIterations]];
}

- (instancetype)initWithPath:(NSString *)path store:(id<NanogramWrapKeyStore>)store iterations:(uint32_t)iterations {
    self = [super init];
    if (self != nil) {
        _path = [path copy];
        _store = store;
        _iterations = iterations;
    }
    return self;
}

- (BOOL)faultAt:(NSString *)step {
    return self.faultInjector != nil && self.faultInjector(step);
}

- (NSString *)lockPath {
    return [_path stringByAppendingString:@".lock"];
}

- (void)withLock:(void (^)(void))body {
    int fd = open([[self lockPath] fileSystemRepresentation], O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR);
    BOOL locked = NO;
    if (fd >= 0) {
        for (int attempt = 0; attempt < 150; attempt++) {
            if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
                locked = YES;
                break;
            }
            if (errno != EWOULDBLOCK) {
                break;
            }
            usleep(20 * 1000);
        }
    }
    body();
    if (fd >= 0) {
        if (locked) {
            flock(fd, LOCK_UN);
        }
        close(fd);
    }
}

- (BOOL)fileExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:_path];
}

- (BOOL)hasPasscode {
    NSData *file = [NSData dataWithContentsOfFile:_path];
    if (file == nil) {
        return NO;
    }
    VaultHeader header = ParseHeader(file);
    return header.valid && header.hasPasscode;
}

- (NanogramKeyVaultResult *)openWithPasscode:(NSString *)passcode {
    NSData *file = [NSData dataWithContentsOfFile:_path];
    if (file == nil) {
        return Result([self fileExists] ? NanogramVaultOutcomeCorrupt : NanogramVaultOutcomeMissing, nil, NO);
    }
    VaultHeader header = ParseHeader(file);
    if (!header.valid) {
        return Result(NanogramVaultOutcomeCorrupt, nil, NO);
    }
    NSData *wrapKey = nil;
    NanogramWrapKeyStatus status = [_store readWrapKeyWithId:HexString(header.keyId) data:&wrapKey];
    if (status == NanogramWrapKeyStatusUnavailable) {
        return Result(NanogramVaultOutcomeKeychainUnavailable, nil, NO);
    }
    if (status == NanogramWrapKeyStatusNotFound || wrapKey.length != 32) {
        return Result(NanogramVaultOutcomeKeyLost, nil, NO);
    }
    if (header.hasPasscode && passcode == nil) {
        return Result(NanogramVaultOutcomeLocked, nil, NO);
    }
    NSData *master = MasterKey(wrapKey, header.hasPasscode ? passcode : nil, header.salt, header.iterations);
    if (master == nil) {
        return Result(NanogramVaultOutcomeLocked, nil, NO);
    }
    NSData *macKey = SubKey(master, @"nanogram.keyvault.v1.mac");
    NSData *signed_ = [file subdataWithRange:NSMakeRange(0, file.length - kTagLength)];
    NSData *tag = [file subdataWithRange:NSMakeRange(file.length - kTagLength, kTagLength)];
    if (!ConstantTimeEqual(HMACSHA256(macKey, signed_), tag)) {
        return Result(header.hasPasscode ? NanogramVaultOutcomeLocked : NanogramVaultOutcomeCorrupt, nil, NO);
    }
    NSData *iv = [file subdataWithRange:NSMakeRange(kHeaderLength, kIVLength)];
    NSData *cipher = [file subdataWithRange:NSMakeRange(kHeaderLength + kIVLength, file.length - kHeaderLength - kIVLength - kTagLength)];
    NSData *payload = AESCBC(NO, SubKey(master, @"nanogram.keyvault.v1.enc"), iv, cipher);
    if (payload == nil || payload.length != kPayloadLength) {
        return Result(NanogramVaultOutcomeCorrupt, nil, NO);
    }
    return Result(NanogramVaultOutcomeOK, payload, NO);
}

- (NanogramVaultOutcome)writeLockedPayload:(NSData *)payload passcode:(NSString *)passcode {
    NSData *oldFile = [NSData dataWithContentsOfFile:_path];
    NSData *oldKeyId = oldFile != nil && ParseHeader(oldFile).valid ? ParseHeader(oldFile).keyId : nil;

    NSData *keyId = RandomData(kKeyIdLength);
    NSData *wrapKey = RandomData(32);
    NSData *salt = RandomData(kSaltLength);
    NSData *iv = RandomData(kIVLength);

    if ([self faultAt:@"beforeWrapKeyStore"]) {
        return NanogramVaultOutcomeInterrupted;
    }
    if (![_store writeWrapKey:wrapKey withId:HexString(keyId)]) {
        return NanogramVaultOutcomeKeychainUnavailable;
    }
    if ([self faultAt:@"afterWrapKeyStore"]) {
        return NanogramVaultOutcomeInterrupted;
    }

    NSData *master = MasterKey(wrapKey, passcode, salt, _iterations);
    if (master == nil) {
        [_store deleteWrapKeyWithId:HexString(keyId)];
        return NanogramVaultOutcomeCorrupt;
    }
    NSMutableData *file = [[NSMutableData alloc] init];
    [file appendBytes:kVaultMagic length:4];
    uint8_t version = kVaultVersion;
    uint8_t flags = passcode != nil ? kVaultFlagPasscode : 0;
    [file appendBytes:&version length:1];
    [file appendBytes:&flags length:1];
    [file appendData:keyId];
    [file appendData:salt];
    uint32_t iterations = CFSwapInt32HostToBig(_iterations);
    [file appendBytes:&iterations length:4];
    [file appendData:iv];
    NSData *cipher = AESCBC(YES, SubKey(master, @"nanogram.keyvault.v1.enc"), iv, payload);
    if (cipher == nil) {
        [_store deleteWrapKeyWithId:HexString(keyId)];
        return NanogramVaultOutcomeCorrupt;
    }
    [file appendData:cipher];
    [file appendData:HMACSHA256(SubKey(master, @"nanogram.keyvault.v1.mac"), file)];

    if (![file writeToFile:_path atomically:YES]) {
        [_store deleteWrapKeyWithId:HexString(keyId)];
        return NanogramVaultOutcomeCorrupt;
    }
    if ([self faultAt:@"afterFileWrite"]) {
        return NanogramVaultOutcomeInterrupted;
    }
    if (oldKeyId != nil) {
        [_store deleteWrapKeyWithId:HexString(oldKeyId)];
    }
    if ([self faultAt:@"afterOldKeyDelete"]) {
        return NanogramVaultOutcomeInterrupted;
    }
    return NanogramVaultOutcomeOK;
}

- (NanogramVaultOutcome)writePayload:(NSData *)payload passcode:(NSString *)passcode {
    if (payload.length != kPayloadLength) {
        return NanogramVaultOutcomeCorrupt;
    }
    __block NanogramVaultOutcome outcome = NanogramVaultOutcomeCorrupt;
    [self withLock:^{
        outcome = [self writeLockedPayload:payload passcode:passcode];
    }];
    return outcome;
}

- (NanogramKeyVaultResult *)adoptLockedPayload:(NSData *)payload passcode:(NSString *)passcode removeLegacy:(void (^)(void))removeLegacy {
    NanogramVaultOutcome written = [self writeLockedPayload:payload passcode:passcode];
    if (written == NanogramVaultOutcomeInterrupted) {
        return Result(NanogramVaultOutcomeInterrupted, nil, NO);
    }
    if (written != NanogramVaultOutcomeOK) {
        if (removeLegacy != nil) {
            return Result(NanogramVaultOutcomeOK, payload, NO);
        }
        return Result(written, nil, NO);
    }
    if ([self faultAt:@"beforeVerify"]) {
        return Result(NanogramVaultOutcomeInterrupted, nil, NO);
    }
    NanogramKeyVaultResult *verified = [self openWithPasscode:passcode];
    if (verified.outcome != NanogramVaultOutcomeOK || ![verified.payload isEqualToData:payload]) {
        if (removeLegacy != nil) {
            return Result(NanogramVaultOutcomeOK, payload, NO);
        }
        return Result(NanogramVaultOutcomeCorrupt, nil, NO);
    }
    if (removeLegacy != nil) {
        if ([self faultAt:@"beforeLegacyRemoval"]) {
            return Result(NanogramVaultOutcomeInterrupted, nil, NO);
        }
        removeLegacy();
        if ([self faultAt:@"afterLegacyRemoval"]) {
            return Result(NanogramVaultOutcomeInterrupted, nil, NO);
        }
    }
    return Result(NanogramVaultOutcomeOK, payload, removeLegacy != nil);
}

- (NanogramKeyVaultResult *)resolveLockedWithPasscode:(NSString *)passcode legacyExists:(BOOL (^)(void))legacyExists legacyPayload:(NSData * (^)(void))legacyPayload removeLegacy:(void (^)(void))removeLegacy create:(BOOL)create {
    BOOL hasLegacy = legacyExists != nil && legacyExists();
    if ([self fileExists]) {
        NanogramKeyVaultResult *opened = [self openWithPasscode:passcode];
        if (opened.outcome == NanogramVaultOutcomeOK) {
            if (hasLegacy && legacyPayload != nil && removeLegacy != nil) {
                NSData *legacy = legacyPayload();
                if (legacy != nil && [legacy isEqualToData:opened.payload]) {
                    removeLegacy();
                }
            }
            return opened;
        }
        if (opened.outcome != NanogramVaultOutcomeKeyLost && opened.outcome != NanogramVaultOutcomeCorrupt) {
            return opened;
        }
        if (!hasLegacy) {
            return opened;
        }
        NSData *legacy = legacyPayload != nil ? legacyPayload() : nil;
        if (legacy == nil) {
            return Result(NanogramVaultOutcomeLocked, nil, NO);
        }
        return [self adoptLockedPayload:legacy passcode:passcode removeLegacy:removeLegacy];
    }
    if (hasLegacy) {
        NSData *legacy = legacyPayload != nil ? legacyPayload() : nil;
        if (legacy == nil) {
            return Result(NanogramVaultOutcomeLocked, nil, NO);
        }
        return [self adoptLockedPayload:legacy passcode:passcode removeLegacy:removeLegacy];
    }
    if (!create) {
        return Result(NanogramVaultOutcomeMissing, nil, NO);
    }
    return [self adoptLockedPayload:RandomData(kPayloadLength) passcode:passcode removeLegacy:nil];
}

- (NanogramKeyVaultResult *)resolveWithPasscode:(NSString *)passcode legacyExists:(BOOL (^)(void))legacyExists legacyPayload:(NSData * (^)(void))legacyPayload removeLegacy:(void (^)(void))removeLegacy create:(BOOL)create {
    __block NanogramKeyVaultResult *result = nil;
    [self withLock:^{
        result = [self resolveLockedWithPasscode:passcode legacyExists:legacyExists legacyPayload:legacyPayload removeLegacy:removeLegacy create:create];
    }];
    return result;
}

+ (NanogramKeyVaultResult *)resolvePlainKeyFileAtPath:(NSString *)legacyPath vault:(NanogramKeyVault *)vault create:(BOOL)create {
    NSData * (^read)(void) = ^NSData *{
        NSData *data = [NSData dataWithContentsOfFile:legacyPath];
        return data.length == kPayloadLength ? data : nil;
    };
    return [vault resolveWithPasscode:nil legacyExists:^BOOL{
        return read() != nil;
    } legacyPayload:read removeLegacy:^{
        [[NSFileManager defaultManager] removeItemAtPath:legacyPath error:nil];
    } create:create];
}

+ (NSData *)deviceKeyPayloadInRootPath:(NSString *)rootPath store:(id<NanogramWrapKeyStore>)store {
    NSString *plainPath = [rootPath stringByAppendingPathComponent:@".tempkey"];
    NSString *vaultPath = [rootPath stringByAppendingPathComponent:@".tempkeyVault"];
    NSData *plain = [NSData dataWithContentsOfFile:plainPath];
    BOOL vaultExists = [[NSFileManager defaultManager] fileExistsAtPath:vaultPath];

    if (store != nil) {
        NanogramKeyVault *vault = [[NanogramKeyVault alloc] initWithPath:vaultPath store:store];
        if (plain.length == 32) {
            NSMutableData *upgraded = [plain mutableCopy];
            [upgraded appendData:RandomData(kPayloadLength - 32)];
            if ([upgraded writeToFile:plainPath atomically:YES]) {
                plain = upgraded;
            }
        }
        NanogramKeyVaultResult *result = [NanogramKeyVault resolvePlainKeyFileAtPath:plainPath vault:vault create:YES];
        if (result.outcome == NanogramVaultOutcomeOK && result.payload != nil) {
            return result.payload;
        }
        if (vaultExists || result.outcome != NanogramVaultOutcomeKeychainUnavailable) {
            NSLog(@"NanogramKeyVault: key unavailable (%ld), using a throwaway key", (long)result.outcome);
            return RandomData(kPayloadLength);
        }
    }

    NSData *current = [NSData dataWithContentsOfFile:plainPath];
    if (current.length == kPayloadLength) {
        return current;
    }
    NSMutableData *generated = [RandomData(kPayloadLength) mutableCopy];
    if (current.length == 32) {
        [current getBytes:generated.mutableBytes length:32];
    }
    [generated writeToFile:plainPath atomically:YES];
    return generated;
}

@end
