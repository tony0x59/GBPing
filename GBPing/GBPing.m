//
//  GBPing.m
//  GBPing
//
//  Created by Luka Mirosevic on 05/11/2012.
//  Copyright (c) 2012 Goonbee. All rights reserved.
//

#define kDefaultPayloadSize 56
#define kDefaultTTL 49
#define kDefaultPingPeriod 1.0
#define kDefaultTimeout 2.0

#import "GBPing.h"


#if TARGET_OS_EMBEDDED || TARGET_IPHONE_SIMULATOR
    #import <CFNetwork/CFNetwork.h>
#else
    #import <CoreServices/CoreServices.h>
#endif

#import "ICMPHeader.h"

#include <sys/socket.h>
#include <netinet/in.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/types.h>
#include <arpa/inet.h>
#include <netdb.h>

#define l(frmt, ...)    NSLog(frmt, ##__VA_ARGS__)



@interface NSTimer (GBToolbox)

//blocks
+(NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats withBlock:(void(^)(void))block;
+(NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats withBlock:(void(^)(void))block;

@end

@implementation NSTimer (GBToolbox)

//blocks
+(NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats withBlock:(void(^)(void))block {
    return [self _timerFactory:interval repeats:repeats withBlock:block shouldSchedule:YES];
}

+(NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats withBlock:(void(^)(void))block {
    return [self _timerFactory:interval repeats:repeats withBlock:block shouldSchedule:NO];
}

+(NSTimer *)_timerFactory:(NSTimeInterval)interval repeats:(BOOL)repeats withBlock:(void(^)(void))block shouldSchedule:(BOOL)shouldSchedule {
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self instanceMethodSignatureForSelector:@selector(callBlock:)]];
    NSTimer *timer = shouldSchedule ?
    [NSTimer scheduledTimerWithTimeInterval:interval invocation:invocation repeats:repeats] :
    [NSTimer timerWithTimeInterval:interval invocation:invocation repeats:repeats];
    
    [invocation setTarget:timer];
    [invocation setSelector:@selector(callBlock:)];
    
    void(^copy)(void) = [block copy];
    [invocation setArgument:&copy atIndex:2];
    
    return timer;
}

-(void)callBlock:(void(^)(void))block {
    block();
}

@end




@interface GBPing ()

@property (assign, atomic) int                          socket;
@property (assign, nonatomic) CFHostRef                 hostRef;
@property (strong, nonatomic) NSData                    *hostAddress;
@property (assign, nonatomic) uint16_t                  identifier;

@property (assign, atomic, readwrite) BOOL              isPinging;
@property (assign, atomic, readwrite) BOOL              isReady;
@property (assign, nonatomic) NSUInteger                nextSequenceNumber;
@property (strong, nonatomic) NSMutableDictionary       *pendingPings;
@property (strong, nonatomic) NSMutableDictionary       *timeoutTimers;

@property (strong, nonatomic) dispatch_queue_t          setupQueue;

@property (assign, atomic) BOOL                         isStopped;

@end

@implementation GBPing

@synthesize payloadSize = _payloadSize;
@synthesize ttl = _ttl;
@synthesize timeout = _timeout;
@synthesize pingPeriod = _pingPeriod;

#pragma mark - custom acc

-(void)setTimeout:(NSTimeInterval)timeout {
    if (self.isPinging) {
        if (self.debug) {
            l(@"GBPing: can't set timeout while pinger is running.");
        }
    }
    else {
        _timeout = timeout;
    }
}

-(NSTimeInterval)timeout {
    if (!_timeout) {
        return kDefaultTimeout;
    }
    else {
        return _timeout;
    }
}

-(void)setTtl:(NSUInteger)ttl {
    if (self.isPinging) {
        if (self.debug) {
            l(@"GBPing: can't set ttl while pinger is running.");
        }
    }
    else {
        _ttl = ttl;
    }
}

-(NSUInteger)ttl {
    if (!_ttl) {
        return kDefaultTTL;
    }
    else {
        return _ttl;
    }
}

-(void)setPayloadSize:(NSUInteger)payloadSize {
    if (self.isPinging) {
        if (self.debug) {
            l(@"GBPing: can't set payload size while pinger is running.");
        }
    }
    else {
        _payloadSize = payloadSize;
    }
}

-(NSUInteger)payloadSize {
    if (!_payloadSize) {
        return kDefaultPayloadSize;
    }
    else {
        return _payloadSize;
    }
}

-(void)setPingPeriod:(NSTimeInterval)pingPeriod {
    if (self.isPinging) {
        if (self.debug) {
            l(@"GBPing: can't set pingPeriod while pinger is running.");
        }
    }
    else {
        _pingPeriod = pingPeriod;
    }
}

-(NSTimeInterval)pingPeriod {
    if (!_pingPeriod) {
        return (NSTimeInterval)kDefaultPingPeriod;
    }
    else {
        return _pingPeriod;
    }
}

#pragma mark - core pinging methods

-(void)setupWithBlock:(StartupCallback)callback {
    //error out of its already setup
    if (self.isReady) {
        if (self.debug) {
            l(@"GBPing: Can't setup, already setup.");
        }
        
        //notify about error and return
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(NO, nil);
        });
        return;
    }
    
    //error out if no host is set
    if (!self.host) {
        if (self.debug) {
            l(@"GBPing: set host before attempting to start.");
        }
        
        //notify about error and return
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(NO, nil);
        });
        return;
    }
    
    //set up data structs
    self.nextSequenceNumber = 0;
    self.pendingPings = [[NSMutableDictionary alloc] init];
    self.timeoutTimers = [[NSMutableDictionary alloc] init];
    
    dispatch_async(self.setupQueue, ^{
        CFStreamError streamError;
        
        self.hostRef = CFHostCreateWithName(NULL, (__bridge CFStringRef)self.host);
        
        BOOL success = CFHostStartInfoResolution(self.hostRef, kCFHostAddresses, &streamError);

        if (!success) {
            //construct an error
            NSDictionary *userInfo;
            NSError *error;
            
            if (streamError.domain == kCFStreamErrorDomainNetDB) {
                userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                            [NSNumber numberWithInteger:streamError.error], kCFGetAddrInfoFailureKey,
                            nil
                            ];
            }
            else {
                userInfo = nil;
            }
            error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorUnknown userInfo:userInfo];
            
            //clean up so far
            [self stop];
            
            //notify about error and return
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(NO, error);
            });
            return;
        }
        
        //get the first IPv4 address
        Boolean resolved;
        const struct sockaddr *addrPtr;
        NSArray *addresses = (__bridge NSArray *)CFHostGetAddressing(self.hostRef, &resolved);
        if (resolved && (addresses != nil)) {
            resolved = false;
            for (NSData *address in addresses) {
                const struct sockaddr *anAddrPtr = (const struct sockaddr *)[address bytes];
                
                if ([address length] >= sizeof(struct sockaddr) && anAddrPtr->sa_family == AF_INET) {
                    resolved = true;
                    addrPtr = anAddrPtr;
                    self.hostAddress = address;
                    break;
                }
            }
        }

        //we can stop host resolution now
        if (self.hostRef) {
            CFRelease(self.hostRef);
            self.hostRef = nil;
        }
        
        //if an error occurred during resolution
        if (!resolved) {
            //stop
            [self stop];
            
            //notify about error and return                
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(NO, [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil]);
            });
            return;
        }
        
        //set up socket
        int err = 0;
        switch (addrPtr->sa_family) {
            case AF_INET: {
                self.socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
                if (self.socket < 0) {
                    err = errno;
                }
            } break;
            case AF_INET6: {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(NO, nil);
                });
                return;
            } break;
            default: {
                err = EPROTONOSUPPORT;
            } break;
        }
        
        //couldnt setup socket
        if (err) {
            //clean up so far
            [self stop];
            
            //notify about error and close
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(NO, [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil]);
            });
            return;
        }
        
        //set ttl on the socket
        if (self.ttl) {
            setsockopt(self.socket, IPPROTO_IP, IP_TTL, &_ttl, sizeof(NSUInteger));
        }
        
        //we are ready now
        self.isReady = YES;
        
        //notify that we are ready
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(YES, nil);
        });
    });
    
    self.isStopped = NO;
}


