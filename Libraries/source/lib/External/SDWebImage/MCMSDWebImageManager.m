/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "MCMSDWebImageManager.h"
#import "MCMSDImageCache.h"
#import "MCMSDWebImageDownloader.h"
#import <objc/message.h>

static MCMSDWebImageManager *instance;

@implementation MCMSDWebImageManager

#if NS_BLOCKS_AVAILABLE
@synthesize cacheKeyFilter;
#endif

- (id)init
{
    if ((self = [super init]))
    {
        downloadInfo = [[NSMutableArray alloc] init];
        downloadDelegates = [[NSMutableArray alloc] init];
        downloaders = [[NSMutableArray alloc] init];
        cacheDelegates = [[NSMutableArray alloc] init];
        cacheURLs = [[NSMutableArray alloc] init];
        downloaderForURL = [[NSMutableDictionary alloc] init];
        failedURLs = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    MCMSDWISafeRelease(downloadInfo);
    MCMSDWISafeRelease(downloadDelegates);
    MCMSDWISafeRelease(downloaders);
    MCMSDWISafeRelease(cacheDelegates);
    MCMSDWISafeRelease(cacheURLs);
    MCMSDWISafeRelease(downloaderForURL);
    MCMSDWISafeRelease(failedURLs);
    MCMSDWISuperDealoc;
}


+ (id)sharedManager
{
    if (instance == nil)
    {
        instance = [[MCMSDWebImageManager alloc] init];
    }
    
    return instance;
}

- (NSString *)cacheKeyForURL:(NSURL *)url
{
#if NS_BLOCKS_AVAILABLE
    if (self.cacheKeyFilter)
    {
        return self.cacheKeyFilter(url);
    }
    else
    {
        return [url absoluteString];
    }
#else
    return [url absoluteString];
#endif
}

/*
 * @deprecated
 */
- (UIImage *)imageWithURL:(NSURL *)url
{
    return [[MCMSDImageCache sharedImageCache] imageFromKey:[self cacheKeyForURL:url]];
}

/*
 * @deprecated
 */
- (void)downloadWithURL:(NSURL *)url delegate:(id<MCMSDWebImageManagerDelegate>)delegate retryFailed:(BOOL)retryFailed
{
    [self downloadWithURL:url delegate:delegate options:(retryFailed ? MCMSDWebImageRetryFailed : 0)];
}

/*
 * @deprecated
 */
- (void)downloadWithURL:(NSURL *)url delegate:(id<MCMSDWebImageManagerDelegate>)delegate retryFailed:(BOOL)retryFailed lowPriority:(BOOL)lowPriority
{
    MCMSDWebImageOptions options = 0;
    if (retryFailed) options |= MCMSDWebImageRetryFailed;
    if (lowPriority) options |= MCMSDWebImageLowPriority;
    [self downloadWithURL:url delegate:delegate options:options];
}

- (void)downloadWithURL:(NSURL *)url delegate:(id<MCMSDWebImageManagerDelegate>)delegate
{
    [self downloadWithURL:url delegate:delegate options:0];
}

- (void)downloadWithURL:(NSURL *)url delegate:(id<MCMSDWebImageManagerDelegate>)delegate options:(MCMSDWebImageOptions)options
{
    [self downloadWithURL:url delegate:delegate options:options userInfo:nil];
}

- (void)downloadWithURL:(NSURL *)url delegate:(id<MCMSDWebImageManagerDelegate>)delegate options:(MCMSDWebImageOptions)options userInfo:(NSDictionary *)userInfo
{
    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, XCode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    if ([url isKindOfClass:NSString.class])
    {
        url = [NSURL URLWithString:(NSString *)url];
    }
    else if (![url isKindOfClass:NSURL.class])
    {
        url = nil; // Prevent some common crashes due to common wrong values passed like NSNull.null for instance
    }
    
    if (!url || !delegate || (!(options & MCMSDWebImageRetryFailed) && [failedURLs containsObject:url]))
    {
        return;
    }
    
    // Check the on-disk cache async so we don't block the main thread
    [cacheDelegates addObject:delegate];
    [cacheURLs addObject:url];
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          delegate, @"delegate",
                          url, @"url",
                          [NSNumber numberWithInt:options], @"options",
                          userInfo ? userInfo : [NSNull null], @"userInfo",
                          nil];
    [[MCMSDImageCache sharedImageCache] queryDiskCacheForKey:[self cacheKeyForURL:url] delegate:self userInfo:info];
}

