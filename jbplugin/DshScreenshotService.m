//
// DshScreenshotService.m
//
// 注入 SpringBoard，监听本机回环端口，按请求截一张整屏返回 PNG。
//
// 为什么需要它：App 在自己的沙盒进程里，`UIGetScreenImage` 只能拿到本进程
// 的图层，截别的 App 就是一张纯黑。只有住在 SpringBoard 里的代码才看得见
// 整个屏幕——Snapper 3 能截图正是这个原因。
//
// 为什么全部走 dlopen + dlsym（这一条是关键）：
//
//   链接期一碰 UIKit / CoreGraphics，arm64e 上的 dylib 就会生成需要指针
//   认证（PAC）的 chained fixup。未正确签名时 SpringBoard 在 libobjc 加载
//   阶段直接崩，崩因写着 "possible pointer authentication failure"，手机
//   进安全模式。实测 DshScreenshotService 之前正是这么崩的。
//
//   只链 Foundation 的探针（DshProbe）能稳定注入。所以这里链接期只留
//   Foundation，UIKit 和 CoreGraphics 的符号全部运行时解析。
//
// 只做一件事：把屏幕像素交出去。不做点按、不做输入、不读剪贴板、不联网。
// 只监听 127.0.0.1，并且要求请求里带上约定密钥。
//

#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// 与 App 侧约定的端口和密钥。改这里就要同时改 App 侧。
static const int kDshScreenPort = 47191;
static NSString *const kDshSharedKey = @"dsh-go-screen-v1";

#pragma mark - 运行时符号

typedef struct {
  void *uikit;
  void *coregraphics;
  // CoreGraphics C 函数
  size_t (*imageGetWidth)(void *);
  void (*imageRelease)(void *);
  void (*imageRetain)(void *);
  // UIKit C 函数
  void *(*screenImage)(void);              // UIGetScreenImage -> CGImageRef
  void *(*uiCreateScreenImage)(void);      // _UICreateScreenUIImage -> UIImage*
  void *(*pngRepresentation)(void *);      // UIImagePNGRepresentation -> NSData*
  // ObjC
  Class imageClass;                        // UIImage
  SEL imageWithCGImage;                    // +imageWithCGImage:
  BOOL ready;
} DshScreenSymbols;

static DshScreenSymbols gSymbols;

static void *DshLookup(void *handle, const char *name) {
  if (!handle || !name) return NULL;
  return dlsym(handle, name);
}

/// 懒加载：注入的那一刻 SpringBoard 可能还没把 UIKit 初始化完，所以每个
/// 请求进来时才解析一次。解析失败返回 NO，调用方据此回 503。
static BOOL DshLoadSymbols(void) {
  if (gSymbols.ready) return YES;

  if (!gSymbols.uikit) {
    gSymbols.uikit = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_LOCAL);
  }
  if (!gSymbols.coregraphics) {
    gSymbols.coregraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                                   RTLD_NOW | RTLD_LOCAL);
  }
  if (!gSymbols.uikit) return NO;

  // CoreGraphics 的函数在 UIKit 里也能找到（UIKit 重导出 CG）。
  void *cg = gSymbols.coregraphics ? gSymbols.coregraphics : gSymbols.uikit;
  gSymbols.imageGetWidth = (size_t (*)(void *))DshLookup(cg, "CGImageGetWidth");
  gSymbols.imageRelease = (void (*)(void *))DshLookup(cg, "CGImageRelease");
  gSymbols.imageRetain = (void *(*)(void *))DshLookup(cg, "CGImageRetain");

  // UIKit 的整屏接口。UIGetScreenImage 是私有函数，_UICreateScreenUIImage 是
  // 更新一些的替代品，两者都试。
  gSymbols.screenImage = (void *(*)(void))DshLookup(gSymbols.uikit, "UIGetScreenImage");
  if (!gSymbols.screenImage) {
    gSymbols.screenImage = (void *(*)(void))DshLookup(NULL, "UIGetScreenImage");
  }
  gSymbols.uiCreateScreenImage = (void *(*)(void))DshLookup(gSymbols.uikit, "_UICreateScreenUIImage");

  gSymbols.pngRepresentation = (void *(*)(void *))DshLookup(gSymbols.uikit, "UIImagePNGRepresentation");

  gSymbols.imageClass = NSClassFromString(@"UIImage");
  gSymbols.imageWithCGImage = NSSelectorFromString(@"imageWithCGImage:");

  gSymbols.ready = (gSymbols.screenImage || gSymbols.uiCreateScreenImage) &&
                   gSymbols.pngRepresentation && gSymbols.imageClass != Nil;
  return gSymbols.ready;
}

#pragma mark - 抓屏

