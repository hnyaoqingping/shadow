// Shadow by jjolano

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Includes/Shadow.h"

Shadow *_shadow = nil;

const char *self_image_name = NULL;

NSArray *dyld_array = nil;
uint32_t dyld_array_count = 0;

// Stable Hooks
%group hook_libc
// #include "Hooks/Stable/libc.xm"
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>
#include <spawn.h>
#include <fcntl.h>
#include <errno.h>

%hookf(int, access, const char *pathname, int mode) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    // workaround for tweaks not loading properly in Substrate
    if([_shadow useInjectCompatibilityMode] && [[path pathExtension] isEqualToString:@"plist"] && [path containsString:@"DynamicLibraries/"]) {
        return %orig;
    }

    if([_shadow isPathRestricted:path]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}

%hookf(char *, getenv, const char *name) {
    if(!name) {
        return %orig;
    }

    NSString *env = [NSString stringWithUTF8String:name];

    if([env isEqualToString:@"DYLD_INSERT_LIBRARIES"]
    || [env isEqualToString:@"_MSSafeMode"]
    || [env isEqualToString:@"_SafeMode"]) {
        return NULL;
    }

    return %orig;
}

%hookf(FILE *, fopen, const char *pathname, const char *mode) {
    if(!pathname) {
        return %orig;
    }
    
    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return NULL;
    }

    return %orig;
}

%hookf(int, stat, const char *pathname, struct stat *statbuf) {
    if(!pathname) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}

%hookf(int, lstat, const char *pathname, struct stat *statbuf) {
    if(!pathname) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}

%hookf(int, statfs, const char *path, struct statfs *buf) {
    if(!path) {
        return %orig;
    }

    int ret = %orig;

    if(ret == 0) {
        NSString *pathname = [NSString stringWithUTF8String:path];

        if([_shadow isPathRestricted:pathname]) {
            errno = ENOENT;
            return -1;
        }

        pathname = [_shadow resolveLinkInPath:pathname];
        
        if(![pathname hasPrefix:@"/var"]
        && ![pathname hasPrefix:@"/private/var"]) {
            if(buf) {
                // Ensure root is marked read-only.
                buf->f_flags |= MNT_RDONLY;
                return ret;
            }
        }
    }

    return ret;
}

%hookf(int, posix_spawn, pid_t *pid, const char *pathname, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    if([_shadow isPathRestricted:path]) {
        return ENOSYS;
    }

    return %orig;
}

%hookf(int, posix_spawnp, pid_t *pid, const char *pathname, const posix_spawn_file_actions_t *file_actions, const posix_spawnattr_t *attrp, char *const argv[], char *const envp[]) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    if([_shadow isPathRestricted:path]) {
        return ENOSYS;
    }

    return %orig;
}

%hookf(char *, realpath, const char *pathname, char *resolved_path) {
    if(!pathname) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return NULL;
    }

    return %orig;
}

%hookf(int, symlink, const char *path1, const char *path2) {
    if(!path1 || !path2) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:path1]] || [_shadow isPathRestricted:[NSString stringWithUTF8String:path2]]) {
        errno = ENOENT;
        return -1;
    }

    int ret = %orig;

    if(ret == 0) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[NSString stringWithUTF8String:path1] toPath:[NSString stringWithUTF8String:path2]];
    }

    return ret;
}

%hookf(int, link, const char *path1, const char *path2) {
    if(!path1 || !path2) {
        return %orig;
    }

    if([_shadow isPathRestricted:[NSString stringWithUTF8String:path1]] || [_shadow isPathRestricted:[NSString stringWithUTF8String:path2]]) {
        errno = ENOENT;
        return -1;
    }

    int ret = %orig;

    if(ret == 0) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[NSString stringWithUTF8String:path1] toPath:[NSString stringWithUTF8String:path2]];
    }

    return ret;
}

%hookf(int, fstatat, int dirfd, const char *pathname, struct stat *buf, int flags) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    if(![path isAbsolutePath]) {
        // Get path of dirfd.
        char dirfdpath[PATH_MAX];
    
        if(fcntl(dirfd, F_GETPATH, dirfdpath) != -1) {
            NSString *dirfd_path = [NSString stringWithUTF8String:dirfdpath];
            path = [dirfd_path stringByAppendingPathComponent:path];
        }
    }
    
    if([_shadow isPathRestricted:path]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}
%end

%group hook_libc_inject
%hookf(int, fstat, int fd, struct stat *buf) {
    // Get path of dirfd.
    char fdpath[PATH_MAX];

    if(fcntl(fd, F_GETPATH, fdpath) != -1) {
        NSString *fd_path = [NSString stringWithUTF8String:fdpath];
        
        if([_shadow isPathRestricted:fd_path]) {
            errno = EBADF;
            return -1;
        }
    }

    return %orig;
}
/*
%hookf(int, open, const char *pathname, int flags) {
    if(pathname && [_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}

%hookf(int, openat, int dirfd, const char *pathname, int flags) {
    if(!pathname) {
        return %orig;
    }

    NSString *path = [NSString stringWithUTF8String:pathname];

    if(![path isAbsolutePath]) {
        // Get path of dirfd.
        char dirfdpath[PATH_MAX];
    
        if(fcntl(dirfd, F_GETPATH, dirfdpath) != -1) {
            NSString *dirfd_path = [NSString stringWithUTF8String:dirfdpath];
            path = [dirfd_path stringByAppendingPathComponent:path];
        }
    }
    
    if([_shadow isPathRestricted:path]) {
        errno = ENOENT;
        return -1;
    }

    return %orig;
}
*/
%end

%group hook_dlopen_inject
%hookf(void *, dlopen, const char *path, int mode) {
    if(!path) {
        return %orig;
    }

    NSString *image_name = [NSString stringWithUTF8String:path];

    if([_shadow isImageRestricted:image_name]) {
        return NULL;
    }

    return %orig;
}
%end

%group hook_NSFileHandle
// #include "Hooks/Stable/NSFileHandle.xm"
%hook NSFileHandle
+ (instancetype)fileHandleForReadingAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForReadingFromURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForWritingAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForWritingToURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForUpdatingAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)fileHandleForUpdatingURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}
%end
%end

%group hook_NSFileManager
// #include "Hooks/Stable/NSFileManager.xm"
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isReadableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isWritableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isDeletableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)isExecutableFileAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)replaceItemAtURL:(NSURL *)originalItemURL withItemAtURL:(NSURL *)newItemURL backupItemName:(NSString *)backupItemName options:(NSFileManagerItemReplacementOptions)options resultingItemURL:(NSURL * _Nullable *)resultingURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:originalItemURL manager:self] || [_shadow isURLRestricted:newItemURL manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    // Filter array.
    NSMutableArray *filtered_ret = nil;
    NSArray *ret = %orig;

    if(ret) {
        filtered_ret = [NSMutableArray new];

        for(NSURL *ret_url in ret) {
            if(![_shadow isURLRestricted:ret_url manager:self]) {
                [filtered_ret addObject:ret_url];
            }
        }
    }

    return ret ? [filtered_ret copy] : ret;
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    // Filter array.
    NSMutableArray *filtered_ret = nil;
    NSArray *ret = %orig;

    if(ret) {
        filtered_ret = [NSMutableArray new];

        for(NSString *ret_path in ret) {
            // Ensure absolute path for path.
            if(![_shadow isPathRestricted:[path stringByAppendingPathComponent:ret_path] manager:self]) {
                [filtered_ret addObject:ret_path];
            }
        }
    }

    return ret ? [filtered_ret copy] : ret;
}