-(void)startPinging {
    if (!self.isPinging) {
        //go into infinite listenloop on a new thread (listenThread)
        NSThread *listenThread = [[NSThread alloc] initWithTarget:self selector:@selector(listenLoop) object:nil];
        listenThread.name = @"listenThread";

        //set up loop that sends packets on a new thread (sendThread)
        NSThread *sendThread = [[NSThread alloc] initWithTarget:self selector:@selector(sendLoop) object:nil];
        sendThread.name = @"sendThread";
        
        //we're pinging now
        self.isPinging = YES;
        [listenThread start];
        [sendThread start];
    }
}

-(void)listenLoop {
    @autoreleasepool {
        while (self.isPinging) {
            [self listenOnce];
        }
    }
}

-(void)listenOnce {
    int                     err;
    struct sockaddr_storage addr;
    socklen_t               addrLen;
    ssize_t                 bytesRead;
    void *                  buffer;
    enum { kBufferSize = 65535 };
    
    buffer = malloc(kBufferSize);
    assert(buffer);
    
    //read the data.
    addrLen = sizeof(addr);
    bytesRead = recvfrom(self.socket, buffer, kBufferSize, 0, (struct sockaddr *)&addr, &addrLen);
    err = 0;
    if (bytesRead < 0) {
        err = errno;
    }
    
    //process the data we read.
    if (bytesRead > 0) {
        NSDate *receiveDate = [NSDate date];
        NSMutableData *packet;
        
        packet = [NSMutableData dataWithBytes:buffer length:(NSUInteger) bytesRead];
        assert(packet);
        
        //complete the ping summary
        const struct ICMPHeader *headerPointer = [[self class] icmpInPacket:packet];
        NSUInteger seqNo = (NSUInteger)OSSwapBigToHostInt16(headerPointer->sequenceNumber);
        NSNumber *key = @(seqNo);
        GBPingSummary *pingSummary = (GBPingSummary *)self.pendingPings[key];
        
        if (pingSummary) {
            if ([self isValidPingResponsePacket:packet]) {
                //override the source address (we might have sent to google.com and 172.123.213.192 replied
                pingSummary.receiveDate = receiveDate;
                pingSummary.host = [[self class] sourceAddressInPacket:packet];
                
                pingSummary.status = GBPingStatusSuccess;
                
                //remove it from pending pings
                [self.pendingPings removeObjectForKey:key];
                
                //invalidate the timeouttimer
                NSTimer *timer = self.timeoutTimers[key];
                [timer invalidate];
                [self.timeoutTimers removeObjectForKey:key];
                
                
                if (self.delegate && [self.delegate respondsToSelector:@selector(ping:didReceiveReplyWithSummary:)] ) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        //notify delegate
                        [self.delegate ping:self didReceiveReplyWithSummary:[pingSummary copy]];
                    });
                }
            }
            else {
                pingSummary.status = GBPingStatusFail;
                
                if (self.delegate && [self.delegate respondsToSelector:@selector(ping:didReceiveUnexpectedReplyWithSummary:)] ) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate ping:self didReceiveReplyWithSummary:[pingSummary copy]];
                    });
                }
            }
        }
        
    }
    else {
        
        //we failed to read the data, so shut everything down.
        if (err == 0) {
            err = EPIPE;
        }
        
        @synchronized(self) {
            if (!self.isStopped) {
                if (self.delegate && [self.delegate respondsToSelector:@selector(ping:didFailWithError:)] ) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate ping:self didFailWithError:[NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil]];
                    });
                }
            }
        }
        
        //stop the whole thing
        [self stop];
    }
    
    free(buffer);
}