#if NS_BLOCKS_AVAILABLE
- (void)downloadWithURL:(NSURL *)url delegate:(id)delegate options:(MCMSDWebImageOptions)options success:(MCMSDWebImageSuccessBlock)success failure:(MCMSDWebImageFailureBlock)failure
{
    [self downloadWithURL:url delegate:delegate options:options userInfo:nil success:success failure:failure];
}

- (void)downloadWithURL:(NSURL *)url delegate:(id)delegate options:(MCMSDWebImageOptions)options userInfo:(NSDictionary *)userInfo success:(MCMSDWebImageSuccessBlock)success failure:(MCMSDWebImageFailureBlock)failure
{
    // repeated logic from above due to requirement for backwards compatability for iOS versions without blocks
    
    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, XCode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    if ([url isKindOfClass:NSString.class])
    {
        url = [NSURL URLWithString:(NSString *)url];
    }
    
    if (!url || !delegate || (!(options & MCMSDWebImageRetryFailed) && [failedURLs containsObject:url]))
    {
        return;
    }
    
    // Check the on-disk cache async so we don't block the main thread
    [cacheDelegates addObject:delegate];
    [cacheURLs addObject:url];
    MCMSDWebImageSuccessBlock successCopy = [success copy];
    MCMSDWebImageFailureBlock failureCopy = [failure copy];
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          delegate, @"delegate",
                          url, @"url",
                          [NSNumber numberWithInt:options], @"options",
                          userInfo ? userInfo : [NSNull null], @"userInfo",
                          successCopy, @"success",
                          failureCopy, @"failure",
                          nil];
    MCMSDWIRelease(successCopy);
    MCMSDWIRelease(failureCopy);
    [[MCMSDImageCache sharedImageCache] queryDiskCacheForKey:[self cacheKeyForURL:url] delegate:self userInfo:info];
}
#endif

- (void)removeObjectsForDelegate:(id<MCMSDWebImageManagerDelegate>)delegate
{
    // Delegates notified, remove downloader and delegate
    // The delegate callbacks above may have modified the arrays, hence we search for the correct index
    int idx = [downloadDelegates indexOfObjectIdenticalTo:delegate];
    if (idx != NSNotFound)
    {
        [downloaders removeObjectAtIndex:idx];
        [downloadInfo removeObjectAtIndex:idx];
        [downloadDelegates removeObjectAtIndex:idx];
    }
}

- (void)cancelForDelegate:(id<MCMSDWebImageManagerDelegate>)delegate
{
    NSUInteger idx;
    while ((idx = [cacheDelegates indexOfObjectIdenticalTo:delegate]) != NSNotFound)
    {
        [cacheDelegates removeObjectAtIndex:idx];
        [cacheURLs removeObjectAtIndex:idx];
    }
    
    while ((idx = [downloadDelegates indexOfObjectIdenticalTo:delegate]) != NSNotFound)
    {
        MCMSDWebImageDownloader *downloader = MCMSDWIReturnRetained([downloaders objectAtIndex:idx]);
        
        [downloadInfo removeObjectAtIndex:idx];
        [downloadDelegates removeObjectAtIndex:idx];
        [downloaders removeObjectAtIndex:idx];
        
        if (![downloaders containsObject:downloader])
        {
            // No more delegate are waiting for this download, cancel it
            [downloader cancel];
            [downloaderForURL removeObjectForKey:downloader.url];
        }
        
        MCMSDWIRelease(downloader);
    }
}

- (void)cancelAll
{
    for (MCMSDWebImageDownloader *downloader in downloaders)
    {
        [downloader cancel];
    }
    [cacheDelegates removeAllObjects];
    [cacheURLs removeAllObjects];
    
    [downloadInfo removeAllObjects];
    [downloadDelegates removeAllObjects];
    [downloaders removeAllObjects];
    [downloaderForURL removeAllObjects];
}

#pragma mark MCMSDImageCacheDelegate