/// 拿一张整屏 PNG。在 SpringBoard 里 UIGetScreenImage 得到的就是当前显示的一切。
static NSData *DshCapturePNG(void) {
  if (!DshLoadSymbols()) return nil;

  // 路线一：UIGetScreenImage → CGImageRef → UIImage → PNG
  if (gSymbols.screenImage) {
    void *cgImage = gSymbols.screenImage();
    if (cgImage) {
      if (gSymbols.imageGetWidth && gSymbols.imageGetWidth(cgImage) > 0) {
        id image = ((id (*)(id, SEL, void *))objc_msgSend)(
            (id)gSymbols.imageClass, gSymbols.imageWithCGImage, cgImage);
        NSData *png = image ? gSymbols.pngRepresentation(image) : nil;
        if (gSymbols.imageRelease) gSymbols.imageRelease(cgImage);
        if (png.length > 0) return png;
      } else if (gSymbols.imageRelease) {
        gSymbols.imageRelease(cgImage);
      }
    }
  }

  // 路线二：_UICreateScreenUIImage 直接给 UIImage
  if (gSymbols.uiCreateScreenImage) {
    id image = ((id (*)(void))gSymbols.uiCreateScreenImage)();
    if (image) {
      NSData *png = gSymbols.pngRepresentation(image);
      if (png.length > 0) return png;
    }
  }

  return nil;
}

#pragma mark - HTTP

static void DshWriteAll(int fd, const void *bytes, size_t length) {
  const uint8_t *p = (const uint8_t *)bytes;
  size_t written = 0;
  while (written < length) {
    ssize_t n = write(fd, p + written, length - written);
    if (n <= 0) return;
    written += (size_t)n;
  }
}

static void DshRespond(int fd, int status, const char *reason,
                       const void *body, size_t bodyLength,
                       const char *contentType) {
  char header[512];
  int headerLength = snprintf(header, sizeof(header),
      "HTTP/1.1 %d %s\r\n"
      "Content-Type: %s\r\n"
      "Content-Length: %zu\r\n"
      "Cache-Control: no-store\r\n"
      "Connection: close\r\n"
      "\r\n",
      status, reason, contentType, bodyLength);
  DshWriteAll(fd, header, (size_t)headerLength);
  if (body && bodyLength) DshWriteAll(fd, body, bodyLength);
}

static void DshHandleClient(int fd) {
  char request[2048] = {0};
  ssize_t got = read(fd, request, sizeof(request) - 1);
  if (got <= 0) { close(fd); return; }
  request[got] = '\0';

  NSString *raw = [NSString stringWithUTF8String:request];
  BOOL authorized = raw && [raw containsString:kDshSharedKey];
  BOOL wantsCapture = raw && [raw rangeOfString:@"GET /capture"].location != NSNotFound;

  if (!authorized) {
    DshRespond(fd, 403, "Forbidden", "denied", 6, "text/plain");
    close(fd);
    return;
  }
  if (!wantsCapture) {
    // 健康检查：App 用它确认插件在不在。
    DshRespond(fd, 200, "OK", "dsh-screen", 10, "text/plain");
    close(fd);
    return;
  }

  NSData *png = DshCapturePNG();
  if (!png || png.length == 0) {
    DshRespond(fd, 503, "Unavailable", "nocapture", 9, "text/plain");
  } else {
    DshRespond(fd, 200, "OK", png.bytes, (size_t)png.length, "image/png");
  }
  close(fd);
}

#pragma mark - 监听

@interface DshScreenshotService : NSObject
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation DshScreenshotService

+ (instancetype)shared {
  static DshScreenshotService *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [[DshScreenshotService alloc] init]; });
  return shared;
}

- (void)startWithLog:(void (^)(NSString *))log {
  if (self.listenFD > 0) return;
  self.queue = dispatch_queue_create("dsh.screen.service", DISPATCH_QUEUE_SERIAL);

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) { log([NSString stringWithFormat:@"socket failed errno=%d\n", errno]); return; }
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(kDshScreenPort);
  // 只绑回环，局域网里别的设备连不上。
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    log([NSString stringWithFormat:@"bind failed errno=%d\n", errno]);
    close(fd);
    return;
  }
  if (listen(fd, 8) < 0) {
    log([NSString stringWithFormat:@"listen failed errno=%d\n", errno]);
    close(fd);
    return;
  }
  self.listenFD = fd;
  log([NSString stringWithFormat:@"listening on 127.0.0.1:%d\n", kDshScreenPort]);

  dispatch_async(self.queue, ^{
    while (YES) {
      int client = accept(fd, NULL, NULL);
      if (client < 0) break;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DshHandleClient(client);
      });
    }
  });
}

@end

#pragma mark - 注入

__attribute__((constructor))
static void DshScreenshotServiceInit(void) {
  @autoreleasepool {
    // 构造函数一进来就落一行日志。这是判断「插件到底有没有被注入」的唯一
    // 可靠手段：端口不通可能是 bind 失败、也可能是根本没被加载，两者要分开。
    NSString *logPath = @"/var/mobile/dsh-screen-plugin.log";
    void (^log)(NSString *) = ^(NSString *line) {
      NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
      if (!handle) {
        [line writeToFile:logPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
      } else {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
      }
    };
    log([NSString stringWithFormat:@"constructor entered uid=%d pid=%d\n", getuid(), getpid()]);

    // SpringBoard 启动期还没把窗口树搭好，等几秒再开监听。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [[DshScreenshotService shared] startWithLog:log];
    });
  }
}
