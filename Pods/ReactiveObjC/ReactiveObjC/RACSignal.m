//
//  RACSignal.m
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/15/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACSignal.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACDynamicSignal.h"
#import "RACEmptySignal.h"
#import "RACErrorSignal.h"
#import "RACMulticastConnection.h"
#import "RACReplaySubject.h"
#import "RACReturnSignal.h"
#import "RACScheduler.h"
#import "RACSerialDisposable.h"
#import "RACSignal+Operations.h"
#import "RACSubject.h"
#import "RACSubscriber+Private.h"
#import "RACTuple.h"
#import <libkern/OSAtomic.h>

@implementation RACSignal

#pragma mark Lifecycle

+ (RACSignal *)createSignal:(RACDisposable * (^)(id<RACSubscriber> subscriber))didSubscribe {
	return [RACDynamicSignal createSignal:didSubscribe];//RACDynamicSignal是RACSignal的子类。
}

+ (RACSignal *)error:(NSError *)error {
	return [RACErrorSignal error:error];
}

+ (RACSignal *)never {
	return [[self createSignal:^ RACDisposable * (id<RACSubscriber> subscriber) {
		return nil;
	}] setNameWithFormat:@"+never"];
}

+ (RACSignal *)startEagerlyWithScheduler:(RACScheduler *)scheduler block:(void (^)(id<RACSubscriber> subscriber))block {
	NSCParameterAssert(scheduler != nil);
	NSCParameterAssert(block != NULL);

	RACSignal *signal = [self startLazilyWithScheduler:scheduler block:block];
	// Subscribe to force the lazy signal to call its block.
	[[signal publish] connect];
	return [signal setNameWithFormat:@"+startEagerlyWithScheduler: %@ block:", scheduler];
}

+ (RACSignal *)startLazilyWithScheduler:(RACScheduler *)scheduler block:(void (^)(id<RACSubscriber> subscriber))block {
	NSCParameterAssert(scheduler != nil);
	NSCParameterAssert(block != NULL);

	RACMulticastConnection *connection = [[RACSignal
		createSignal:^ id (id<RACSubscriber> subscriber) {
			block(subscriber);
			return nil;
		}]
		multicast:[RACReplaySubject subject]];
	
	return [[[RACSignal
		createSignal:^ id (id<RACSubscriber> subscriber) {
			[connection.signal subscribe:subscriber];
			[connection connect];
			return nil;
		}]
		subscribeOn:scheduler]
		setNameWithFormat:@"+startLazilyWithScheduler: %@ block:", scheduler];
}

#pragma mark NSObject

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p> name: %@", self.class, self, self.name];
}

@end

@implementation RACSignal (RACStream)

+ (RACSignal *)empty {
	return [RACEmptySignal empty];
}

+ (RACSignal *)return:(id)value {
	return [RACReturnSignal return:value];
}

/*
 先来说说bind函数的作用：
 1. 会订阅原始的信号。
 2. 任何时刻原始信号发送一个值，都会绑定的block转换一次。
 3. 一旦绑定的block转换了值变成信号，就立即订阅，并把值发给订阅者subscriber。
 4. 一旦绑定的block要终止绑定，原始的信号就complete。
 5. 当所有的信号都complete，发送completed信号给订阅者subscriber。
 6. 如果中途信号出现了任何error，都要把这个错误发送给subscriber
 */