- (NSDirectoryEnumerator<NSURL *> *)enumeratorAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask errorHandler:(BOOL (^)(NSURL *url, NSError *error))handler {
    if([_shadow isURLRestricted:url manager:self]) {
        return %orig([NSURL fileURLWithPath:@"file:///.file"], keys, mask, handler);
    }

    return %orig;
}

- (NSDirectoryEnumerator<NSString *> *)enumeratorAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return %orig(@"/.file");
    }

    return %orig;
}

- (NSArray<NSString *> *)subpathsOfDirectoryAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    // Filter array.
    NSMutableArray *filtered_ret = nil;
    NSArray *ret = %orig;

    if(ret) {
        filtered_ret = [NSMutableArray new];

        for(NSString *ret_path in ret) {
            // Ensure absolute path for path.
            if(![_shadow isPathRestricted:[path stringByAppendingPathComponent:ret_path] manager:self]) {
                [filtered_ret addObject:ret_path];
            }
        }
    }

    return ret ? [filtered_ret copy] : ret;
}

- (NSArray<NSString *> *)subpathsAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return nil;
    }

    // Filter array.
    NSMutableArray *filtered_ret = nil;
    NSArray *ret = %orig;

    if(ret) {
        filtered_ret = [NSMutableArray new];

        for(NSString *ret_path in ret) {
            // Ensure absolute path for path.
            if(![_shadow isPathRestricted:[path stringByAppendingPathComponent:ret_path] manager:self]) {
                [filtered_ret addObject:ret_path];
            }
        }
    }

    return ret ? [filtered_ret copy] : ret;
}

- (BOOL)copyItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:srcURL manager:self] || [_shadow isURLRestricted:dstURL manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:srcPath manager:self] || [_shadow isPathRestricted:dstPath manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)moveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:srcURL manager:self] || [_shadow isURLRestricted:dstURL manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:srcPath manager:self] || [_shadow isPathRestricted:dstPath manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (NSArray<NSString *> *)componentsToDisplayForPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return nil;
    }

    return %orig;
}

- (NSString *)displayNameAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return path;
    }

    return %orig;
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfItemAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (NSDictionary<NSFileAttributeKey, id> *)attributesOfFileSystemForPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes ofItemAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (NSData *)contentsAtPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return nil;
    }

    return %orig;
}

- (BOOL)contentsEqualAtPath:(NSString *)path1 andPath:(NSString *)path2 {
    if([_shadow isPathRestricted:path1] || [_shadow isPathRestricted:path2]) {
        return NO;
    }

    return %orig;
}

- (BOOL)getRelationship:(NSURLRelationship *)outRelationship ofDirectoryAtURL:(NSURL *)directoryURL toItemAtURL:(NSURL *)otherURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:directoryURL manager:self] || [_shadow isURLRestricted:otherURL manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)getRelationship:(NSURLRelationship *)outRelationship ofDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domainMask toItemAtURL:(NSURL *)otherURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:otherURL manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)changeCurrentDirectoryPath:(NSString *)path {
    if([_shadow isPathRestricted:path manager:self]) {
        return NO;
    }

    return %orig;
}

- (BOOL)createSymbolicLinkAtURL:(NSURL *)url withDestinationURL:(NSURL *)destURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url manager:self] || [_shadow isURLRestricted:destURL manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[url path] toPath:[destURL path]];
    }

    return ret;
}

- (BOOL)createSymbolicLinkAtPath:(NSString *)path withDestinationPath:(NSString *)destPath error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path] || [_shadow isPathRestricted:destPath]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:path toPath:destPath];
    }

    return ret;
}

- (BOOL)linkItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:srcURL manager:self] || [_shadow isURLRestricted:dstURL manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:[srcURL path] toPath:[dstURL path]];
    }

    return ret;
}

- (BOOL)linkItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:srcPath manager:self] || [_shadow isPathRestricted:dstPath manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    BOOL ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:srcPath toPath:dstPath];
    }

    return ret;
}

- (NSString *)destinationOfSymbolicLinkAtPath:(NSString *)path error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path manager:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    NSString *ret = %orig;

    if(ret) {
        // Track this symlink in Shadow
        [_shadow addLinkFromPath:path toPath:ret];
    }

    return ret;
}
%end
%end

%group hook_NSEnumerator
%hook NSEnumerator
- (id)nextObject {
    if([self isKindOfClass:[NSDirectoryEnumerator class]]) {
        id ret = nil;

        while((ret = %orig)) {
            if([ret isKindOfClass:[NSURL class]]) {
                if([_shadow isURLRestricted:ret]) {
                    continue;
                }
            }

            if([ret isKindOfClass:[NSString class]]) {
                // TODO: convert to absolute path
            }

            break;
        }

        return ret;
    }

    return %orig;
}
%end
%end

%group hook_NSURL
// #include "Hooks/Stable/NSURL.xm"
%hook NSURL
- (BOOL)checkResourceIsReachableAndReturnError:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:self]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}
%end
%end

%group hook_UIApplication
// #include "Hooks/Stable/UIApplication.xm"
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if([_shadow isURLRestricted:url]) {
        return NO;
    }

    return %orig;
}
%end
%end

%group hook_NSBundle
// #include "Hooks/Testing/NSBundle.xm"
%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if([key isEqualToString:@"SignerIdentity"]) {
        return nil;
    }

    return %orig;
}
%end
%end

%group hook_CoreFoundation
%hookf(CFArrayRef, CFBundleGetAllBundles) {
    CFArrayRef cfbundles = %orig;
    CFIndex cfcount = CFArrayGetCount(cfbundles);

    NSMutableArray *filter = [NSMutableArray new];
    NSMutableArray *bundles = [NSMutableArray arrayWithArray:(__bridge NSArray *) cfbundles];

    // Filter return value.
    int i;
    for(i = 0; i < cfcount; i++) {
        CFBundleRef cfbundle = (CFBundleRef) CFArrayGetValueAtIndex(cfbundles, i);
        CFURLRef cfbundle_cfurl = CFBundleCopyExecutableURL(cfbundle);

        if(cfbundle_cfurl) {
            NSURL *bundle_url = (__bridge NSURL *) cfbundle_cfurl;

            if([_shadow isURLRestricted:bundle_url]) {
                continue;
            }
        }

        [filter addObject:bundles[i]];
    }

    return (__bridge CFArrayRef) [filter copy];
}

/*
%hookf(CFReadStreamRef, CFReadStreamCreateWithFile, CFAllocatorRef alloc, CFURLRef fileURL) {
    NSURL *nsurl = (__bridge NSURL *)fileURL;

    if([nsurl isFileURL] && [_shadow isPathRestricted:[nsurl path] partial:NO]) {
        return NULL;
    }

    return %orig;
}

%hookf(CFWriteStreamRef, CFWriteStreamCreateWithFile, CFAllocatorRef alloc, CFURLRef fileURL) {
    NSURL *nsurl = (__bridge NSURL *)fileURL;

    if([nsurl isFileURL] && [_shadow isPathRestricted:[nsurl path] partial:NO]) {
        return NULL;
    }

    return %orig;
}

%hookf(CFURLRef, CFURLCreateFilePathURL, CFAllocatorRef allocator, CFURLRef url, CFErrorRef *error) {
    NSURL *nsurl = (__bridge NSURL *)url;

    if([nsurl isFileURL] && [_shadow isPathRestricted:[nsurl path] partial:NO]) {
        if(error) {
            *error = (__bridge CFErrorRef) [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }
        
        return NULL;
    }

    return %orig;
}

%hookf(CFURLRef, CFURLCreateFileReferenceURL, CFAllocatorRef allocator, CFURLRef url, CFErrorRef *error) {
    NSURL *nsurl = (__bridge NSURL *)url;

    if([nsurl isFileURL] && [_shadow isPathRestricted:[nsurl path] partial:NO]) {
        if(error) {
            *error = (__bridge CFErrorRef) [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }
        
        return NULL;
    }

    return %orig;
}
*/
%end