-(void)sendLoop {
    @autoreleasepool {
        while (self.isPinging) {
            [self sendPing];
            [NSThread sleepForTimeInterval:self.pingPeriod];
        }
    }
}

-(void)sendPing {
    if (self.isPinging) {
        
        int err;
        NSMutableData *packet;
        ICMPHeader *icmpPtr;
        ssize_t bytesSent;
        
        // Construct the ping packet.
        NSData *payload = [self generateDataWithLength:(self.payloadSize)];
        
        packet = [NSMutableData dataWithLength:sizeof(*icmpPtr) + [payload length]];
        
        icmpPtr = [packet mutableBytes];
        icmpPtr->type = kICMPTypeEchoRequest;
        icmpPtr->code = 0;
        icmpPtr->checksum = 0;
        icmpPtr->identifier     = OSSwapHostToBigInt16(self.identifier);
        icmpPtr->sequenceNumber = OSSwapHostToBigInt16(self.nextSequenceNumber);
        memcpy(&icmpPtr[1], [payload bytes], [payload length]);
        
        // The IP checksum returns a 16-bit number that's already in correct byte order
        // (due to wacky 1's complement maths), so we just put it into the packet as a
        // 16-bit unit.
        icmpPtr->checksum = in_cksum([packet bytes], [packet length]);
        
        // Send the packet.
        if (self.socket == 0) {
            bytesSent = -1;
            err = EBADF;
        }
        else {
            bytesSent = sendto(
                               self.socket,
                               [packet bytes],
                               [packet length],
                               0,
                               (struct sockaddr *) [self.hostAddress bytes],
                               (socklen_t) [self.hostAddress length]
                               );
            err = 0;
            if (bytesSent < 0) {
                err = errno;
            }
        }
        
        // Handle the results of the send.
        NSDate *sendDate = [NSDate date];
        
        //construct ping summary, as much as it can
        GBPingSummary *newPingSummary = [[GBPingSummary alloc] init];
        newPingSummary.sequenceNumber = self.nextSequenceNumber;
        newPingSummary.host = self.host;
        newPingSummary.sendDate = sendDate;
        newPingSummary.ttl = self.ttl;
        newPingSummary.payloadSize = self.payloadSize;
        
        //successfully sent
        if ((bytesSent > 0) && (((NSUInteger) bytesSent) == [packet length])) {
            
            //update the statsus to pending
            newPingSummary.status = GBPingStatusPending;
            
            //add it to pending pings
            NSNumber *key = @(self.nextSequenceNumber);
            self.pendingPings[key] = newPingSummary;
            
            //add a timeout timer
            NSTimer *timeoutTimer = [NSTimer timerWithTimeInterval:self.timeout repeats:NO withBlock:^{

                newPingSummary.status = GBPingStatusFail;
                
                //notify about the failure
                if (self.delegate && [self.delegate respondsToSelector:@selector(ping:didTimeoutWithSummary:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate ping:self didTimeoutWithSummary:[newPingSummary copy]];
                    });
                }
                
                //remove the ping from the pending list
                [self.pendingPings removeObjectForKey:key];
                
                //remove the timer itself from the timers list
                //foo make sure that the timer list doesnt grow and these removals actually work... try logging the count of the timeoutTimers when stopping the pinger
                [self.timeoutTimers removeObjectForKey:key];
            }];
            [[NSRunLoop mainRunLoop] addTimer:timeoutTimer forMode:NSRunLoopCommonModes];
            
            //keep a local ref to it
            self.timeoutTimers[key] = timeoutTimer;

            //notify delegate about this
            if (self.delegate && [self.delegate respondsToSelector:@selector(ping:didSendPingWithSummary:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate ping:self didSendPingWithSummary:[newPingSummary copy]];
                });
            }
        }
        //failed to send
        else {
            //complete the error
            if (err == 0) {
                err = ENOBUFS;          // This is not a hugely descriptor error, alas.
            }
            
            //little log
            if (self.debug) {
                l(@"GBPing: failed to send packet with error code: %d", err);
            }
            
            //change status
            newPingSummary.status = GBPingStatusFail;
            
            //notify delegate
            if (self.delegate && [self.delegate respondsToSelector:@selector(ping:didFailToSendPingWithSummary:error:)]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate ping:self didFailToSendPingWithSummary:[newPingSummary copy] error:[NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil]];
                });
            }
        }
        
        //increment sequence number
        self.nextSequenceNumber += 1;
    }
}

