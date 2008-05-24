//
//  TCPConnection.m
//  MYNetwork
//
//  Created by Jens Alfke on 5/18/08.
//  Copyright 2008 Jens Alfke. All rights reserved.
//

#import "TCP_Internal.h"
#import "IPAddress.h"

#import "Logging.h"
#import "Test.h"
#import "ExceptionUtils.h"


NSString* const TCPErrorDomain = @"TCP";


@interface TCPConnection ()
@property TCPConnectionStatus status;
- (BOOL) _checkIfClosed;
- (void) _closed;
@end


@implementation TCPConnection


static NSMutableArray *sAllConnections;


- (Class) readerClass   {return [TCPReader class];}
- (Class) writerClass   {return [TCPWriter class];}


- (id) _initWithAddress: (IPAddress*)address
            inputStream: (NSInputStream*)input
           outputStream: (NSOutputStream*)output
{
    self = [super init];
    if (self != nil) {
        if( !address || !input || !output ) {
            LogTo(TCP,@"Failed to create %@: addr=%@, in=%@, out=%@",
                  self.class,address,input,output);
            [self release];
            return nil;
        }
        _address = [address copy];
        _reader = [[[self readerClass] alloc] initWithConnection: self stream: input];
        _writer = [[[self writerClass] alloc] initWithConnection: self stream: output];
        LogTo(TCP,@"%@ initialized",self);
    }
    return self;
}



- (id) initToAddress: (IPAddress*)address
           localPort: (UInt16)localPort
{
    NSInputStream *input = nil;
    NSOutputStream *output = nil;
    [NSStream getStreamsToHost: [NSHost hostWithAddress: address.ipv4name]
                          port: address.port 
                   inputStream: &input 
                  outputStream: &output];
    return [self _initWithAddress: address inputStream: input outputStream: output];
    //FIX: Support localPort!
}

- (id) initToAddress: (IPAddress*)address
{
    return [self initToAddress: address localPort: 0];
}


- (id) initIncomingFromSocket: (CFSocketNativeHandle)socket
                     listener: (TCPListener*)listener
{
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socket, &readStream, &writeStream);
    self = [self _initWithAddress: [IPAddress addressOfSocket: socket] 
                      inputStream: (NSInputStream*)readStream
                     outputStream: (NSOutputStream*)writeStream];
    if( self ) {
        _isIncoming = YES;
        _server = [listener retain];
        CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
        CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    }
    return self;
}    


- (void) dealloc
{
    LogTo(TCP,@"DEALLOC %@",self);
    [_reader release];
    [_writer release];
    [_address release];
    [super dealloc];
}


- (NSString*) description
{
    return $sprintf(@"%@[%@ %@]",self.class,(_isIncoming ?@"from" :@"to"),_address);
}


@synthesize address=_address, isIncoming=_isIncoming, status=_status, delegate=_delegate,
            reader=_reader, writer=_writer, server=_server;


- (NSError*) error
{
    return _error;
}


- (NSString*) actualSecurityLevel
{
    return _reader.securityLevel;

}

- (NSArray*) peerSSLCerts
{
    return _reader.peerSSLCerts ?: _writer.peerSSLCerts;
}


- (void) _setStreamProperty: (id)value forKey: (NSString*)key
{
    [_reader setProperty: value forKey: (CFStringRef)key];
    [_writer setProperty: value forKey: (CFStringRef)key];
}


#pragma mark -
#pragma mark OPENING / CLOSING:


- (void) open
{
    if( _status<=kTCP_Closed && _reader ) {
        _reader.SSLProperties = _sslProperties;
        _writer.SSLProperties = _sslProperties;
        [_reader open];
        [_writer open];
        if( ! [sAllConnections my_containsObjectIdenticalTo: self] )
            [sAllConnections addObject: self];
        self.status = kTCP_Opening;
    }
}


- (void) disconnect
{
    if( _status > kTCP_Closed ) {
        LogTo(TCP,@"%@ disconnecting",self);
        [_writer disconnect];
        setObj(&_writer,nil);
        [_reader disconnect];
        setObj(&_reader,nil);
        self.status = kTCP_Disconnected;
    }
}


- (void) close
{
    [self closeWithTimeout: 60.0];
}

- (void) closeWithTimeout: (NSTimeInterval)timeout
{
    if( _status == kTCP_Opening ) {
        LogTo(TCP,@"%@ canceling open",self);
        [self _closed];
    } else if( _status == kTCP_Open ) {
        LogTo(TCP,@"%@ closing",self);
        self.status = kTCP_Closing;
        [self retain];
        [_reader close];
        [_writer close];
        if( ! [self _checkIfClosed] ) {
            if( timeout <= 0.0 )
                [self disconnect];
            else if( timeout != INFINITY )
                [self performSelector: @selector(_closeTimeoutExpired)
                           withObject: nil afterDelay: timeout];
        }
        [self release];
    }
}

