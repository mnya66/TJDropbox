//
//  TJDropbox.m
//  TJDropbox
//
//  Created by Tim Johnsen on 4/11/16.
//  Copyright © 2016 tijo. All rights reserved.
//

#import "TJDropbox.h"

NSString *const TJDropboxErrorDomain = @"TJDropboxErrorDomain";

@implementation TJDropbox

#pragma mark - Authentication

+ (NSURL *)tokenAuthenticationURLWithClientIdentifier:(NSString *const)clientIdentifier redirectURL:(NSURL *const)redirectURL
{
    // https://www.dropbox.com/developers/documentation/http/documentation#auth
    
    NSURLComponents *const components = [NSURLComponents componentsWithURL:[NSURL URLWithString:@"https://www.dropbox.com/1/oauth2/authorize"] resolvingAgainstBaseURL:NO];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client_id" value:clientIdentifier],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:redirectURL.absoluteString],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"token"]
    ];
    return components.URL;
}

+ (nullable NSString *)accessTokenFromURL:(NSURL *const)url withRedirectURL:(NSURL *const)redirectURL
{
    NSString *accessToken = nil;
    if ([url.absoluteString hasPrefix:redirectURL.absoluteString]) {
        NSString *const fragment = url.fragment;
        NSURLComponents *const components = [NSURLComponents new];
        components.query = fragment;
        for (NSURLQueryItem *const item in components.queryItems) {
            if ([item.name isEqualToString:@"access_token"]) {
                accessToken = item.value;
                break;
            }
        }
    }
    return accessToken;
}

#pragma mark - Generic

+ (NSMutableURLRequest *)requestWithBaseURLString:(NSString *const)baseURLString path:(NSString *const)path accessToken:(NSString *const)accessToken
{
    NSURLComponents *const components = [[NSURLComponents alloc] initWithString:baseURLString];
    components.path = path;
    
    NSMutableURLRequest *const request = [[NSMutableURLRequest alloc] initWithURL:components.URL];
    request.HTTPMethod = @"POST";
    NSString *const authorization = [NSString stringWithFormat:@"Bearer %@", accessToken];
    [request addValue:authorization forHTTPHeaderField:@"Authorization"];
    
    return request;
}

+ (NSData *)parameterDataForParameters:(NSDictionary<NSString *, NSString *> *)parameters
{
    NSData *parameterData = nil;
    if (parameters.count > 0) {
        NSError *error = nil;
        parameterData = [NSJSONSerialization dataWithJSONObject:parameters options:0 error:&error];
        if (error) {
            NSLog(@"[TJDropbox] - Error in %s: %@", __PRETTY_FUNCTION__, error);
        }
    }
    return parameterData;
}

+ (NSURLRequest *)apiRequestWithPath:(NSString *const)path accessToken:(NSString *const)accessToken parameters:(NSDictionary<NSString *, NSString *> *const)parameters
{
    NSMutableURLRequest *const request = [self requestWithBaseURLString:@"https://api.dropboxapi.com" path:path accessToken:accessToken];
    [request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [self parameterDataForParameters:parameters];
    return request;
}

+ (NSMutableURLRequest *)contentRequestWithPath:(NSString *const)path accessToken:(NSString *const)accessToken parameters:(NSDictionary<NSString *, NSString *> *const)parameters
{
    NSMutableURLRequest *const request = [self requestWithBaseURLString:@"https://content.dropboxapi.com" path:path accessToken:accessToken];
    NSData *const parameterData = [self parameterDataForParameters:parameters];
    if (parameterData) {
        NSString *const parameterString = [[NSString alloc] initWithData:parameterData encoding:NSUTF8StringEncoding];
        [request setValue:parameterString forHTTPHeaderField:@"Dropbox-API-Arg"];
    }
    return request;
}

+ (NSURLSession *)session
{
    static NSURLSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    });
    return session;
}

+ (void)performRequest:(NSURLRequest *)request withCompletion:(void (^const)(NSDictionary *_Nullable parsedResponse, NSError *_Nullable error))completion
{
    [[[self session] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSDictionary *parsedResult = nil;
        [self processResultJSONData:data response:response error:&error parsedResult:&parsedResult];
        completion(parsedResult, error);
    }] resume];
}