- (NSUInteger)indexOfDelegate:(id<MCMSDWebImageManagerDelegate>)delegate waitingForURL:(NSURL *)url
{
    // Do a linear search, simple (even if inefficient)
    NSUInteger idx;
    for (idx = 0; idx < [cacheDelegates count]; idx++)
    {
        if ([cacheDelegates objectAtIndex:idx] == delegate && [[cacheURLs objectAtIndex:idx] isEqual:url])
        {
            return idx;
        }
    }
    return NSNotFound;
}

- (void)imageCache:(MCMSDImageCache *)imageCache didFindImage:(UIImage *)image forKey:(NSString *)key userInfo:(NSDictionary *)info
{
    NSURL *url = [info objectForKey:@"url"];
    id<MCMSDWebImageManagerDelegate> delegate = [info objectForKey:@"delegate"];
    
    NSUInteger idx = [self indexOfDelegate:delegate waitingForURL:url];
    if (idx == NSNotFound)
    {
        // Request has since been canceled
        return;
    }
    
    if ([delegate respondsToSelector:@selector(webImageManager:didFinishWithImage:)])
    {
        [delegate performSelector:@selector(webImageManager:didFinishWithImage:) withObject:self withObject:image];
    }
    if ([delegate respondsToSelector:@selector(webImageManager:didFinishWithImage:forURL:)])
    {
        objc_msgSend(delegate, @selector(webImageManager:didFinishWithImage:forURL:), self, image, url);
    }
    if ([delegate respondsToSelector:@selector(webImageManager:didFinishWithImage:forURL:userInfo:)])
    {
        NSDictionary *userInfo = [info objectForKey:@"userInfo"];
        if ([userInfo isKindOfClass:NSNull.class])
        {
            userInfo = nil;
        }
        objc_msgSend(delegate, @selector(webImageManager:didFinishWithImage:forURL:userInfo:), self, image, url, userInfo);
    }
#if NS_BLOCKS_AVAILABLE
    if ([info objectForKey:@"success"])
    {
        MCMSDWebImageSuccessBlock success = [info objectForKey:@"success"];
        success(image, YES);
    }
#endif
    
    // Delegates notified, remove url and delegate
    // The delegate callbacks above may have modified the arrays, hence we search for the correct index
    int removeIdx = [self indexOfDelegate:delegate waitingForURL:url];
    if (removeIdx != NSNotFound)
    {
        [cacheDelegates removeObjectAtIndex:removeIdx];
        [cacheURLs removeObjectAtIndex:removeIdx];
    }
}

- (void)imageCache:(MCMSDImageCache *)imageCache didNotFindImageForKey:(NSString *)key userInfo:(NSDictionary *)info
{
    NSURL *url = [info objectForKey:@"url"];
    id<MCMSDWebImageManagerDelegate> delegate = [info objectForKey:@"delegate"];
    MCMSDWebImageOptions options = [[info objectForKey:@"options"] intValue];
    
    NSUInteger idx = [self indexOfDelegate:delegate waitingForURL:url];
    if (idx == NSNotFound)
    {
        // Request has since been canceled
        return;
    }
    
    [cacheDelegates removeObjectAtIndex:idx];
    [cacheURLs removeObjectAtIndex:idx];
    
    // Share the same downloader for identical URLs so we don't download the same URL several times
    MCMSDWebImageDownloader *downloader = [downloaderForURL objectForKey:url];
    
    if (!downloader)
    {
        downloader = [MCMSDWebImageDownloader downloaderWithURL:url delegate:self userInfo:info lowPriority:(options & MCMSDWebImageLowPriority)];
        [downloaderForURL setObject:downloader forKey:url];
    }
    else
    {
        // Reuse shared downloader
        downloader.lowPriority = (options & MCMSDWebImageLowPriority);
    }
    
    if ((options & MCMSDWebImageProgressiveDownload) && !downloader.progressive)
    {
        // Turn progressive download support on demand
        downloader.progressive = YES;
    }
    
    [downloadInfo addObject:info];
    [downloadDelegates addObject:delegate];
    [downloaders addObject:downloader];
}

#pragma mark MCMSDWebImageDownloaderDelegate