- (void) _closeTimeoutExpired
{
    if( _status==kTCP_Closing )
        [self disconnect];
}


- (BOOL) _checkIfClosed
{
    if( _status == kTCP_Closing && _writer==nil && _reader==nil ) {
        [self _closed];
        return YES;
    } else
        return NO;
}


// called by my streams when they close (after my -close is called)
- (void) _closed
{
    if( _status != kTCP_Closed && _status != kTCP_Disconnected ) {
        LogTo(TCP,@"%@ is now closed",self);
        self.status = (_status==kTCP_Closing ?kTCP_Closed :kTCP_Disconnected);
        [self tellDelegate: @selector(connectionDidClose:) withObject: nil];
    }
    [NSObject cancelPreviousPerformRequestsWithTarget: self
                                             selector: @selector(_closeTimeoutExpired)
                                               object: nil];
    [sAllConnections removeObjectIdenticalTo: self];
}


+ (void) closeAllWithTimeout: (NSTimeInterval)timeout
{
    NSArray *connections = [sAllConnections copy];
    for( TCPConnection *conn in connections )
        [conn closeWithTimeout: timeout];
    [connections release];
}

+ (void) waitTillAllClosed
{
    while( sAllConnections.count ) {
        if( ! [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                       beforeDate: [NSDate distantFuture]] )
            break;
    }
}


#pragma mark -
#pragma mark STREAM CALLBACKS:


- (void) _streamOpened: (TCPStream*)stream
{
    if( _status==kTCP_Opening && _reader.isOpen && _writer.isOpen ) {
        LogTo(TCP,@"%@ opened",self);
        self.status = kTCP_Open;
        [self tellDelegate: @selector(connectionDidOpen:) withObject: nil];
    }
}


- (BOOL) _streamPeerCertAvailable: (TCPStream*)stream
{
    BOOL allow = YES;
    if( ! _checkedPeerCert ) {
        @try{
            _checkedPeerCert = YES;
            if( stream.securityLevel != nil ) {
                NSArray *certs = stream.peerSSLCerts;
                if( ! certs && ! _isIncoming )
                    allow = NO; // Server MUST have a cert!
                else {
                    SecCertificateRef cert = certs.count ?(SecCertificateRef)[certs objectAtIndex:0] :NULL;
                    LogTo(TCP,@"%@: Peer cert = %@",self,cert);
                    if( [_delegate respondsToSelector: @selector(connection:authorizeSSLPeer:)] )
                        allow = [_delegate connection: self authorizeSSLPeer: cert];
                }
            }
        }@catch( NSException *x ) {
            MYReportException(x,@"TCPConnection _streamPeerCertAvailable");
            _checkedPeerCert = NO;
            allow = NO;
        }
        if( ! allow )
            [self _stream: stream 
                 gotError: [NSError errorWithDomain: NSStreamSocketSSLErrorDomain
                                               code: errSSLClosedAbort
                                           userInfo: nil]];
    }
    return allow;
}


- (void) _stream: (TCPStream*)stream gotError: (NSError*)error
{
    LogTo(TCP,@"%@ got %@ on %@",self,error,stream.class);
    Assert(error);
    setObj(&_error,error);
    [_reader disconnect];
    setObj(&_reader,nil);
    [_writer disconnect];
    setObj(&_writer,nil);
    [self _closed];
}

- (void) _streamGotEOF: (TCPStream*)stream
{
    LogTo(TCP,@"%@ got EOF on %@",self,stream);
    if( stream == _reader ) {
        setObj(&_reader,nil);
        // This is the expected way for he peer to initiate closing the connection.
        if( _status==kTCP_Open ) {
            [self closeWithTimeout: INFINITY];
            return;
        }
    } else if( stream == _writer ) {
        setObj(&_writer,nil);
    }
    
    if( _status == kTCP_Closing ) {
        [self _checkIfClosed];
    } else {
        [self _stream: stream 
             gotError: [NSError errorWithDomain: NSPOSIXErrorDomain code: ECONNRESET userInfo: nil]];
    }
}


// Called after I called -close on a stream and it finished closing:
- (void) _streamClosed: (TCPStream*)stream
{
    LogTo(TCP,@"%@ finished closing %@",self,stream);
    if( stream == _reader )
        setObj(&_reader,nil);
    else if( stream == _writer )
        setObj(&_writer,nil);
    if( !_reader.isOpen && !_writer.isOpen )
        [self _closed];
}


@end


/*
 Copyright (c) 2008, Jens Alfke <jens@mooseyard.com>. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted
 provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions
 and the following disclaimer in the documentation and/or other materials provided with the
 distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND 
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRI-
 BUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR 
  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF 
 THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
