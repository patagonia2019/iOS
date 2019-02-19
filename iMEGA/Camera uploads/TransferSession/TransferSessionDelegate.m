
#import "TransferSessionDelegate.h"
#import "TransferSessionTaskDelegate.h"
#import "TransferSessionManager.h"

@interface TransferSessionDelegate ()

@property (strong, nonatomic) NSMutableDictionary<NSNumber *, TransferSessionTaskDelegate *> *taskDelegateDict;
@property (weak, nonatomic) TransferSessionManager *manager;

@end

@implementation TransferSessionDelegate

- (instancetype)initWithSessionManager:(TransferSessionManager *)manager {
    self = [super init];
    if (self) {
        _manager = manager;
        _taskDelegateDict = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - session tasks

- (TransferSessionTaskDelegate *)delegateForTask:(NSURLSessionTask *)task {
    return self.taskDelegateDict[@(task.taskIdentifier)];
}

- (void)removeDelegateForTask:(NSURLSessionTask *)task {
    [self.taskDelegateDict removeObjectForKey:@(task.taskIdentifier)];
}

- (void)addDelegate:(TransferSessionTaskDelegate *)delegate forTask:(NSURLSessionTask *)task {
    self.taskDelegateDict[@(task.taskIdentifier)] = delegate;
}

#pragma mark - session level delegate

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
    MEGALogError(@"[Camera Upload] Session %@ did become invalid with error: %@", session.configuration.identifier, error);
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    MEGALogInfo(@"[Camera Upload] Session %@ did finish events for background URL Session", session.configuration.identifier);
    [self.manager finishEventsForBackgroundURLSession:session];
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    MEGALogInfo(@"[Camera Upload] Session %@ did receive challenge for protection space: %@", session.configuration.identifier, challenge.protectionSpace);
    if (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust) {
#warning add public key matching check here to improve the security
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

#pragma mark - task level delegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [[self delegateForTask:task] URLSession:session task:task didCompleteWithError:error];
    [self removeDelegateForTask:task];
}

#pragma mark - data level delegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [[self delegateForTask:dataTask] URLSession:session dataTask:dataTask didReceiveData:data];
}

@end