-(void)stop {
    @synchronized(self) {
        if (!self.isStopped) {
            self.isPinging = NO;

            self.isReady = NO;
        
            //destroy listenThread by closing socket (listenThread)
            if (self.socket) {
                close(self.socket);
                self.socket = 0;
            }
            
            //just to be safe make sure this one is gone
            if (self.hostRef) {
                CFRelease(self.hostRef);
                self.hostRef = nil;
            }
            
            //destroy host
            self.hostAddress = nil;
            
            //clean up pendingpings
            [self.pendingPings removeAllObjects];
            self.pendingPings = nil;
            for (NSNumber *key in self.timeoutTimers) {
                NSTimer *timer = self.timeoutTimers[key];
                [timer invalidate];
            }
            
            //clean up timeouttimers
            [self.timeoutTimers removeAllObjects];
            self.timeoutTimers = nil;
            
            //reset seq number
            self.nextSequenceNumber = 0;
            
            self.isStopped = YES;
        }
    }
}

#pragma mark - util

static uint16_t in_cksum(const void *buffer, size_t bufferLen)
// This is the standard BSD checksum code, modified to use modern types.
{
	size_t              bytesLeft;
    int32_t             sum;
	const uint16_t *    cursor;
	union {
		uint16_t        us;
		uint8_t         uc[2];
	} last;
	uint16_t            answer;
    
	bytesLeft = bufferLen;
	sum = 0;
	cursor = buffer;
    
	/*
	 * Our algorithm is simple, using a 32 bit accumulator (sum), we add
	 * sequential 16 bit words to it, and at the end, fold back all the
	 * carry bits from the top 16 bits into the lower 16 bits.
	 */
	while (bytesLeft > 1) {
		sum += *cursor;
        cursor += 1;
		bytesLeft -= 2;
	}
    
	/* mop up an odd byte, if necessary */
	if (bytesLeft == 1) {
		last.uc[0] = * (const uint8_t *) cursor;
		last.uc[1] = 0;
		sum += last.us;
	}
    
	/* add back carry outs from top 16 bits to low 16 bits */
	sum = (sum >> 16) + (sum & 0xffff);	/* add hi 16 to low 16 */
	sum += (sum >> 16);			/* add carry */
	answer = (uint16_t) ~sum;   /* truncate to 16 bits */
    
	return answer;
}

