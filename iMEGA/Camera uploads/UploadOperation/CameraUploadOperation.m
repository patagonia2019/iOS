
#import "CameraUploadOperation.h"
#import "MEGASdkManager.h"
#import "NSFileManager+MNZCategory.h"
#import "NSString+MNZCategory.h"
#import "TransferSessionManager.h"
#import "AssetUploadInfo.h"
#import "CameraUploadRecordManager.h"
#import "CameraUploadManager.h"
#import "CameraUploadRequestDelegate.h"
#import "FileEncryption.h"
@import Photos;

@interface CameraUploadOperation ()

@property (nonatomic) UIBackgroundTaskIdentifier uploadTaskIdentifier;
@property (strong, nonatomic, nullable) MEGASdk *attributesDataSDK;
@property (strong, nonatomic) CameraUploadCoordinator *uploadCoordinator;

@end

@implementation CameraUploadOperation

#pragma mark - initializers

- (instancetype)initWithUploadInfo:(AssetUploadInfo *)uploadInfo {
    self = [super init];
    if (self) {
        _uploadInfo = uploadInfo;
    }
    
    return self;
}

#pragma mark - properties

- (CameraUploadCoordinator *)uploadCoordinator {
    if (_uploadCoordinator == nil) {
        _uploadCoordinator = [[CameraUploadCoordinator alloc] init];
    }
    
    return _uploadCoordinator;
}

- (MEGASdk *)attributesDataSDK {
    if (_attributesDataSDK == nil) {
        NSString *basePath = [[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject] path];
        _attributesDataSDK = [[MEGASdk alloc] initWithAppKey:@"EVtjzb7R"
                                                   userAgent:[NSString stringWithFormat:@"%@/%@", @"MEGAiOS", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]]
                                                    basePath:basePath];
    }
    
    return _attributesDataSDK;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ %@ %@ %@", NSStringFromClass(self.class), self.uploadInfo.asset.localIdentifier, self.uploadInfo.asset.creationDate, self.uploadInfo.fileName];
}

#pragma mark - start operation

- (void)start {
    [super start];
    
    if (self.uploadInfo.asset == nil) {
        [[CameraUploadRecordManager shared] deleteRecordsByLocalIdentifiers:@[self.uploadInfo.asset.localIdentifier] error:nil];
        [self finishOperation];
        MEGALogDebug(@"[Camera Upload] %@ finishes with empty asset", self);
        return;
    }

    [self beginBackgroundTask];
    
    MEGALogDebug(@"[Camera Upload] %@ starts processing", self);
    [[CameraUploadRecordManager shared] updateStatus:UploadStatusProcessing forLocalIdentifier:self.uploadInfo.asset.localIdentifier error:nil];
}

- (void)beginBackgroundTask {
    self.uploadTaskIdentifier = [UIApplication.sharedApplication beginBackgroundTaskWithName:[NSString stringWithFormat:@"nz.mega.cameraUpload.%@", NSStringFromClass(self.class)] expirationHandler:^{
        MOAssetUploadRecord *record = [CameraUploadRecordManager.shared fetchAssetUploadRecordByLocalIdentifier:self.uploadInfo.asset.localIdentifier error:nil];
        MEGALogDebug(@"[Camera Upload] %@ background task expired", self);
        if ([record.status isEqualToString:UploadStatusUploading]) {
            [self finishOperation];
            MEGALogDebug(@"[Camera Upload] %@ finishes while uploading", self);
        } else {
            [self cancel];
            [self finishOperationWithStatus:UploadStatusFailed shouldUploadNextAsset:NO];
        }
        
        [UIApplication.sharedApplication endBackgroundTask:self.uploadTaskIdentifier];
        self.uploadTaskIdentifier = UIBackgroundTaskInvalid;
    }];
}

#pragma mark - data processing

- (void)copyToParentNodeIfNeededForMatchingNode:(MEGANode *)node {
    if (node == nil) {
        return;
    }
    
    if (node.parentHandle != self.uploadInfo.parentNode.handle) {
        [[MEGASdkManager sharedMEGASdk] copyNode:node newParent:self.uploadInfo.parentNode];
    }
}

- (MEGANode *)nodeForOriginalFingerprint:(NSString *)fingerprint {
    MEGANode *matchingNode = [MEGASdkManager.sharedMEGASdk nodeForFingerprint:fingerprint];
    if (matchingNode == nil) {
        MEGANodeList *nodeList = [MEGASdkManager.sharedMEGASdk nodesForOriginalFingerprint:fingerprint];
        if (nodeList.size.integerValue > 0) {
            matchingNode = [self firstNodeInNodeList:nodeList hasParentNode:self.uploadInfo.parentNode];
            if (matchingNode == nil) {
                matchingNode = [nodeList nodeAtIndex:0];
            }
        }
    }
    
    return matchingNode;
}

- (MEGANode *)firstNodeInNodeList:(MEGANodeList *)nodeList hasParentNode:(MEGANode *)parent {
    for (NSInteger i = 0; i < nodeList.size.integerValue; i++) {
        MEGANode *node = [nodeList nodeAtIndex:i];
        if (node.parentHandle == parent.handle) {
            return node;
        }
    }
    
    return nil;
}

