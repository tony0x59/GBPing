GBPing
============

Highly accurate ICMP Ping controller for iOS (not based on Apple Sample Code, see "Details" section)

Details
------------

This code is a low level ping library that gives extremely accurate round-trip timing results without being impacted by UI and other processing on the main thread. This is not the case with most other ping libraries such as the typical Apple SimplePing which are built as a single threaded class interleaved within the main thread of execution, causing them to suffer from all kinds of indeterministic errors. This library is a multi-threaded class built on top of BSD sockets and GCD, delivering the best possible timing accuracy regardless of system resource state or device performance.

Usage
------------

First import header

```objective-c
#import "GBPing.h"
```

Basic usage:

```objective-c
self.ping = [[GBPing alloc] init];
self.ping.host = @"192.168.0.116";
self.ping.delegate = self;
self.ping.timeout = 1;
self.ping.pingPeriod = 0.9;

[self.ping setupWithBlock:^(BOOL success, NSError *error) { //necessary to resolve hostname
    if (success) {
        //start pinging
        [self.ping startPinging];
        
        //stop it after 5 seconds
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO withBlock:^{
            l(@"stop it");
            [_ping stop];
            _ping = nil;
        }];
    }
    else {
        l(@"failed to start");
    }
}];
```

Implement optional delegate methods:

```objective-c
-(void)ping:(GBPing *)pinger didReceiveReplyWithSummary:(GBPingSummary *)summary {
    l(@"REPLY>  %@", summary);
}

-(void)ping:(GBPing *)pinger didReceiveUnexpectedReplyWithSummary:(GBPingSummary *)summary {
    l(@"BREPLY> %@", summary);
}

-(void)ping:(GBPing *)pinger didSendPingWithSummary:(GBPingSummary *)summary {
    l(@"SENT>   %@", summary);
}

-(void)ping:(GBPing *)pinger didTimeoutWithSummary:(GBPingSummary *)summary {
    l(@"TIMOUT> %@", summary);
}

-(void)ping:(GBPing *)pinger didFailWithError:(NSError *)error {
    l(@"FAIL>   %@", error);
}

-(void)ping:(GBPing *)pinger didFailToSendPingWithSummary:(GBPingSummary *)summary error:(NSError *)error {
    l(@"FSENT>  %@, %@", summary, error);
}
```

Demo project
------------

See: [github.com/lmirosevic/GBPingDemo](https://github.com/lmirosevic/GBPingDemo)

Features
------------

GBPing provides the following info (inside a GBPingSummaryObject exposed as properties):

* NSUInteger        sequenceNumber;
* NSUInteger        payloadSize;
* NSUInteger        ttl;
* NSString          *host;
* NSDate            *sendDate;
* NSDate            *receiveDate;
* NSTimeInterval    rtt;
* GBPingStatus      status;

Dependencies
------------

Static libraries (Add dependency, link, -ObjC linker flag, header search path in superproject):

* [GBToolbox](https://github.com/lmirosevic/GBToolbox)

System Frameworks (link them in):

* CFNetwork
* CoreGraphics

Copyright & License
------------

Copyright 2013 Luka Mirosevic

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this work except in compliance with the License. You may obtain a copy of the License in the LICENSE file, or at:

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

[![Bitdeli Badge](https://d2weczhvl823v0.cloudfront.net/lmirosevic/gbping/trend.png)](https://bitdeli.com/free "Bitdeli Badge")