%group hook_NSUtilities
%hook UIImage
- (instancetype)initWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (UIImage *)imageWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}
%end

/*
%hook NSData
- (id)initWithContentsOfMappedFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (id)dataWithContentsOfMappedFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

- (instancetype)initWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}

- (instancetype)initWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)readOptionsMask error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)readOptionsMask error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }
        
        return nil;
    }

    return %orig;
}

+ (instancetype)dataWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)dataWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (instancetype)dataWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)readOptionsMask error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (instancetype)dataWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)readOptionsMask error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}
%end
*/

%hook NSMutableArray
- (id)initWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

- (id)initWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (id)arrayWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (id)arrayWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}
%end

%hook NSArray
- (id)initWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (id)arrayWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (id)arrayWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}
%end

%hook NSMutableDictionary
- (id)initWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

- (id)initWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}
%end

%hook NSDictionary
- (id)initWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

- (id)initWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}

- (id)initWithContentsOfURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (id)dictionaryWithContentsOfFile:(NSString *)path {
    if([_shadow isPathRestricted:path partial:NO]) {
        return nil;
    }

    return %orig;
}

+ (id)dictionaryWithContentsOfURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (id)dictionaryWithContentsOfURL:(NSURL *)url {
    if([_shadow isURLRestricted:url partial:NO]) {
        return nil;
    }

    return %orig;
}
%end

%hook NSString
- (instancetype)initWithContentsOfFile:(NSString *)path encoding:(NSStringEncoding)enc error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

- (instancetype)initWithContentsOfFile:(NSString *)path usedEncoding:(NSStringEncoding *)enc error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (instancetype)stringWithContentsOfFile:(NSString *)path encoding:(NSStringEncoding)enc error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}

+ (instancetype)stringWithContentsOfFile:(NSString *)path usedEncoding:(NSStringEncoding *)enc error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return nil;
    }

    return %orig;
}
%end
%end

// Other Hooks
%group hook_private
// #include "Hooks/ApplePrivate.xm"
#include <unistd.h>
#include "Includes/codesign.h"

%hookf(int, csops, pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    int ret = %orig;

    if(ops == CS_OPS_STATUS && (ret & CS_PLATFORM_BINARY) && pid == getpid()) {
        // Ensure that the platform binary flag is not set.
        ret &= ~CS_PLATFORM_BINARY;
    }

    return ret;
}
%end

%group hook_debugging
// #include "Hooks/Debugging.xm"
#include <sys/sysctl.h>
#include <unistd.h>
#include <fcntl.h>

%hookf(int, sysctl, int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = %orig;

    if(ret == 0
    && name[0] == CTL_KERN
    && name[1] == KERN_PROC
    && name[2] == KERN_PROC_PID
    && name[3] == getpid()) {
        // Remove trace flag.
        if(oldp) {
            struct kinfo_proc *p = ((struct kinfo_proc *) oldp);

            if(p->kp_proc.p_flag & P_TRACED) {
                p->kp_proc.p_flag &= ~P_TRACED;
            }
        }
    }

    return ret;
}

%hookf(pid_t, getppid) {
    return 1;
}

/*
%hookf(int, "_ptrace", int request, pid_t pid, caddr_t addr, int data) {
    // PTRACE_DENY_ATTACH = 31
    if(request == 31) {
        return 0;
    }

    return %orig;
}
*/
%end

%group hook_dyld_image
// #include "Hooks/dyld.xm"
#include <mach-o/dyld.h>

%hookf(uint32_t, _dyld_image_count) {
    if(dyld_array_count > 0) {
        return dyld_array_count;
    }

    return %orig;
}

%hookf(const char *, _dyld_get_image_name, uint32_t image_index) {
    if(dyld_array_count > 0) {
        if(image_index >= dyld_array_count) {
            return NULL;
        }

        image_index = (uint32_t) [dyld_array[image_index] unsignedIntValue];
    }

    // Basic filter.
    const char *ret = %orig(image_index);

    if(ret && [_shadow isImageRestricted:[NSString stringWithUTF8String:ret]]) {
        return self_image_name ? self_image_name : %orig(0);
    }

    return ret;
}

%hookf(const struct mach_header *, _dyld_get_image_header, uint32_t image_index) {
    if(dyld_array_count > 0) {
        if(image_index >= dyld_array_count) {
            return NULL;
        }

        // image_index = (uint32_t) [dyld_array[image_index] unsignedIntValue];
    }

    return %orig(image_index);
}

%hookf(intptr_t, _dyld_get_image_vmaddr_slide, uint32_t image_index) {
    if(dyld_array_count > 0) {
        if(image_index >= dyld_array_count) {
            return 0;
        }

        // image_index = (uint32_t) [dyld_array[image_index] unsignedIntValue];
    }

    return %orig(image_index);
}

%hookf(bool, dlopen_preflight, const char *path) {
    if(path) {
        NSString *image_name = [NSString stringWithUTF8String:path];

        if([_shadow isImageRestricted:image_name]) {
            NSLog(@"blocked dlopen_preflight: %@", image_name);
            return false;
        }
    }

    return %orig;
}
%end

%group hook_dyld_advanced
%hookf(int32_t, NSVersionOfRunTimeLibrary, const char *libraryName) {
    if(libraryName) {
        NSString *name = [NSString stringWithUTF8String:libraryName];

        if([_shadow isImageRestricted:name]) {
            return -1;
        }
    }
    
    return %orig;
}

%hookf(int32_t, NSVersionOfLinkTimeLibrary, const char *libraryName) {
    if(libraryName) {
        NSString *name = [NSString stringWithUTF8String:libraryName];

        if([_shadow isImageRestricted:name]) {
            return -1;
        }
    }
    
    return %orig;
}

%hookf(void, _dyld_register_func_for_add_image, void (*func)(const struct mach_header *mh, intptr_t vmaddr_slide)) {
    %orig;
}

%hookf(void, _dyld_register_func_for_remove_image, void (*func)(const struct mach_header *mh, intptr_t vmaddr_slide)) {
    %orig;
}
%end

/*
%group hook_dyld_dlsym
// #include "Hooks/dlsym.xm"
#include <dlfcn.h>

%hookf(void *, dlsym, void *handle, const char *symbol) {
    if(!symbol) {
        return %orig;
    }

    NSString *sym = [NSString stringWithUTF8String:symbol];

    if([sym hasPrefix:@"MS"]
    || [sym hasPrefix:@"Sub"]
    || [sym hasPrefix:@"PS"]) {
        NSLog(@"blocked dlsym lookup: %@", sym);
        return NULL;
    }

    return %orig;
}
%end
*/

%group hook_sandbox
// #include "Hooks/Sandbox.xm"
#include <stdio.h>
#include <unistd.h>

%hook NSArray
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile {
    if([_shadow isPathRestricted:path partial:NO]) {
        return NO;
    }

    return %orig;
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)atomically {
    if([_shadow isURLRestricted:url partial:NO]) {
        return NO;
    }

    return %orig;
}
%end