+(NSString *)sourceAddressInPacket:(NSData *)packet {
// Returns the source address of the IP packet
    
    const struct IPHeader   *ipPtr;
    const uint8_t           *sourceAddress;
    
    if ([packet length] >= sizeof(IPHeader)) {
        ipPtr = (const IPHeader *)[packet bytes];

        sourceAddress = ipPtr->sourceAddress;//dont need to swap byte order those cuz theyre the smallest atomic unit (1 byte)
        NSString *ipString = [NSString stringWithFormat:@"%d.%d.%d.%d", sourceAddress[0], sourceAddress[1], sourceAddress[2], sourceAddress[3]];
        
        return ipString;
    }
    else return nil;
}

+ (NSUInteger)icmpHeaderOffsetInPacket:(NSData *)packet
// Returns the offset of the ICMPHeader within an IP packet.
{
    NSUInteger              result;
    const struct IPHeader * ipPtr;
    size_t                  ipHeaderLength;
    
    result = NSNotFound;
    if ([packet length] >= (sizeof(IPHeader) + sizeof(ICMPHeader))) {
        ipPtr = (const IPHeader *) [packet bytes];
        assert((ipPtr->versionAndHeaderLength & 0xF0) == 0x40);     // IPv4
        assert(ipPtr->protocol == 1);                               // ICMP
        ipHeaderLength = (ipPtr->versionAndHeaderLength & 0x0F) * sizeof(uint32_t);
        if ([packet length] >= (ipHeaderLength + sizeof(ICMPHeader))) {
            result = ipHeaderLength;
        }
    }
    return result;
}

