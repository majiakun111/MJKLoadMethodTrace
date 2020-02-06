//
//  Person+Test1.m
//  MJKLoadMethodTrace
//
//  Created by Ansel on 2020/1/7.
//  Copyright © 2020 Ansel. All rights reserved.
//

#import "Person+Test1.h"

@implementation Person (Test1)

+ (void)load {
    NSLog(@"xxxxxxTest1");
}

@end