- (void)imageDownloader:(MCMSDWebImageDownloader *)downloader didUpdatePartialImage:(UIImage *)image
{
    NSMutableArray *notifiedDelegates = [NSMutableArray arrayWithCapacity:downloaders.count];
    
    BOOL found = YES;
    while (found)
    {
        found = NO;
        assert(downloaders.count == downloadDelegates.count);
        assert(downloaders.count == downloadInfo.count);
        NSInteger count = downloaders.count;
        for (NSInteger i=count-1; i>=0; --i)
        {
            MCMSDWebImageDownloader *aDownloader = [downloaders objectAtIndex:i];
            if (aDownloader != downloader)
            {
                continue;
            }
            
            id<MCMSDWebImageManagerDelegate> delegate = [downloadDelegates objectAtIndex:i];
            MCMSDWIRetain(delegate);
            MCMSDWIAutorelease(delegate);
            
            if ([notifiedDelegates containsObject:delegate])
            {
                continue;
            }
            // Keep track of delegates notified
            [notifiedDelegates addObject:delegate];
            
            NSDictionary *info = [downloadInfo objectAtIndex:i];
            MCMSDWIRetain(info);
            MCMSDWIAutorelease(info);
            
            if ([delegate respondsToSelector:@selector(webImageManager:didProgressWithPartialImage:forURL:)])
            {
                objc_msgSend(delegate, @selector(webImageManager:didProgressWithPartialImage:forURL:), self, image, downloader.url);
            }
            if ([delegate respondsToSelector:@selector(webImageManager:didProgressWithPartialImage:forURL:userInfo:)])
            {
                NSDictionary *userInfo = [info objectForKey:@"userInfo"];
                if ([userInfo isKindOfClass:NSNull.class])
                {
                    userInfo = nil;
                }
                objc_msgSend(delegate, @selector(webImageManager:didProgressWithPartialImage:forURL:userInfo:), self, image, downloader.url, userInfo);
            }
            // Delegate notified. Break out and restart loop
            found = YES;
            break;
        }
    }
}

- (void)imageDownloader:(MCMSDWebImageDownloader *)downloader didFinishWithImage:(UIImage *)image
{
    MCMSDWIRetain(downloader);
    MCMSDWebImageOptions options = [[downloader.userInfo objectForKey:@"options"] intValue];
    BOOL found = YES;
    while (found)
    {
        found = NO;
        assert(downloaders.count == downloadDelegates.count);
        assert(downloaders.count == downloadInfo.count);
        NSInteger count = downloaders.count;
        for (NSInteger i=count-1; i>=0; --i)
        {
            MCMSDWebImageDownloader *aDownloader = [downloaders objectAtIndex:i];
            if (aDownloader != downloader)
            {
                continue;
            }
            id<MCMSDWebImageManagerDelegate> delegate = [downloadDelegates objectAtIndex:i];
            MCMSDWIRetain(delegate);
            MCMSDWIAutorelease(delegate);
            NSDictionary *info = [downloadInfo objectAtIndex:i];
            MCMSDWIRetain(info);
            MCMSDWIAutorelease(info);
            
            if (image)
            {
                if ([delegate respondsToSelector:@selector(webImageManager:didFinishWithImage:)])
                {
                    [delegate performSelector:@selector(webImageManager:didFinishWithImage:) withObject:self withObject:image];
                }
                if ([delegate respondsToSelector:@selector(webImageManager:didFinishWithImage:forURL:)])
                {
                    objc_msgSend(delegate, @selector(webImageManager:didFinishWithImage:forURL:), self, image, downloader.url);
                }
                if ([delegate respondsToSelector:@selector(webImageManager:didFinishWithImage:forURL:userInfo:)])
                {
                    NSDictionary *userInfo = [info objectForKey:@"userInfo"];
                    if ([userInfo isKindOfClass:NSNull.class])
                    {
                        userInfo = nil;
                    }
                    objc_msgSend(delegate, @selector(webImageManager:didFinishWithImage:forURL:userInfo:), self, image, downloader.url, userInfo);
                }
#if NS_BLOCKS_AVAILABLE
                if ([info objectForKey:@"success"])
                {
                    MCMSDWebImageSuccessBlock success = [info objectForKey:@"success"];
                    success(image, NO);
                }
#endif
            }
            else
            {
                if ([delegate respondsToSelector:@selector(webImageManager:didFailWithError:)])
                {
                    [delegate performSelector:@selector(webImageManager:didFailWithError:) withObject:self withObject:nil];
                }
                if ([delegate respondsToSelector:@selector(webImageManager:didFailWithError:forURL:)])
                {
                    objc_msgSend(delegate, @selector(webImageManager:didFailWithError:forURL:), self, nil, downloader.url);
                }
                if ([delegate respondsToSelector:@selector(webImageManager:didFailWithError:forURL:userInfo:)])
                {
                    NSDictionary *userInfo = [info objectForKey:@"userInfo"];
                    if ([userInfo isKindOfClass:NSNull.class])
                    {
                        userInfo = nil;
                    }
                    objc_msgSend(delegate, @selector(webImageManager:didFailWithError:forURL:userInfo:), self, nil, downloader.url, userInfo);
                }
#if NS_BLOCKS_AVAILABLE
                if ([info objectForKey:@"failure"])
                {
                    MCMSDWebImageFailureBlock failure = [info objectForKey:@"failure"];
                    failure(nil);
                }
#endif
            }
            // Downloader found. Break out and restart for loop
            [self removeObjectsForDelegate:delegate];
            found = YES;
            break;
        }
    }
    
    if (image)
    {
        // Store the image in the cache
        [[MCMSDImageCache sharedImageCache] storeImage:image
                                          imageData:downloader.imageData
                                             forKey:[self cacheKeyForURL:downloader.url]
                                             toDisk:!(options & MCMSDWebImageCacheMemoryOnly)];
    }
    else if (!(options & MCMSDWebImageRetryFailed))
    {
        // The image can't be downloaded from this URL, mark the URL as failed so we won't try and fail again and again
        // (do this only if MCMSDWebImageRetryFailed isn't activated)
        [failedURLs addObject:downloader.url];
    }
    
    
    // Release the downloader
    [downloaderForURL removeObjectForKey:downloader.url];
    MCMSDWIRelease(downloader);
}