%hook NSDictionary
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile {
    if([_shadow isPathRestricted:path partial:NO]) {
        return NO;
    }

    return %orig;
}

- (BOOL)writeToURL:(NSURL *)url error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)atomically {
    if([_shadow isURLRestricted:url partial:NO]) {
        return NO;
    }

    return %orig;
}
%end

%hook NSData
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile {
    if([_shadow isPathRestricted:path partial:NO]) {
        return NO;
    }

    return %orig;
}

- (BOOL)writeToFile:(NSString *)path options:(NSDataWritingOptions)writeOptionsMask error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)useAuxiliaryFile {
    if([_shadow isURLRestricted:url partial:NO]) {
        return NO;
    }

    return %orig;
}

- (BOOL)writeToURL:(NSURL *)url options:(NSDataWritingOptions)writeOptionsMask error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}
%end

%hook NSString
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile encoding:(NSStringEncoding)enc error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)useAuxiliaryFile encoding:(NSStringEncoding)enc error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}
%end

%hook NSFileManager
- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes error:(NSError * _Nullable *)error {
    if([_shadow isURLRestricted:url partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes error:(NSError * _Nullable *)error {
    if([_shadow isPathRestricted:path partial:NO]) {
        if(error) {
            *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSFileNoSuchFileError userInfo:nil];
        }

        return NO;
    }

    return %orig;
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary<NSFileAttributeKey, id> *)attr {
    if([_shadow isPathRestricted:path partial:NO]) {
        return NO;
    }

    return %orig;
}
%end

%hookf(int, creat, const char *pathname, mode_t mode) {
    if(!pathname) {
        return %orig;
    }
    
    if([_shadow isPathRestricted:[NSString stringWithUTF8String:pathname]]) {
        errno = EACCES;
        return -1;
    }

    return %orig;
}

%hookf(pid_t, vfork) {
    errno = ENOSYS;
    return -1;
}

%hookf(pid_t, fork) {
    errno = ENOSYS;
    return -1;
}

%hookf(FILE *, popen, const char *command, const char *type) {
    errno = ENOSYS;
    return NULL;
}

%hookf(int, setgid, gid_t gid) {
    // Block setgid for root.
    if(gid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, setuid, uid_t uid) {
    // Block setuid for root.
    if(uid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, setegid, gid_t gid) {
    // Block setegid for root.
    if(gid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, seteuid, uid_t uid) {
    // Block seteuid for root.
    if(uid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(uid_t, getuid) {
    // Return uid for mobile.
    return 501;
}

%hookf(gid_t, getgid) {
    // Return gid for mobile.
    return 501;
}

%hookf(uid_t, geteuid) {
    // Return uid for mobile.
    return 501;
}

%hookf(uid_t, getegid) {
    // Return gid for mobile.
    return 501;
}

%hookf(int, setreuid, uid_t ruid, uid_t euid) {
    // Block for root.
    if(ruid == 0 || euid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}

%hookf(int, setregid, gid_t rgid, gid_t egid) {
    // Block for root.
    if(rgid == 0 || egid == 0) {
        errno = EPERM;
        return -1;
    }

    return %orig;
}
%end

%group hook_libraries
%hook UIDevice
+ (BOOL)isJailbroken {
    return NO;
}

- (BOOL)isJailBreak {
    return NO;
}

- (BOOL)isJailBroken {
    return NO;
}
%end

// %hook SFAntiPiracy
// + (int)isJailbroken {
// 	// Probably should not hook with a hard coded value.
// 	// This value may be changed by developers using this library.
// 	// Best to defeat the checks rather than skip them.
// 	return 4783242;
// }
// %end

%hook JailbreakDetectionVC
- (BOOL)isJailbroken {
    return NO;
}
%end

%hook DTTJailbreakDetection
+ (BOOL)isJailbroken {
    return NO;
}
%end

%hook ANSMetadata
- (BOOL)computeIsJailbroken {
    return NO;
}

- (BOOL)isJailbroken {
    return NO;
}
%end

%hook AppsFlyerUtils
+ (BOOL)isJailBreakon {
    return NO;
}
%end

%hook GBDeviceInfo
- (BOOL)isJailbroken {
    return NO;
}
%end

%hook CMARAppRestrictionsDelegate
- (bool)isDeviceNonCompliant {
    return false;
}
%end

%hook ADYSecurityChecks
+ (bool)isDeviceJailbroken {
    return false;
}
%end

%hook UBReportMetadataDevice
- (void *)is_rooted {
    return NULL;
}
%end

%hook UtilitySystem
+ (bool)isJailbreak {
    return false;
}
%end

%hook GemaltoConfiguration
+ (bool)isJailbreak {
    return false;
}
%end

%hook CPWRDeviceInfo
- (bool)isJailbroken {
    return false;
}
%end

%hook CPWRSessionInfo
- (bool)isJailbroken {
    return false;
}
%end

%hook KSSystemInfo
+ (bool)isJailbroken {
    return false;
}
%end

%hook EMDSKPPConfiguration
- (bool)jailBroken {
    return false;
}
%end

%hook EnrollParameters
- (void *)jailbroken {
    return NULL;
}
%end

%hook EMDskppConfigurationBuilder
- (bool)jailbreakStatus {
    return false;
}
%end

%hook FCRSystemMetadata
- (bool)isJailbroken {
    return false;
}
%end

%hook v_VDMap
- (bool)isJailBrokenDetectedByVOS {
    return false;
}
%end

%hook SDMUtils
- (BOOL)isJailBroken {
    return NO;
}
%end
%end

void init_path_map(Shadow *shadow) {
    // Restrict / by whitelisting
    [shadow addPath:@"/" restricted:YES hidden:NO];
    [shadow addPath:@"/.file" restricted:NO];
    [shadow addPath:@"/.ba" restricted:NO];
    [shadow addPath:@"/.mb" restricted:NO];
    [shadow addPath:@"/.HFS" restricted:NO];
    [shadow addPath:@"/.Trashes" restricted:NO];
    [shadow addPath:@"/AppleInternal" restricted:NO];
    [shadow addPath:@"/boot" restricted:NO];
    [shadow addPath:@"/cores" restricted:NO];
    [shadow addPath:@"/Developer" restricted:NO];
    [shadow addPath:@"/lib" restricted:NO];
    [shadow addPath:@"/mnt" restricted:NO];
    [shadow addPath:@"/sbin" restricted:NO];

    // Restrict common checks in /bin (this will be very reliant on file map now)
    [shadow addPath:@"/bin" restricted:NO];
    [shadow addPath:@"/bin/bash" restricted:YES];
    [shadow addPath:@"/bin/sh" restricted:YES];

    // Restrict /Applications
    [shadow addPath:@"/Applications" restricted:NO];
    [shadow addPath:@"/Applications/Cydia.app" restricted:YES];
    [shadow addPath:@"/Applications/Sileo.app" restricted:YES];
    [shadow addPath:@"/Applications/Zebra.app" restricted:YES];
    [shadow addPath:@"/Applications/SafeMode.app" restricted:YES];

    // Restrict /dev
    [shadow addPath:@"/dev" restricted:NO];
    [shadow addPath:@"/dev/dlci." restricted:YES];
    [shadow addPath:@"/dev/vn0" restricted:YES];
    [shadow addPath:@"/dev/vn1" restricted:YES];
    [shadow addPath:@"/dev/ptmx" restricted:YES];
    [shadow addPath:@"/dev/kmem" restricted:YES];
    [shadow addPath:@"/dev/mem" restricted:YES];

    // Restrict /private by whitelisting
    [shadow addPath:@"/private" restricted:YES hidden:NO];
    [shadow addPath:@"/private/etc" restricted:NO];
    [shadow addPath:@"/private/system_data" restricted:NO];
    [shadow addPath:@"/private/var" restricted:NO];
    [shadow addPath:@"/private/xarts" restricted:NO];

    // Restrict /etc by whitelisting
    [shadow addPath:@"/etc" restricted:YES hidden:NO];
    [shadow addPath:@"/etc/asl" restricted:NO];
    [shadow addPath:@"/etc/asl.conf" restricted:NO];
    [shadow addPath:@"/etc/fstab" restricted:NO];
    [shadow addPath:@"/etc/group" restricted:NO];
    [shadow addPath:@"/etc/hosts" restricted:NO];
    [shadow addPath:@"/etc/hosts.equiv" restricted:NO];
    [shadow addPath:@"/etc/master.passwd" restricted:NO];
    [shadow addPath:@"/etc/networks" restricted:NO];
    [shadow addPath:@"/etc/notify.conf" restricted:NO];
    [shadow addPath:@"/etc/passwd" restricted:NO];
    [shadow addPath:@"/etc/ppp" restricted:NO];
    [shadow addPath:@"/etc/profile" restricted:NO];
    [shadow addPath:@"/etc/protocols" restricted:NO];
    [shadow addPath:@"/etc/racoon" restricted:NO];
    [shadow addPath:@"/etc/services" restricted:NO];
    [shadow addPath:@"/etc/ttys" restricted:NO];
    
    // Restrict /Library by whitelisting
    [shadow addPath:@"/Library" restricted:YES hidden:NO];
    [shadow addPath:@"/Library/Application Support" restricted:YES hidden:NO];
    [shadow addPath:@"/Library/Application Support/AggregateDictionary" restricted:NO];
    [shadow addPath:@"/Library/Application Support/BTServer" restricted:NO];
    [shadow addPath:@"/Library/Audio" restricted:NO];
    [shadow addPath:@"/Library/Caches" restricted:NO];
    [shadow addPath:@"/Library/Caches/cy-" restricted:YES];
    [shadow addPath:@"/Library/Filesystems" restricted:NO];
    [shadow addPath:@"/Library/Internet Plug-Ins" restricted:NO];
    [shadow addPath:@"/Library/Keychains" restricted:NO];
    [shadow addPath:@"/Library/LaunchAgents" restricted:NO];
    [shadow addPath:@"/Library/LaunchDaemons" restricted:YES hidden:NO];
    [shadow addPath:@"/Library/Logs" restricted:NO];
    [shadow addPath:@"/Library/Managed Preferences" restricted:NO];
    [shadow addPath:@"/Library/MobileDevice" restricted:NO];
    [shadow addPath:@"/Library/MusicUISupport" restricted:NO];
    [shadow addPath:@"/Library/Preferences" restricted:NO];
    [shadow addPath:@"/Library/Printers" restricted:NO];
    [shadow addPath:@"/Library/Ringtones" restricted:NO];
    [shadow addPath:@"/Library/Updates" restricted:NO];
    [shadow addPath:@"/Library/Wallpaper" restricted:NO];
    
    // Restrict /tmp
    [shadow addPath:@"/tmp" restricted:NO];
    [shadow addPath:@"/tmp/substrate" restricted:YES];
    [shadow addPath:@"/tmp/Substrate" restricted:YES];
    [shadow addPath:@"/tmp/cydia.log" restricted:YES];
    [shadow addPath:@"/tmp/syslog" restricted:YES];
    [shadow addPath:@"/tmp/slide.txt" restricted:YES];
    [shadow addPath:@"/tmp/amfidebilitate.out" restricted:YES];
    [shadow addPath:@"/tmp/org.coolstar" restricted:YES];
    
    // Restrict /User
    [shadow addPath:@"/User" restricted:NO];
    [shadow addPath:@"/User/." restricted:YES];
    [shadow addPath:@"/User/Containers" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Containers/Data" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Containers/Data/Application" restricted:NO];
    [shadow addPath:@"/User/Containers/Data/InternalDaemon" restricted:NO];
    [shadow addPath:@"/User/Containers/Data/PluginKitPlugin" restricted:NO];
    [shadow addPath:@"/User/Containers/Data/TempDir" restricted:NO];
    [shadow addPath:@"/User/Containers/Data/VPNPlugin" restricted:NO];
    [shadow addPath:@"/User/Containers/Data/XPCService" restricted:NO];
    [shadow addPath:@"/User/Containers/Shared" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Containers/Shared/AppGroup" restricted:NO];
    [shadow addPath:@"/User/Documents" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Documents/com.apple" restricted:NO];
    [shadow addPath:@"/User/Downloads" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Downloads/com.apple" restricted:NO];
    [shadow addPath:@"/User/Library/Caches" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Library/Caches/com.apple" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/.com.apple" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/AdMob" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/AccountMigrationInProgress" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/ACMigrationLock" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/BTAvrcp" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/cache" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/Checkpoint.plist" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/ckkeyrolld" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/CloudKit" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/DateFormats.plist" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/FamilyCircle" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/GameKit" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/GeoServices" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/AccountMigrationInProgress" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/MappedImageCache" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/OTACrashCopier" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/PassKit" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/rtcreportingd" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/sharedCaches" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/Snapshots" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Library/Caches/Snapshots/com.apple" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/TelephonyUI" restricted:NO];
    [shadow addPath:@"/User/Library/Caches/Weather" restricted:NO];
    [shadow addPath:@"/User/Library/Cydia" restricted:YES];
    [shadow addPath:@"/User/Library/Logs/Cydia" restricted:YES];
    [shadow addPath:@"/User/Library/SBSettings" restricted:YES];
    [shadow addPath:@"/User/Library/Sileo" restricted:YES];
    [shadow addPath:@"/User/Library/Preferences" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Library/Preferences/com.apple." restricted:NO];
    [shadow addPath:@"/User/Library/Preferences/.GlobalPreferences.plist" restricted:NO];
    [shadow addPath:@"/User/Library/Preferences/ckkeyrolld.plist" restricted:NO];
    [shadow addPath:@"/User/Library/Preferences/nfcd.plist" restricted:NO];
    [shadow addPath:@"/User/Library/Preferences/.GlobalPreferences.plist" restricted:NO];
    [shadow addPath:@"/User/Media" restricted:YES hidden:NO];
    [shadow addPath:@"/User/Media/AirFair" restricted:NO];
    [shadow addPath:@"/User/Media/Books" restricted:NO];
    [shadow addPath:@"/User/Media/CloudAssets" restricted:NO];
    [shadow addPath:@"/User/Media/DCIM" restricted:NO];
    [shadow addPath:@"/User/Media/Downloads" restricted:NO];
    [shadow addPath:@"/User/Media/iTunes_Control" restricted:NO];
    [shadow addPath:@"/User/Media/LoFiCloudAssets" restricted:NO];
    [shadow addPath:@"/User/Media/MediaAnalysis" restricted:NO];
    [shadow addPath:@"/User/Media/PhotoData" restricted:NO];
    [shadow addPath:@"/User/Media/Photos" restricted:NO];
    [shadow addPath:@"/User/Media/Purchases" restricted:NO];
    [shadow addPath:@"/User/Media/Radio" restricted:NO];
    [shadow addPath:@"/User/Media/Recordings" restricted:NO];

    // Restrict /usr by whitelisting
    [shadow addPath:@"/usr" restricted:YES hidden:NO];
    [shadow addPath:@"/usr/bin" restricted:YES hidden:NO];
    [shadow addPath:@"/usr/lib" restricted:NO];
    [shadow addPath:@"/usr/lib/_ncurses" restricted:YES];
    [shadow addPath:@"/usr/lib/apt" restricted:YES];
    [shadow addPath:@"/usr/lib/bash" restricted:YES];
    [shadow addPath:@"/usr/lib/cycript" restricted:YES];
    [shadow addPath:@"/usr/lib/libdpkg.a" restricted:YES];
    [shadow addPath:@"/usr/lib/librocketbootstrap.dylib" restricted:YES];
    [shadow addPath:@"/usr/lib/libapplist.dylib" restricted:YES];
    [shadow addPath:@"/usr/lib/libjailbreak.dylib" restricted:YES];
    [shadow addPath:@"/usr/lib/libapt" restricted:YES];
    [shadow addPath:@"/usr/lib/libsubstitute" restricted:YES];
    [shadow addPath:@"/usr/lib/libsubstrate" restricted:YES];
    [shadow addPath:@"/usr/lib/libSubstitrate" restricted:YES];
    [shadow addPath:@"/usr/lib/TweakInject.dylib" restricted:YES];
    [shadow addPath:@"/usr/lib/TweakInject" restricted:YES];
    [shadow addPath:@"/usr/lib/pspawn" restricted:YES];
    [shadow addPath:@"/usr/lib/substrate" restricted:YES];
    [shadow addPath:@"/usr/libexec" restricted:NO];
    [shadow addPath:@"/usr/libexec/apt" restricted:YES];
    [shadow addPath:@"/usr/libexec/cydia" restricted:YES];
    [shadow addPath:@"/usr/libexec/coreutils" restricted:YES];
    [shadow addPath:@"/usr/libexec/dpkg" restricted:YES];
    [shadow addPath:@"/usr/libexec/substrate" restricted:YES];
    [shadow addPath:@"/usr/libexec/jailbreakd" restricted:YES];
    [shadow addPath:@"/usr/libexec/rocketd" restricted:YES];
    [shadow addPath:@"/usr/libexec/_rocketd_reenable" restricted:YES];
    [shadow addPath:@"/usr/local" restricted:YES hidden:NO];
    [shadow addPath:@"/usr/local/bin" restricted:YES hidden:NO];
    [shadow addPath:@"/usr/local/lib" restricted:YES hidden:NO];
    [shadow addPath:@"/usr/local/standalone" restricted:NO];
    [shadow addPath:@"/usr/sbin" restricted:YES hidden:NO];
    [shadow addPath:@"/usr/share" restricted:YES hidden:NO];
    [shadow addPath:@"/usr/share/com.apple.languageassetd" restricted:NO];
    [shadow addPath:@"/usr/share/CSI" restricted:NO];
    [shadow addPath:@"/usr/share/dict" restricted:NO];
    [shadow addPath:@"/usr/share/firmware" restricted:NO];
    [shadow addPath:@"/usr/share/icu" restricted:NO];
    [shadow addPath:@"/usr/share/langid" restricted:NO];
    [shadow addPath:@"/usr/share/locale" restricted:NO];
    [shadow addPath:@"/usr/share/mecabra" restricted:NO];
    [shadow addPath:@"/usr/share/misc" restricted:NO];
    [shadow addPath:@"/usr/share/progressui" restricted:NO];
    [shadow addPath:@"/usr/share/tokenizer" restricted:NO];
    [shadow addPath:@"/usr/share/zoneinfo" restricted:NO];
    [shadow addPath:@"/usr/share/zoneinfo.default" restricted:NO];
    [shadow addPath:@"/usr/standalone" restricted:NO];
    
    // Restrict /var by whitelisting
    [shadow addPath:@"/var" restricted:YES hidden:NO];
    [shadow addPath:@"/var/.DocumentRevisions" restricted:NO];
    [shadow addPath:@"/var/.fseventsd" restricted:NO];
    [shadow addPath:@"/var/.overprovisioning_file" restricted:NO];
    [shadow addPath:@"/var/audit" restricted:NO];
    [shadow addPath:@"/var/backups" restricted:NO];
    [shadow addPath:@"/var/buddy" restricted:NO];
    [shadow addPath:@"/var/containers" restricted:NO];
    [shadow addPath:@"/var/cores" restricted:NO];
    [shadow addPath:@"/var/db" restricted:NO];
    [shadow addPath:@"/var/db/stash" restricted:YES];
    [shadow addPath:@"/var/ea" restricted:NO];
    [shadow addPath:@"/var/empty" restricted:NO];
    [shadow addPath:@"/var/folders" restricted:NO];
    [shadow addPath:@"/var/hardware" restricted:NO];
    [shadow addPath:@"/var/installd" restricted:NO];
    [shadow addPath:@"/var/internal" restricted:NO];
    [shadow addPath:@"/var/keybags" restricted:NO];
    [shadow addPath:@"/var/Keychains" restricted:NO];
    [shadow addPath:@"/var/lib" restricted:YES hidden:NO];
    [shadow addPath:@"/var/local" restricted:NO];
    [shadow addPath:@"/var/lock" restricted:NO];
    [shadow addPath:@"/var/log" restricted:YES hidden:NO];
    [shadow addPath:@"/var/log/asl" restricted:NO];
    [shadow addPath:@"/var/log/com.apple.xpc.launchd" restricted:NO];
    [shadow addPath:@"/var/log/corecaptured.log" restricted:NO];
    [shadow addPath:@"/var/log/ppp" restricted:NO];
    [shadow addPath:@"/var/log/ppp.log" restricted:NO];
    [shadow addPath:@"/var/log/racoon.log" restricted:NO];
    [shadow addPath:@"/var/log/sa" restricted:NO];
    [shadow addPath:@"/var/logs" restricted:NO];
    [shadow addPath:@"/var/Managed Preferences" restricted:NO];
    [shadow addPath:@"/var/mobile" restricted:NO];
    [shadow addPath:@"/var/MobileAsset" restricted:NO];
    [shadow addPath:@"/var/MobileDevice" restricted:NO];
    [shadow addPath:@"/var/MobileSoftwareUpdate" restricted:NO];
    [shadow addPath:@"/var/msgs" restricted:NO];
    [shadow addPath:@"/var/networkd" restricted:NO];
    [shadow addPath:@"/var/preferences" restricted:NO];
    [shadow addPath:@"/var/root" restricted:NO];
    [shadow addPath:@"/var/run" restricted:YES hidden:NO];
    [shadow addPath:@"/var/run/lockdown" restricted:NO];
    [shadow addPath:@"/var/run/lockdown.sock" restricted:NO];
    [shadow addPath:@"/var/run/lockdown_first_run" restricted:NO];
    [shadow addPath:@"/var/run/mDNSResponder" restricted:NO];
    [shadow addPath:@"/var/run/printd" restricted:NO];
    [shadow addPath:@"/var/run/syslog" restricted:NO];
    [shadow addPath:@"/var/run/syslog.pid" restricted:NO];
    [shadow addPath:@"/var/run/utmpx" restricted:NO];
    [shadow addPath:@"/var/run/vpncontrol.sock" restricted:NO];
    [shadow addPath:@"/var/run/asl_input" restricted:NO];
    [shadow addPath:@"/var/run/configd.pid" restricted:NO];
    [shadow addPath:@"/var/run/lockbot" restricted:NO];
    [shadow addPath:@"/var/run/pppconfd" restricted:NO];
    [shadow addPath:@"/var/run/fudinit" restricted:NO];
    [shadow addPath:@"/var/spool" restricted:NO];
    [shadow addPath:@"/var/staged_system_apps" restricted:NO];
    [shadow addPath:@"/var/tmp" restricted:NO];
    [shadow addPath:@"/var/vm" restricted:NO];
    [shadow addPath:@"/var/wireless" restricted:NO];

    // Restrict /System
    [shadow addPath:@"/System" restricted:NO];
    [shadow addPath:@"/System/Library/PreferenceBundles/AppList.bundle" restricted:YES];
}

// Manual hooks
#include <dirent.h>

static int (*orig_open)(const char *path, int oflag, ...);
static int hook_open(const char *path, int oflag, ...) {
    int result = 0;

    if(path) {
        if([_shadow isPathRestricted:[NSString stringWithUTF8String:path]]) {
            errno = ((oflag & O_CREAT) == O_CREAT) ? EACCES : ENOENT;
            return -1;
        }
    }
    
    if((oflag & O_CREAT) == O_CREAT) {
        mode_t mode;
        va_list args;
        
        va_start(args, oflag);
        mode = (mode_t) va_arg(args, int);
        va_end(args);

        result = orig_open(path, oflag, mode);
    } else {
        result = orig_open(path, oflag);
    }

    return result;
}

static int (*orig_openat)(int fd, const char *path, int oflag, ...);
static int hook_openat(int fd, const char *path, int oflag, ...) {
    int result = 0;

    if(path) {
        NSString *nspath = [NSString stringWithUTF8String:path];

        if(![nspath isAbsolutePath]) {
            // Get path of dirfd.
            char dirfdpath[PATH_MAX];
        
            if(fcntl(fd, F_GETPATH, dirfdpath) != -1) {
                NSString *dirfd_path = [NSString stringWithUTF8String:dirfdpath];
                nspath = [dirfd_path stringByAppendingPathComponent:nspath];
            }
        }
        
        if([_shadow isPathRestricted:nspath]) {
            errno = ((oflag & O_CREAT) == O_CREAT) ? EACCES : ENOENT;
            return -1;
        }
    }
    
    if((oflag & O_CREAT) == O_CREAT) {
        mode_t mode;
        va_list args;
        
        va_start(args, oflag);
        mode = (mode_t) va_arg(args, int);
        va_end(args);

        result = orig_openat(fd, path, oflag, mode);
    } else {
        result = orig_openat(fd, path, oflag);
    }

    return result;
}

static DIR *(*orig_opendir)(const char *filename);
static DIR *hook_opendir(const char *filename) {
    if(filename) {
        if([_shadow isPathRestricted:[NSString stringWithUTF8String:filename]]) {
            errno = ENOENT;
            return NULL;
        }
    }

    return orig_opendir(filename);
}

static struct dirent *(*orig_readdir)(DIR *dirp);
static struct dirent *hook_readdir(DIR *dirp) {
    struct dirent *ret = NULL;
    NSString *path = nil;

    // Get path of dirfd.
    NSString *dirfd_path = nil;
    int fd = dirfd(dirp);
    char dirfdpath[PATH_MAX];

    if(fcntl(fd, F_GETPATH, dirfdpath) != -1) {
        dirfd_path = [NSString stringWithUTF8String:dirfdpath];
    } else {
        return orig_readdir(dirp);
    }

    // Filter returned results, skipping over restricted paths.
    do {
        ret = orig_readdir(dirp);

        if(ret) {
            path = [dirfd_path stringByAppendingPathComponent:[NSString stringWithUTF8String:ret->d_name]];
        } else {
            break;
        }
    } while([_shadow isPathRestricted:path]);

    return ret;
}

#include <dlfcn.h>

static void *(*orig_dlsym)(void *handle, const char *symbol);
static void *hook_dlsym(void *handle, const char *symbol) {
    void *ret = orig_dlsym(handle, symbol);

    if(ret) {
        if(strstr(symbol, "MS") == symbol
        || strstr(symbol, "Sub") == symbol
        || strstr(symbol, "PS") == symbol) {
            NSLog(@"blocked dlsym lookup: %s", symbol);
            return NULL;
        }
    }

    return ret;
}

static int (*orig_dladdr)(const void *addr, Dl_info *info);
static int hook_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);

    if(ret) {
        NSString *path = [NSString stringWithUTF8String:info->dli_fname];

        if([_shadow isImageRestricted:path]) {
            return 0;
        }
    }

    return ret;
}

static ssize_t (*orig_readlink)(const char *path, char *buf, size_t bufsiz);
static ssize_t hook_readlink(const char *path, char *buf, size_t bufsiz) {
    if(!path || !buf) {
        return orig_readlink(path, buf, bufsiz);
    }

    NSString *nspath = [NSString stringWithUTF8String:path];

    if([_shadow isPathRestricted:nspath]) {
        errno = ENOENT;
        return -1;
    }

    ssize_t ret = orig_readlink(path, buf, bufsiz);

    if(ret != -1) {
        buf[ret] = '\0';

        // Track this symlink in Shadow
        [_shadow addLinkFromPath:nspath toPath:[NSString stringWithUTF8String:buf]];
    }

    return ret;
}

static ssize_t (*orig_readlinkat)(int fd, const char *path, char *buf, size_t bufsiz);
static ssize_t hook_readlinkat(int fd, const char *path, char *buf, size_t bufsiz) {
    if(!path || !buf) {
        return orig_readlinkat(fd, path, buf, bufsiz);
    }

    NSString *nspath = [NSString stringWithUTF8String:path];

    if(![nspath isAbsolutePath]) {
        // Get path of dirfd.
        char dirfdpath[PATH_MAX];
    
        if(fcntl(fd, F_GETPATH, dirfdpath) != -1) {
            NSString *dirfd_path = [NSString stringWithUTF8String:dirfdpath];
            nspath = [dirfd_path stringByAppendingPathComponent:nspath];
        }
    }

    if([_shadow isPathRestricted:nspath]) {
        errno = ENOENT;
        return -1;
    }

    ssize_t ret = orig_readlinkat(fd, path, buf, bufsiz);

    if(ret != -1) {
        buf[ret] = '\0';

        // Track this symlink in Shadow
        [_shadow addLinkFromPath:nspath toPath:[NSString stringWithUTF8String:buf]];
    }

    return ret;
}

void updateDyldArray(void) {
    dyld_array_count = 0;
    dyld_array = [_shadow generateDyldArray];
    dyld_array_count = (uint32_t) [dyld_array count];

    NSLog(@"generated dyld array (%d items)", dyld_array_count);
}

%ctor {
    NSBundle *bundle = [NSBundle mainBundle];

    if(bundle != nil) {
        NSString *executablePath = [bundle executablePath];
        NSString *bundleIdentifier = [bundle bundleIdentifier];

        // Load preferences file
        NSMutableDictionary *prefs = [[NSMutableDictionary alloc] initWithContentsOfFile:PREFS_PATH];

        if(!prefs) {
            // Create new preferences file
            prefs = [NSMutableDictionary new];
            [prefs writeToFile:PREFS_PATH atomically:YES];
        }

        // Check if Shadow is enabled
        if(prefs[@"enabled"] && ![prefs[@"enabled"] boolValue]) {
            // Shadow disabled in preferences
            return;
        }

        // Check if safe bundleIdentifier
        if(prefs[@"exclude_system_apps"] && [prefs[@"exclude_system_apps"] boolValue]) {
            // Disable Shadow for Apple and jailbreak apps
            NSArray *excluded_bundleids = @[
                @"com.apple", // Apple apps
                @"is.workflow.my.app", // Shortcuts
                @"science.xnu.undecimus", // unc0ver
                @"com.electrateam.chimera", // Chimera
                @"org.coolstar.electra" // Electra
            ];

            for(NSString *bundle_id in excluded_bundleids) {
                if([bundleIdentifier hasPrefix:bundle_id]) {
                    return;
                }
            }
        }

        // Check if excluded bundleIdentifier
        if(prefs[@"mode"]) {
            if([prefs[@"mode"] isEqualToString:@"whitelist"]) {
                // Whitelist - disable Shadow if not enabled for this bundleIdentifier
                if(!prefs[bundleIdentifier] || ![prefs[bundleIdentifier] boolValue]) {
                    return;
                }
            } else {
                // Blacklist - disable Shadow if enabled for this bundleIdentifier
                if(prefs[bundleIdentifier] && [prefs[bundleIdentifier] boolValue]) {
                    return;
                }
            }
        }

        // Set default settings
        if(!prefs[@"dyld_hooks_enabled"]) {
            prefs[@"dyld_hooks_enabled"] = @YES;
        }

        if(!prefs[@"inject_compatibility_mode"]) {
            prefs[@"inject_compatibility_mode"] = @YES;
        }

        if(!prefs[@"bypass_checks"]) {
            prefs[@"bypass_checks"] = @YES;
        }

        // System Applications
        if([executablePath hasPrefix:@"/Applications"]) {
            return;
        }

        // User (Sandboxed) Applications
        if([executablePath hasPrefix:@"/var/containers/Bundle/Application"]) {
            NSLog(@"bundleIdentifier: %@", bundleIdentifier);

            // Initialize Shadow
            _shadow = [Shadow new];

            if(!_shadow) {
                NSLog(@"failed to initialize Shadow");
                return;
            }

            // Initialize restricted path map
            init_path_map(_shadow);
            NSLog(@"initialized internal path map");

            // Initialize file map
            if(prefs[@"auto_file_map_generation_enabled"] && [prefs[@"auto_file_map_generation_enabled"] boolValue]) {
                prefs[@"file_map"] = [Shadow generateFileMap];

                NSLog(@"scanned installed packages");
            }

            if(prefs[@"file_map"]) {
                [_shadow addPathsFromFileMap:prefs[@"file_map"]];

                NSLog(@"initialized file map (%lu items)", (unsigned long) [prefs[@"file_map"] count]);
            }

            if(prefs[@"url_set"]) {
                [_shadow addSchemesFromURLSet:prefs[@"url_set"]];

                NSLog(@"initialized url set (%lu items)", (unsigned long) [prefs[@"url_set"] count]);
            }

            // Compatibility mode
            NSString *bundleIdentifier_compat = [NSString stringWithFormat:@"tweak_compat%@", bundleIdentifier];

            [_shadow setUseTweakCompatibilityMode:YES];

            if(prefs[bundleIdentifier_compat] && [prefs[bundleIdentifier_compat] boolValue]) {
                [_shadow setUseTweakCompatibilityMode:NO];
            }

            bundleIdentifier_compat = [NSString stringWithFormat:@"inject_compat%@", bundleIdentifier];

            [_shadow setUseInjectCompatibilityMode:YES];

            if(prefs[bundleIdentifier_compat] && [prefs[bundleIdentifier_compat] boolValue]) {
                [_shadow setUseInjectCompatibilityMode:NO];
            }

            // Disable this if we are using Substitute.
            BOOL isSubstitute = [[NSFileManager defaultManager] fileExistsAtPath:@"/usr/lib/libsubstitute.dylib"];

            if(isSubstitute) {
                [_shadow setUseInjectCompatibilityMode:NO];
            }

            // Lockdown mode
            NSString *bundleIdentifier_lockdown = [NSString stringWithFormat:@"lockdown%@", bundleIdentifier];

            if(prefs[bundleIdentifier_lockdown] && [prefs[bundleIdentifier_lockdown] boolValue]) {
                %init(hook_libc_inject);
                %init(hook_dlopen_inject);

                MSHookFunction((void *) open, (void *) hook_open, (void **) &orig_open);
                MSHookFunction((void *) openat, (void *) hook_openat, (void **) &orig_openat);
                
                prefs[@"dyld_hooks_enabled"] = @YES;
                prefs[@"dyld_filter_enabled"] = @YES;

                [_shadow setUseInjectCompatibilityMode:NO];
                [_shadow setUseTweakCompatibilityMode:NO];

                NSLog(@"enabled lockdown mode");
            }

            if([_shadow useInjectCompatibilityMode]) {
                NSLog(@"using injection compatibility mode");
            } else {
                // Substitute doesn't like hooking opendir :(
                if(!isSubstitute) {
                    MSHookFunction((void *) opendir, (void *) hook_opendir, (void **) &orig_opendir);
                }

                MSHookFunction((void *) readdir, (void *) hook_readdir, (void **) &orig_readdir);
            }

            if([_shadow useTweakCompatibilityMode]) {
                NSLog(@"using tweak compatibility mode");
            }

            // Initialize stable hooks
            %init(hook_libc);
            %init(hook_NSFileHandle);
            %init(hook_NSFileManager);
            %init(hook_NSEnumerator);
            %init(hook_NSURL);
            %init(hook_UIApplication);
            %init(hook_NSBundle);
            %init(hook_NSUtilities);
            %init(hook_private);
            %init(hook_debugging);

            MSHookFunction((void *) readlink, (void *) hook_readlink, (void **) &orig_readlink);
            MSHookFunction((void *) readlinkat, (void *) hook_readlinkat, (void **) &orig_readlinkat);

            NSLog(@"hooked bypass methods");

            // Initialize other hooks
            if(prefs[@"bypass_checks"] && [prefs[@"bypass_checks"] boolValue]) {
                %init(hook_libraries);

                NSLog(@"hooked detection libraries");
            }

            if(prefs[@"dyld_hooks_enabled"] && [prefs[@"dyld_hooks_enabled"] boolValue]) {
                self_image_name = _dyld_get_image_name(0);

                %init(hook_dyld_image);

                NSLog(@"filtering dynamic libraries");
            }

            if(prefs[@"sandbox_hooks_enabled"] && [prefs[@"sandbox_hooks_enabled"] boolValue]) {
                %init(hook_sandbox);

                NSLog(@"hooked sandbox methods");
            }

            // Generate filtered dyld array
            if(prefs[@"dyld_filter_enabled"] && [prefs[@"dyld_filter_enabled"] boolValue]) {
                updateDyldArray();

                %init(hook_dyld_advanced);
                %init(hook_CoreFoundation);
                MSHookFunction((void *) dladdr, (void *) hook_dladdr, (void **) &orig_dladdr);

                NSLog(@"enabled advanced dynamic library filtering");
            }

            NSString *bundleIdentifier_dlfcn = [NSString stringWithFormat:@"dlfcn%@", bundleIdentifier];

            if(prefs[bundleIdentifier_dlfcn] && [prefs[bundleIdentifier_dlfcn] boolValue]) {
                // %init(hook_dyld_dlsym);
                MSHookFunction((void *) dlsym, (void *) hook_dlsym, (void **) &orig_dlsym);

                NSLog(@"hooked dynamic linker methods");
            }

            NSLog(@"ready");
        }
    }
}
