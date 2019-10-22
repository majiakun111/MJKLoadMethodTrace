//
//  CSMLoadMethodTracer.m
//  Pods
//
//  Created by Zhiyu_Wang on 2017/7/18.
//
//

#import "MJKLoadMethodTracer.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/getsect.h>
#import <mach-o/dyld.h>

#ifdef __LP64__
typedef uint64_t mjk_ptr;
typedef struct section_64 mjk_section;
#define GetSectByNameFromHeader getsectbynamefromheader_64
#else
typedef uint32_t mjk_ptr;
typedef struct section mjk_section;
#define GetSectByNameFromHeader getsectbynamefromheader
#endif

struct category_t {
    const char *name;
    Class cls;
    struct method_list_t *instanceMethods;
    struct method_list_t *classMethods;
};

struct method_t {
    SEL name;
    const char *types;
    IMP imp;
};

struct method_list_t {
    uint32_t entsizeAndFlags;
    uint32_t count;
    struct method_t first;
};

@interface MJKLoadMethodTracer ()

@property (nonatomic, strong) NSMutableSet<Class> *nonLazyClasses; // 有 +load 方法的类集合
@property (nonatomic, strong) NSMutableDictionary<Class, NSMutableArray *> *classCategoriesMap; // 类到它的 Category 们的对应

@end

@implementation MJKLoadMethodTracer

+ (instancetype)sharedTracer {
    static MJKLoadMethodTracer *tracer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tracer = [[self alloc] init];
    });
    return tracer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _nonLazyClasses = [NSMutableSet set];
        _classCategoriesMap = [NSMutableDictionary dictionary];
    }
    
    return self;
}

// 从 image 的数据段读取 non-lazy 的（也就是包含 +load 方法的）class 和 category
- (void)readNonLazyClassAndCategory {
    // 考虑到有多 image 的情况，不能只处理当前 image
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        const struct mach_header* image_header = _dyld_get_image_header(i);
        Dl_info info;
        if (dladdr(image_header, &info) == 0) {
            continue;
        }
        
        [self readNonLazyClassAndCategoryWithMachHeader:(mjk_ptr)info.dli_fbase];
    }
}

- (void)readNonLazyClassAndCategoryWithMachHeader:(const mjk_ptr)mach_header {
    // 读取 non-lazy class list
    const mjk_section *nonLazyClassListSection = GetSectByNameFromHeader((void *)mach_header, "__DATA", "__objc_nlclslist");
    if (nonLazyClassListSection != NULL) {
        for (mjk_ptr addr = nonLazyClassListSection->offset; addr < nonLazyClassListSection->offset + nonLazyClassListSection->size; addr += sizeof(const void *))
        {
            Class cls = (__bridge Class)(*(void **)(mach_header + addr));
            
            // 忽略 __ARCLite__ 这个奇葩
            if (strcmp(class_getName(cls), "__ARCLite__") == 0) {
                continue;
            }
            
            [self.nonLazyClasses addObject:cls];
        }
    }
    
    // 读取 non-lazy category list，建立 category 与 class 的映射
    const mjk_section *nonLazyCategoryListSection = GetSectByNameFromHeader((void *)mach_header, "__DATA", "__objc_nlcatlist");
    if (nonLazyCategoryListSection != NULL) {
        for (mjk_ptr addr = nonLazyCategoryListSection->offset; addr < nonLazyCategoryListSection->offset + nonLazyCategoryListSection->size; addr += sizeof(const void **))
        {
            struct category_t *catRef = (*(struct category_t **)(mach_header + addr));
            Class cls = catRef->cls;
            
            [self.nonLazyClasses addObject:cls];
            
            NSMutableArray *categories = self.classCategoriesMap[cls];
            if (!categories) {
                categories = [NSMutableArray array];
                self.classCategoriesMap[(id <NSCopying>)cls] = categories;
            }
            [categories addObject:@((uintptr_t)catRef)];
        }
    }
}

+ (void)load {
    [[self sharedTracer] startTracing];
}

- (void)startTracing {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        [self readNonLazyClassAndCategory];
        
        // 遍历所有实现 +load 方法
        for (Class cls in self.nonLazyClasses) {
            Class metaClass = object_getClass(cls);
            
            unsigned int methodCount;
            Method *methodList = class_copyMethodList(metaClass, &methodCount);
            for (int i = 0; i < methodCount; i++) {
                struct method_t *loadMethod = (struct method_t *)methodList[i];
                if (!sel_isEqual(loadMethod->name, @selector(load))) {
                    continue;
                }
                
                // 查找添加这个 load 方法的 category，拿到 category 名称
                const char *categoryName = NULL;
                NSArray *categories = self.classCategoriesMap[cls];
                for (NSNumber *categoryPtr in categories){
                    struct category_t cat = *(struct category_t *)[categoryPtr unsignedLongValue];
                    struct method_list_t *method_list = cat.classMethods;
                    BOOL found = NO;
                    for (int j = 0; j < method_list->count; j++) {
                        struct method_t *aMethod = (struct method_t *)(&(method_list->first) + j);
                        if (aMethod->imp == loadMethod->imp) {
                            categoryName = cat.name;
                            found = YES;
                            break;
                        }
                    }
                    if (found) {
                        break;
                    }
                }
                
                // 替换 imp
                IMP origLoadIMP = loadMethod->imp;
                NSString *receiver = categoryName ? ([NSString stringWithFormat:@"%@(%@)", NSStringFromClass(cls), [NSString stringWithUTF8String:categoryName]]) : NSStringFromClass(cls);
                NSString *eventName = [NSString stringWithFormat:@"+[%@ load]", receiver];
                IMP newLoadIMP = imp_implementationWithBlock(^(__unsafe_unretained id self, SEL cmd) {
                    double startTime = CACurrentMediaTime(); // csm_currentTimestamp();
                    ((void (*)(id, SEL))origLoadIMP)(self, cmd);
                    double endTime = CACurrentMediaTime(); //csm_currentTimestamp();
                    NSLog(@"xxxxxxxxx:%@ : %f", eventName, (endTime - startTime) * 1000);
                });
                loadMethod->imp = newLoadIMP;
            }
            free(methodList);
        }
    });
}

@end