- (void)imageDownloader:(MCMSDWebImageDownloader *)downloader didFailWithError:(NSError *)error;
{
    MCMSDWIRetain(downloader);
    
    // Notify all the downloadDelegates with this downloader
    BOOL found = YES;
    while (found)
    {
        found = NO;
        assert(downloaders.count == downloadDelegates.count);
        assert(downloaders.count == downloadInfo.count);
        NSInteger count = downloaders.count;
        for (NSInteger i=count-1 ; i>=0; --i)
        {
            MCMSDWebImageDownloader *aDownloader = [downloaders objectAtIndex:i];
            if (aDownloader != downloader)
            {
                continue;
            }
            id<MCMSDWebImageManagerDelegate> delegate = [downloadDelegates objectAtIndex:i];
            MCMSDWIRetain(delegate);
            MCMSDWIAutorelease(delegate);
            NSDictionary *info = [downloadInfo objectAtIndex:i];
            MCMSDWIRetain(info);
            MCMSDWIAutorelease(info);
            
            if ([delegate respondsToSelector:@selector(webImageManager:didFailWithError:)])
            {
                [delegate performSelector:@selector(webImageManager:didFailWithError:) withObject:self withObject:error];
            }
            if ([delegate respondsToSelector:@selector(webImageManager:didFailWithError:forURL:)])
            {
                objc_msgSend(delegate, @selector(webImageManager:didFailWithError:forURL:), self, error, downloader.url);
            }
            if ([delegate respondsToSelector:@selector(webImageManager:didFailWithError:forURL:userInfo:)])
            {
                NSDictionary *userInfo = [info objectForKey:@"userInfo"];
                if ([userInfo isKindOfClass:NSNull.class])
                {
                    userInfo = nil;
                }
                objc_msgSend(delegate, @selector(webImageManager:didFailWithError:forURL:userInfo:), self, error, downloader.url, userInfo);
            }
#if NS_BLOCKS_AVAILABLE
            if ([info objectForKey:@"failure"])
            {
                MCMSDWebImageFailureBlock failure = [info objectForKey:@"failure"];
                failure(error);
            }
#endif
            // Downloader found. Break out and restart for loop
            [self removeObjectsForDelegate:delegate];
            found = YES;
            break;
        }
    }
    
    // Release the downloader
    [downloaderForURL removeObjectForKey:downloader.url];
    MCMSDWIRelease(downloader);
}

@end