- (RACSignal *)bind:(RACSignalBindBlock (^)(void))block {
	NSCParameterAssert(block != NULL);//断言传入的block不能为空

	/*
	 * -bind: should:
	 * 
	 * 1. Subscribe to the original signal of values. 订阅源信号值
	 * 2. Any time the original signal sends a value, transform it using the binding block. 任何时候源信号发送一个值，使用绑定的block进行运送
	 * 3. If the binding block returns a signal, subscribe to it, and pass all of its values through to the subscriber as they're received.如果绑定的block返回了一个信号，订阅它，并传送它的所有值给订阅者，当收到数据的时候
	 * 4. If the binding block asks the bind to terminate, complete the _original_ signal.如果绑定的block需要终止绑定，同时将源信号置为完成
	 * 5. When _all_ signals complete, send completed to the subscriber.当所有信号完成，将完成信息发送给订阅者
	 * 
	 * If any signal sends an error at any point, send that to the subscriber.任何时间点信号发出了错误，同样需要传输给订阅者
	 */

    //返回一个信号  这个信号是用来管理信号的信号的
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACSignalBindBlock bindingBlock = block();//获取block返回的拦截block,这个信号拦截处理返回的值

		__block volatile int32_t signalCount = 1;   // indicates self  信号计数

        //用来管理信号的信号数组销毁
		RACCompoundDisposable *compoundDisposable = [RACCompoundDisposable compoundDisposable];

        //完成信号回调
		void (^completeSignal)(RACDisposable *) = ^(RACDisposable *finishedDisposable) {
			if (OSAtomicDecrement32Barrier(&signalCount) == 0) {//如果信号计数为0，则释放资源
				[subscriber sendCompleted];
				[compoundDisposable dispose];
			} else {
				[compoundDisposable removeDisposable:finishedDisposable];
			}
		};

        //增加信号回调
		void (^addSignal)(RACSignal *) = ^(RACSignal *signal) {
			OSAtomicIncrement32Barrier(&signalCount);

			RACSerialDisposable *selfDisposable = [[RACSerialDisposable alloc] init];
			[compoundDisposable addDisposable:selfDisposable];

			RACDisposable *disposable = [signal subscribeNext:^(id x) {
				[subscriber sendNext:x];
			} error:^(NSError *error) {
				[compoundDisposable dispose];
				[subscriber sendError:error];
			} completed:^{
				@autoreleasepool {
					completeSignal(selfDisposable);
				}
			}];

			selfDisposable.disposable = disposable;
		};

		@autoreleasepool {
			RACSerialDisposable *selfDisposable = [[RACSerialDisposable alloc] init];
			[compoundDisposable addDisposable:selfDisposable];

            //订阅自己
			RACDisposable *bindingDisposable = [self subscribeNext:^(id x) {
				// Manually check disposal to handle synchronous errors.
				if (compoundDisposable.disposed) return;

				BOOL stop = NO;
				id signal = bindingBlock(x, &stop);//传入拦截block内部

				@autoreleasepool {
					if (signal != nil) addSignal(signal);
					if (signal == nil || stop) {//如果终止或者返回的信号为空，则清空该signa资源
						[selfDisposable dispose];
						completeSignal(selfDisposable);
					}
				}
			} error:^(NSError *error) {
				[compoundDisposable dispose];
				[subscriber sendError:error];
			} completed:^{
				@autoreleasepool {
					completeSignal(selfDisposable);
				}
			}];

			selfDisposable.disposable = bindingDisposable;
		}

		return compoundDisposable;
	}] setNameWithFormat:@"[%@] -bind:", self.name];
}

/*
 这里有二点需要注意的是：
 
 只有当第一个信号完成之后才能收到第二个信号的值，因为第二个信号是在第一个信号completed的闭包里面订阅的，所以第一个信号不结束，第二个信号也不会被订阅。
 两个信号concat在一起之后，新的信号的结束信号在第二个信号结束的时候才结束。看上图描述，新的信号的发送长度等于前面两个信号长度之和，concat之后的新信号的结束信号也就是第二个信号的结束信号。
 concat是有序的组合，第一个信号完成之后才发送第二个信号。
 */
- (RACSignal *)concat:(RACSignal *)signal {
	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		RACCompoundDisposable *compoundDisposable = [[RACCompoundDisposable alloc] init];

		RACDisposable *sourceDisposable = [self subscribeNext:^(id x) {
            //发送第一个信号的值
			[subscriber sendNext:x];
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
            //订阅第二个信号
			RACDisposable *concattedDisposable = [signal subscribe:subscriber];
			[compoundDisposable addDisposable:concattedDisposable];
		}];

		[compoundDisposable addDisposable:sourceDisposable];
		return compoundDisposable;
	}] setNameWithFormat:@"[%@] -concat: %@", self.name, signal];
}