+ (void)processResultJSONData:(NSData *const)data response:(NSURLResponse *const)response error:(inout NSError **)error parsedResult:(out NSDictionary **)parsedResult
{
    NSString *errorString = nil;
    if (data.length > 0) {
        id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([result isKindOfClass:[NSDictionary class]]) {
            *parsedResult = result;
        } else {
            errorString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    }
    
    // Things leading to errors
    // 1. error returned to this block
    // 2. dropboxAPIErrorDictionary populated
    // 3. Status code >= 400
    // 4. errorString populated
    
    NSHTTPURLResponse *const httpURLResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    const NSInteger statusCode = [httpURLResponse statusCode];
    NSDictionary *const dropboxAPIErrorDictionary = [*parsedResult objectForKey:@"error"];
    
    if (!*error) {
        if (statusCode >= 400 || dropboxAPIErrorDictionary || !*parsedResult) {
            NSMutableDictionary *const userInfo = [NSMutableDictionary new];
            if (response) {
                [userInfo setObject:response forKey:@"response"];
            }
            if (dropboxAPIErrorDictionary) {
                [userInfo setObject:dropboxAPIErrorDictionary forKey:@"dropboxError"];
            }
            if (errorString) {
                [userInfo setObject:errorString forKey:@"errorString"];
            }
            *error = [NSError errorWithDomain:TJDropboxErrorDomain code:0 userInfo:userInfo];
        }
    }
}

#pragma mark - File Inspection

+ (NSURLRequest *)listFolderRequestWithPath:(NSString *const)filePath accessToken:(NSString *const)accessToken cursor:(nullable NSString *const)cursor
{
    NSString *const urlPath = cursor.length > 0 ? @"/2/files/list_folder/continue" : @"/2/files/list_folder";
    NSMutableDictionary *const parameters = [NSMutableDictionary new];
    [parameters setObject:filePath forKey:@"path"];
    if (cursor) {
        [parameters setObject:cursor forKey:@"cursor"];
    }
    return [self apiRequestWithPath:urlPath accessToken:accessToken parameters:parameters];
}

+ (void)listFolderWithPath:(NSString *const)path accessToken:(NSString *const)accessToken completion:(void (^const)(NSArray<NSDictionary *> *_Nullable entries, NSError *_Nullable error))completion
{
    [self listFolderWithPath:path accessToken:accessToken cursor:nil accumulatedFiles:nil completion:completion];
}

+ (void)listFolderWithPath:(NSString *const)path accessToken:(NSString *const)accessToken cursor:(NSString *const)cursor accumulatedFiles:(NSArray *const)accumulatedFiles completion:(void (^const)(NSArray<NSDictionary *> *_Nullable entries, NSError *_Nullable error))completion;
{
    NSURLRequest *const request = [self listFolderRequestWithPath:path accessToken:accessToken cursor:cursor];
    [self performRequest:request withCompletion:^(NSDictionary *parsedResponse, NSError *error) {
        if (!error) {
            NSArray *const files = [parsedResponse objectForKey:@"entries"];
            NSArray *const newlyAccumulatedFiles = accumulatedFiles.count > 0 ? [accumulatedFiles arrayByAddingObjectsFromArray:files] : files;
            const BOOL hasMore = [[parsedResponse objectForKey:@"has_more"] boolValue];
            NSString *const cursor = [parsedResponse objectForKey:@"cursor"];
            if (hasMore) {
                if (cursor) {
                    // Fetch next page
                    [self listFolderWithPath:path accessToken:accessToken cursor:cursor accumulatedFiles:newlyAccumulatedFiles completion:completion];
                } else {
                    // We can't load more without a cursor
                    completion(nil, error);
                }
            } else {
                // All files fetched, finish.
                completion(newlyAccumulatedFiles, error);
            }
        } else {
            completion(nil, error);
        }
    }];
}

#pragma mark - File Manipulation

+ (void)downloadFileAtPath:(NSString *const)remotePath toPath:(NSString *const)localPath accessToken:(NSString *const)accessToken completion:(void (^const)(NSDictionary *_Nullable parsedResponse, NSError *_Nullable error))completion
{
    NSURLRequest *const request = [self contentRequestWithPath:@"/2/files/download" accessToken:accessToken parameters:@{
        @"path": remotePath
    }];
    
    [[[self session] downloadTaskWithRequest:request completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSDictionary *parsedResult = nil;
        NSHTTPURLResponse *const httpURLResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSString *const resultString = httpURLResponse.allHeaderFields[@"Dropbox-API-Result"];
        NSData *const resultData = [resultString dataUsingEncoding:NSUTF8StringEncoding];
        [self processResultJSONData:resultData response:response error:&error parsedResult:&parsedResult];
        
        if (!error && location) {
            // Move file into place
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:localPath] error:&error];
        }
        
        completion(parsedResult, error);
    }] resume];
}

+ (void)deleteFileAtPath:(NSString *const)path accessToken:(NSString *const)accessToken completion:(void (^const)(NSDictionary *_Nullable parsedResponse, NSError *_Nullable error))completion
{
    NSURLRequest *const request = [self apiRequestWithPath:@"/2/files/delete" accessToken:accessToken parameters:@{
        @"path": path
    }];
    [self performRequest:request withCompletion:completion];
}

#pragma mark - Sharing

+ (void)getSharedLinkForFileAtPath:(NSString *const)path accessToken:(NSString *const)accessToken completion:(void (^const)(NSString *_Nullable urlString))completion
{
    NSURLRequest *const request = [self apiRequestWithPath:@"/2/sharing/create_shared_link_with_settings" accessToken:accessToken parameters:@{
        @"path": path
    }];
    [self performRequest:request withCompletion:^(NSDictionary * _Nullable parsedResponse, NSError * _Nullable error) {
        completion(parsedResponse[@"url"]);
    }];
}

@end