- (NSURL *)URLForAssetFolder {
    NSURL *assetDirectoryURL = [AssetUploadInfo assetDirectoryURLForLocalIdentifier:self.uploadInfo.asset.localIdentifier];
    [NSFileManager.defaultManager removeItemIfExistsAtURL:assetDirectoryURL];
    [[NSFileManager defaultManager] createDirectoryAtURL:assetDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    return assetDirectoryURL;
}

- (void)createThumbnailAndPreviewFiles {
    [self.attributesDataSDK createThumbnail:self.uploadInfo.fileURL.path destinatioPath:self.uploadInfo.thumbnailURL.path];
    [self.attributesDataSDK createPreview:self.uploadInfo.fileURL.path destinatioPath:self.uploadInfo.previewURL.path];
    self.attributesDataSDK = nil;
}

#pragma mark - upload task

- (void)encryptsFile {
    self.uploadInfo.mediaUpload = [MEGASdkManager.sharedMEGASdk backgroundMediaUpload];
    FileEncryption *fileEncryption = [[FileEncryption alloc] initWithMediaUpload:self.uploadInfo.mediaUpload outputFileURL:self.uploadInfo.encryptionDirectoryURL];
    [fileEncryption encryptFileAtURL:self.uploadInfo.fileURL completion:^(BOOL success, unsigned long long fileSize, NSDictionary<NSString *,NSURL *> * _Nonnull chunkURLsKeyedByUploadSuffix, NSError * _Nonnull error) {
        if (success) {
            MEGALogDebug(@"[Camera Upload] %@ file encryption is done with chunks %@", self, chunkURLsKeyedByUploadSuffix);
            self.uploadInfo.fileSize = fileSize;
            self.uploadInfo.encryptedChunkURLsKeyedByUploadSuffix = chunkURLsKeyedByUploadSuffix;
            [self requestUploadURL];
        } else {
            MEGALogDebug(@"[Camera Upload] %@ error when to encrypt file %@", self, error);
            [self finishOperationWithStatus:UploadStatusFailed shouldUploadNextAsset:YES];
            return;
        }
    }];
}

- (void)requestUploadURL {
    [[MEGASdkManager sharedMEGASdk] requestBackgroundUploadURLWithFileSize:self.uploadInfo.fileSize mediaUpload:self.uploadInfo.mediaUpload delegate:[[CameraUploadRequestDelegate alloc] initWithCompletion:^(MEGARequest * _Nonnull request, MEGAError * _Nonnull error) {
        if (error.type) {
            MEGALogError(@"[Camera Upload] %@ requests upload url failed with error type: %ld", self, error.type);
            [self finishOperationWithStatus:UploadStatusFailed shouldUploadNextAsset:YES];
        } else {
            self.uploadInfo.uploadURLString = [self.uploadInfo.mediaUpload uploadURLString];
            [self uploadEncryptedChunksToServer];
        }
    }]];
}

- (void)uploadEncryptedChunksToServer {
    [self createThumbnailAndPreviewFiles];
    MEGALogDebug(@"[Camera Upload] %@ starts uploading file to server: %@", self, self.uploadInfo.uploadURLString);
    [self archiveUploadInfoDataForBackgroundTransfer];
    [CameraUploadRecordManager.shared updateStatus:UploadStatusUploading forLocalIdentifier:self.uploadInfo.asset.localIdentifier error:nil];
    
    for (NSString *uploadSuffix in self.uploadInfo.encryptedChunkURLsKeyedByUploadSuffix.allKeys) {
        NSURL *serverURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", self.uploadInfo.uploadURLString, uploadSuffix]];
        NSURL *chunkURL = self.uploadInfo.encryptedChunkURLsKeyedByUploadSuffix[uploadSuffix];
        if ([NSFileManager.defaultManager fileExistsAtPath:chunkURL.path]) {
            NSURLSessionUploadTask *uploadTask = [[TransferSessionManager shared] photoUploadTaskWithURL:serverURL fromFile:chunkURL completion:nil];
            uploadTask.taskDescription = self.uploadInfo.asset.localIdentifier;
            [uploadTask resume];
            MEGALogDebug(@"[Camera Upload] %@ starts uploading chunk %@", self, chunkURL);
        } else {
            MEGALogDebug(@"[Camera Upload] %@ chunk doesn't exist at %@", self, chunkURL);
            [self finishOperationWithStatus:UploadStatusFailed shouldUploadNextAsset:YES];
            return;
        }
    }
    
    [self finishOperation];
}

#pragma mark - archive upload info

- (void)archiveUploadInfoDataForBackgroundTransfer {
    MEGALogDebug(@"[Camera Upload] %@ start archiving upload info", self);
    NSURL *archivedURL = [AssetUploadInfo archivedURLForLocalIdentifier:self.uploadInfo.asset.localIdentifier];
    [NSKeyedArchiver archiveRootObject:self.uploadInfo toFile:archivedURL.path];
}

#pragma mark - finish operation

- (void)finishOperationWithStatus:(NSString *)status shouldUploadNextAsset:(BOOL)uploadNextAsset {
    MEGALogDebug(@"[Camera Upload] %@ finishes with status: %@", self, status);
    
    [[NSFileManager defaultManager] removeItemAtURL:self.uploadInfo.directoryURL error:nil];
    
    [[CameraUploadRecordManager shared] updateStatus:status forLocalIdentifier:self.uploadInfo.asset.localIdentifier error:nil];
    
    [self finishOperation];
    
    if (uploadNextAsset) {
        [[CameraUploadManager shared] uploadNextForAsset:self.uploadInfo.asset];
    }
}

- (void)finishOperation {
    [super finishOperation];
    
    if (self.uploadTaskIdentifier != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.uploadTaskIdentifier];
        self.uploadTaskIdentifier = UIBackgroundTaskInvalid;
    }
}

@end