/*
 当把两个信号通过zipWith之后，就像上面的那张图一样，拉链的两边被中间的拉索拉到了一起。既然是拉链，那么一一的位置是有对应的，上面的拉链第一个位置只能对着下面拉链第一个位置，这样拉链才能拉到一起去。
 */
- (RACSignal *)zipWith:(RACSignal *)signal {
	NSCParameterAssert(signal != nil);

	return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
		__block BOOL selfCompleted = NO;
		NSMutableArray *selfValues = [NSMutableArray array];

		__block BOOL otherCompleted = NO;
		NSMutableArray *otherValues = [NSMutableArray array];

		void (^sendCompletedIfNecessary)(void) = ^{
			@synchronized (selfValues) {
				BOOL selfEmpty = (selfCompleted && selfValues.count == 0);
				BOOL otherEmpty = (otherCompleted && otherValues.count == 0);
                //如果任意一个信号完成并且数组里面空了，就整个信号算完成
				if (selfEmpty || otherEmpty) [subscriber sendCompleted];
			}
		};

		void (^sendNext)(void) = ^{
			@synchronized (selfValues) {
                //数组里面的空了就返回
				if (selfValues.count == 0) return;
				if (otherValues.count == 0) return;

                //每次都取出两个数组里面的第0位的值，打包成元组
				RACTuple *tuple = RACTuplePack(selfValues[0], otherValues[0]);
				[selfValues removeObjectAtIndex:0];
				[otherValues removeObjectAtIndex:0];

                //把元组发送出去
				[subscriber sendNext:tuple];
				sendCompletedIfNecessary();
			}
		};

        //订阅第一个信号
		RACDisposable *selfDisposable = [self subscribeNext:^(id x) {
			@synchronized (selfValues) {
                //把第一个信号的值加入到数组中
				[selfValues addObject:x ?: RACTupleNil.tupleNil];
				sendNext();
			}
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			@synchronized (selfValues) {
                //订阅完成时判断是否要发送完成信号
				selfCompleted = YES;
				sendCompletedIfNecessary();
			}
		}];

        //订阅第二个信号
		RACDisposable *otherDisposable = [signal subscribeNext:^(id x) {
			@synchronized (selfValues) {
                //把第二个信号加入到数组中
				[otherValues addObject:x ?: RACTupleNil.tupleNil];
				sendNext();
			}
		} error:^(NSError *error) {
			[subscriber sendError:error];
		} completed:^{
			@synchronized (selfValues) {
                //订阅完成时判断是否要发送完成信号
				otherCompleted = YES;
				sendCompletedIfNecessary();
			}
		}];

		return [RACDisposable disposableWithBlock:^{
            //销毁两个信号
			[selfDisposable dispose];
			[otherDisposable dispose];
		}];
	}] setNameWithFormat:@"[%@] -zipWith: %@", self.name, signal];
}

@end

@implementation RACSignal (Subscription)

- (RACDisposable *)subscribe:(id<RACSubscriber>)subscriber {
	NSCAssert(NO, @"This method must be overridden by subclasses");
	return nil;
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock {
	NSCParameterAssert(nextBlock != NULL);
	//创建订阅者,并在订阅者内部保存nextBlock
	RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:NULL completed:NULL];
	return [self subscribe:o];//这里实际是调用了RACDynamicSignal类里面的subscribe方法。
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock completed:(void (^)(void))completedBlock {
	NSCParameterAssert(nextBlock != NULL);
	NSCParameterAssert(completedBlock != NULL);
	
	RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:NULL completed:completedBlock];
	return [self subscribe:o];
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock error:(void (^)(NSError *error))errorBlock completed:(void (^)(void))completedBlock {
	NSCParameterAssert(nextBlock != NULL);
	NSCParameterAssert(errorBlock != NULL);
	NSCParameterAssert(completedBlock != NULL);
	
	RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:errorBlock completed:completedBlock];
	return [self subscribe:o];
}