+ (const struct ICMPHeader *)icmpInPacket:(NSData *)packet
// See comment in header.
{
    const struct ICMPHeader *   result;
    NSUInteger                  icmpHeaderOffset;
    
    result = nil;
    icmpHeaderOffset = [self icmpHeaderOffsetInPacket:packet];
    if (icmpHeaderOffset != NSNotFound) {
        result = (const struct ICMPHeader *) (((const uint8_t *)[packet bytes]) + icmpHeaderOffset);
    }
    return result;
}

- (BOOL)isValidPingResponsePacket:(NSMutableData *)packet
// Returns true if the packet looks like a valid ping response packet destined
// for us.
{
    BOOL                result;
    NSUInteger          icmpHeaderOffset;
    ICMPHeader *        icmpPtr;
    uint16_t            receivedChecksum;
    uint16_t            calculatedChecksum;
    
    result = NO;
    
    icmpHeaderOffset = [[self class] icmpHeaderOffsetInPacket:packet];
    if (icmpHeaderOffset != NSNotFound) {
        icmpPtr = (struct ICMPHeader *) (((uint8_t *)[packet mutableBytes]) + icmpHeaderOffset);
        
        receivedChecksum   = icmpPtr->checksum;
        icmpPtr->checksum  = 0;
        calculatedChecksum = in_cksum(icmpPtr, [packet length] - icmpHeaderOffset);
        icmpPtr->checksum  = receivedChecksum;
        
        if (receivedChecksum == calculatedChecksum) {
            if ( (icmpPtr->type == kICMPTypeEchoReply) && (icmpPtr->code == 0) ) {
                if ( OSSwapBigToHostInt16(icmpPtr->identifier) == self.identifier ) {
                    if ( OSSwapBigToHostInt16(icmpPtr->sequenceNumber) < self.nextSequenceNumber ) {
                        result = YES;
                    }
                }
            }
        }
    }
    
//    l(@"valid: %@, type: %d", _b(result), icmpPtr->type);
    
    return result;
}

-(NSData *)generateDataWithLength:(NSUInteger)length {
    //create a buffer full of 7's of specified length
    char tempBuffer[length];
    memset(tempBuffer, 7, length);
    
    return [[NSData alloc] initWithBytes:tempBuffer length:length];
}

#pragma mark - memory

-(id)init {
    if (self = [super init]) {
        self.setupQueue = dispatch_queue_create("GBPing setup queue", 0);
        self.isStopped = YES;
    }
    
    return self;
}

-(void)dealloc {
    self.delegate = nil;
    self.host = nil;
    self.timeoutTimers = nil;
    self.pendingPings = nil;
    self.hostAddress = nil;
    
    //clean up dispatch queue
    if (self.setupQueue) {
        //foo check that this actually works
        self.setupQueue = nil;
    }
    
    //clean up socket to be sure
    if (self.socket) {
        close(self.socket);
        self.socket = 0;
    }
    
    //clean up host ref to be sure
    if (self.hostRef) {
        CFRelease(self.hostRef);
        self.hostRef = nil;
    }
}

@end