- (RACDisposable *)subscribeError:(void (^)(NSError *error))errorBlock {
	NSCParameterAssert(errorBlock != NULL);
	
	RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:errorBlock completed:NULL];
	return [self subscribe:o];
}

- (RACDisposable *)subscribeCompleted:(void (^)(void))completedBlock {
	NSCParameterAssert(completedBlock != NULL);
	
	RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:NULL completed:completedBlock];
	return [self subscribe:o];
}

- (RACDisposable *)subscribeNext:(void (^)(id x))nextBlock error:(void (^)(NSError *error))errorBlock {
	NSCParameterAssert(nextBlock != NULL);
	NSCParameterAssert(errorBlock != NULL);
	
	RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:errorBlock completed:NULL];
	return [self subscribe:o];
}

- (RACDisposable *)subscribeError:(void (^)(NSError *))errorBlock completed:(void (^)(void))completedBlock {
	NSCParameterAssert(completedBlock != NULL);
	NSCParameterAssert(errorBlock != NULL);
	
	RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:errorBlock completed:completedBlock];
	return [self subscribe:o];
}

@end

@implementation RACSignal (Debugging)

- (RACSignal *)logAll {
	return [[[self logNext] logError] logCompleted];
}

- (RACSignal *)logNext {
	return [[self doNext:^(id x) {
		NSLog(@"%@ next: %@", self, x);
	}] setNameWithFormat:@"%@", self.name];
}

- (RACSignal *)logError {
	return [[self doError:^(NSError *error) {
		NSLog(@"%@ error: %@", self, error);
	}] setNameWithFormat:@"%@", self.name];
}

- (RACSignal *)logCompleted {
	return [[self doCompleted:^{
		NSLog(@"%@ completed", self);
	}] setNameWithFormat:@"%@", self.name];
}

@end

@implementation RACSignal (Testing)

static const NSTimeInterval RACSignalAsynchronousWaitTimeout = 10;

- (id)asynchronousFirstOrDefault:(id)defaultValue success:(BOOL *)success error:(NSError **)error {
	return [self asynchronousFirstOrDefault:defaultValue success:success error:error timeout:RACSignalAsynchronousWaitTimeout];
}

- (id)asynchronousFirstOrDefault:(id)defaultValue success:(BOOL *)success error:(NSError **)error timeout:(NSTimeInterval)timeout {
	NSCAssert([NSThread isMainThread], @"%s should only be used from the main thread", __func__);

	__block id result = defaultValue;
	__block BOOL done = NO;

	// Ensures that we don't pass values across thread boundaries by reference.
	__block NSError *localError;
	__block BOOL localSuccess = YES;

	[[[[self
		take:1]
		timeout:timeout onScheduler:[RACScheduler scheduler]]
		deliverOn:RACScheduler.mainThreadScheduler]
		subscribeNext:^(id x) {
			result = x;
			done = YES;
		} error:^(NSError *e) {
			if (!done) {
				localSuccess = NO;
				localError = e;
				done = YES;
			}
		} completed:^{
			done = YES;
		}];
	
	do {
		[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	} while (!done);

	if (success != NULL) *success = localSuccess;
	if (error != NULL) *error = localError;

	return result;
}

- (BOOL)asynchronouslyWaitUntilCompleted:(NSError **)error timeout:(NSTimeInterval)timeout {
	BOOL success = NO;
	[[self ignoreValues] asynchronousFirstOrDefault:nil success:&success error:error timeout:timeout];
	return success;
}

- (BOOL)asynchronouslyWaitUntilCompleted:(NSError **)error {
	return [self asynchronouslyWaitUntilCompleted:error timeout:RACSignalAsynchronousWaitTimeout];
}

@end
