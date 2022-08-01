/**
 *    Copyright (c) 2022 Project CHIP Authors
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

#import "MatterControllerFactory.h"
#import "MatterControllerFactory_Internal.h"

#import "CHIPAttestationTrustStoreBridge.h"
#import "CHIPControllerAccessControl.h"
#import "CHIPDeviceController.h"
#import "CHIPDeviceControllerStartupParams.h"
#import "CHIPDeviceControllerStartupParams_Internal.h"
#import "CHIPDeviceController_Internal.h"
#import "CHIPLogging.h"
#import "CHIPP256KeypairBridge.h"
#import "CHIPPersistentStorageDelegateBridge.h"
#import "MTRCertificates.h"
#import "NSDataSpanConversion.h"

#include <controller/CHIPDeviceControllerFactory.h>
#include <controller/OperationalCredentialsDelegate.h>
#include <credentials/CHIPCert.h>
#include <credentials/FabricTable.h>
#include <credentials/GroupDataProviderImpl.h>
#include <credentials/attestation_verifier/DefaultDeviceAttestationVerifier.h>
#include <credentials/attestation_verifier/DeviceAttestationVerifier.h>
#include <lib/support/TestPersistentStorageDelegate.h>
#include <platform/PlatformManager.h>

using namespace chip;
using namespace chip::Controller;

static NSString * const kErrorMemoryInit = @"Init Memory failure";
static NSString * const kErrorPersistentStorageInit = @"Init failure while creating a persistent storage delegate";
static NSString * const kErrorAttestationTrustStoreInit = @"Init failure while creating the attestation trust store";
static NSString * const kInfoFactoryShutdown = @"Shutting down the Matter controller factory";
static NSString * const kErrorGroupProviderInit = @"Init failure while initializing group data provider";
static NSString * const kErrorControllersInit = @"Init controllers array failure";
static NSString * const kErrorControllerFactoryInit = @"Init failure while initializing controller factory";

@interface MatterControllerFactory ()

@property (atomic, readonly) dispatch_queue_t chipWorkQueue;
@property (readonly) DeviceControllerFactory * controllerFactory;
@property (readonly) CHIPPersistentStorageDelegateBridge * persistentStorageDelegateBridge;
@property (readonly) CHIPAttestationTrustStoreBridge * attestationTrustStoreBridge;
// We use TestPersistentStorageDelegate just to get an in-memory store to back
// our group data provider impl.  We initialize this store correctly on every
// controller startup, so don't need to actually persist it.
@property (readonly) chip::TestPersistentStorageDelegate * groupStorageDelegate;
@property (readonly) chip::Credentials::GroupDataProviderImpl * groupDataProvider;
@property (readonly) NSMutableArray<CHIPDeviceController *> * controllers;

- (BOOL)findMatchingFabric:(FabricTable &)fabricTable
                    params:(CHIPDeviceControllerStartupParams *)params
                    fabric:(FabricInfo * _Nullable * _Nonnull)fabric;
@end

// Conver a ByteSpan representing a Matter TLV certificate into NSData holding a
// DER X.509 certificate.  Returns nil on failures.
static NSData * _Nullable MatterCertToX509Data(const ByteSpan & cert)
{
    uint8_t buf[Controller::kMaxCHIPDERCertLength];
    MutableByteSpan derCert(buf);
    CHIP_ERROR err = Credentials::ConvertChipCertToX509Cert(cert, derCert);
    if (err != CHIP_NO_ERROR) {
        CHIP_LOG_ERROR("Failed do convert Matter certificate to X.509 DER: %s", ErrorStr(err));
        return nil;
    }

    return AsData(derCert);
}

@implementation MatterControllerFactory

+ (instancetype)sharedInstance
{
    static MatterControllerFactory * factory = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // initialize the factory.
        factory = [[MatterControllerFactory alloc] init];
    });
    return factory;
}

- (instancetype)init
{
    if (!(self = [super init])) {
        return nil;
    }

    _isRunning = NO;
    _chipWorkQueue = DeviceLayer::PlatformMgrImpl().GetWorkQueue();
    _controllerFactory = &DeviceControllerFactory::GetInstance();
    CHIP_ERROR errorCode = Platform::MemoryInit();
    if ([self checkForInitError:(CHIP_NO_ERROR == errorCode) logMsg:kErrorMemoryInit]) {
        return nil;
    }

    _groupStorageDelegate = new chip::TestPersistentStorageDelegate();
    if ([self checkForInitError:(_groupStorageDelegate != nullptr) logMsg:kErrorGroupProviderInit]) {
        return nil;
    }

    // For now default args are fine, since we are just using this for the IPK.
    _groupDataProvider = new chip::Credentials::GroupDataProviderImpl();
    if ([self checkForInitError:(_groupDataProvider != nullptr) logMsg:kErrorGroupProviderInit]) {
        return nil;
    }

    _groupDataProvider->SetStorageDelegate(_groupStorageDelegate);
    errorCode = _groupDataProvider->Init();
    if ([self checkForInitError:(CHIP_NO_ERROR == errorCode) logMsg:kErrorGroupProviderInit]) {
        return nil;
    }

    _controllers = [[NSMutableArray alloc] init];
    if ([self checkForInitError:(_controllers != nil) logMsg:kErrorControllersInit]) {
        return nil;
    }

    return self;
}

- (void)dealloc
{
    [self shutdown];
    [self cleanupInitObjects];
}

- (BOOL)checkForInitError:(BOOL)condition logMsg:(NSString *)logMsg
{
    if (condition) {
        return NO;
    }

    CHIP_LOG_ERROR("Error: %@", logMsg);

    [self cleanupInitObjects];

    return YES;
}

- (void)cleanupInitObjects
{
    _controllers = nil;

    if (_groupDataProvider) {
        _groupDataProvider->Finish();
        delete _groupDataProvider;
        _groupDataProvider = nullptr;
    }

    if (_groupStorageDelegate) {
        delete _groupStorageDelegate;
        _groupStorageDelegate = nullptr;
    }

    Platform::MemoryShutdown();
}

- (void)cleanupStartupObjects
{
    if (_attestationTrustStoreBridge) {
        delete _attestationTrustStoreBridge;
        _attestationTrustStoreBridge = nullptr;
    }

    if (_persistentStorageDelegateBridge) {
        delete _persistentStorageDelegateBridge;
        _persistentStorageDelegateBridge = nullptr;
    }
}

- (BOOL)startup:(MatterControllerFactoryParams *)startupParams
{
    if ([self isRunning]) {
        CHIP_LOG_DEBUG("Ignoring duplicate call to startup, Matter controller factory already started...");
        return YES;
    }

    DeviceLayer::PlatformMgrImpl().StartEventLoopTask();

    dispatch_sync(_chipWorkQueue, ^{
        if ([self isRunning]) {
            return;
        }

        [CHIPControllerAccessControl init];

        _persistentStorageDelegateBridge = new CHIPPersistentStorageDelegateBridge(startupParams.storageDelegate);
        if (_persistentStorageDelegateBridge == nil) {
            CHIP_LOG_ERROR("Error: %@", kErrorPersistentStorageInit);
            return;
        }

        // Initialize device attestation verifier
        if (startupParams.paaCerts) {
            _attestationTrustStoreBridge = new CHIPAttestationTrustStoreBridge(startupParams.paaCerts);
            if (_attestationTrustStoreBridge == nullptr) {
                CHIP_LOG_ERROR("Error: %@", kErrorAttestationTrustStoreInit);
                return;
            }
            chip::Credentials::SetDeviceAttestationVerifier(chip::Credentials::GetDefaultDACVerifier(_attestationTrustStoreBridge));
        } else {
            // TODO: Replace testingRootStore with a AttestationTrustStore that has the necessary official PAA roots available
            const chip::Credentials::AttestationTrustStore * testingRootStore = chip::Credentials::GetTestAttestationTrustStore();
            chip::Credentials::SetDeviceAttestationVerifier(chip::Credentials::GetDefaultDACVerifier(testingRootStore));
        }

        chip::Controller::FactoryInitParams params;
        if (startupParams.port != nil) {
            params.listenPort = [startupParams.port unsignedShortValue];
        }
        if (startupParams.startServer == YES) {
            params.enableServerInteractions = true;
        }

        params.groupDataProvider = _groupDataProvider;
        params.fabricIndependentStorage = _persistentStorageDelegateBridge;
        CHIP_ERROR errorCode = _controllerFactory->Init(params);
        if (errorCode != CHIP_NO_ERROR) {
            CHIP_LOG_ERROR("Error: %@", kErrorControllerFactoryInit);
            return;
        }

        self->_isRunning = YES;
    });

    // Make sure to stop the event loop again before returning, so we are not running it while we don't have any controllers.
    DeviceLayer::PlatformMgrImpl().StopEventLoopTask();

    if (![self isRunning]) {
        [self cleanupStartupObjects];
    }

    return [self isRunning];
}

- (void)shutdown
{
    if (![self isRunning]) {
        return;
    }

    while ([_controllers count] != 0) {
        [_controllers[0] shutdown];
    }

    CHIP_LOG_DEBUG("%@", kInfoFactoryShutdown);
    _controllerFactory->Shutdown();

    [self cleanupStartupObjects];

    // NOTE: we do not call cleanupInitObjects because we can be restarted, and
    // that does not re-create the objects that we create inside init.
    // Maybe we should be creating them in startup?

    _isRunning = NO;
}

- (CHIPDeviceController * _Nullable)startControllerOnExistingFabric:(CHIPDeviceControllerStartupParams *)startupParams
{
    if (![self isRunning]) {
        CHIP_LOG_ERROR("Trying to start controller while Matter controller factory is not running");
        return nil;
    }

    // Make a copy of the startup params, because we're going to fill
    // out various optional fields and we don't want to modify what
    // the caller passed us, especially from another work queue.
    auto * params = [[CHIPDeviceControllerStartupParamsInternal alloc] initWithKeypair:startupParams.nocSigner
                                                                              fabricId:startupParams.fabricId
                                                                                   ipk:startupParams.ipk];
    if (params == nil) {
        return nil;
    }
    params.vendorId = startupParams.vendorId;
    params.nodeId = startupParams.nodeId;
    params.rootCertificate = startupParams.rootCertificate;
    params.intermediateCertificate = startupParams.intermediateCertificate;

    // Create the controller, so we start the event loop, since we plan to do our fabric table operations there.
    auto * controller = [self createController];
    if (controller == nil) {
        return nil;
    }

    __block BOOL okToStart = NO;
    dispatch_sync(_chipWorkQueue, ^{
        FabricTable fabricTable;
        FabricInfo * fabric = nullptr;
        BOOL ok = [self findMatchingFabric:fabricTable params:params fabric:&fabric];
        if (!ok) {
            CHIP_LOG_ERROR("Can't start on existing fabric: fabric matching failed");
            return;
        }

        if (fabric == nullptr) {
            CHIP_LOG_ERROR("Can't start on existing fabric: fabric not found");
            return;
        }

        for (CHIPDeviceController * existing in _controllers) {
            BOOL isRunning = YES; // assume the worst
            if ([existing isRunningOnFabric:fabric isRunning:&isRunning] != CHIP_NO_ERROR) {
                CHIP_LOG_ERROR("Can't tell what fabric a controller is running on.  Not safe to start.");
                return;
            }

            if (isRunning) {
                CHIP_LOG_ERROR("Can't start on existing fabric: another controller is running on it");
                return;
            }
        }

        // Fill out our params.
        if (params.vendorId == nil) {
            params.vendorId = @(fabric->GetVendorId());
        }

        if (params.nodeId == nil) {
            params.nodeId = @(fabric->GetNodeId());
            ByteSpan noc;
            CHIP_ERROR err = fabric->GetNOCCert(noc);
            if (err != CHIP_NO_ERROR) {
                CHIP_LOG_ERROR("Failed to get existing NOC: %s", ErrorStr(err));
                return;
            }
            params.operationalCertificate = MatterCertToX509Data(noc);
            if (params.operationalCertificate == nil) {
                CHIP_LOG_ERROR("Failed to convert TLV NOC to DER X.509: %s", ErrorStr(err));
                return;
            }
            if (fabric->GetOperationalKey() == nullptr) {
                CHIP_LOG_ERROR("No existing operational key for fabric");
                return;
            }
            params.operationalKeypair = new Crypto::P256SerializedKeypair();
            if (params.operationalKeypair == nullptr) {
                CHIP_LOG_ERROR("Failed to allocate serialized keypair");
                return;
            }

            err = fabric->GetOperationalKey()->Serialize(*params.operationalKeypair);
            if (err != CHIP_NO_ERROR) {
                CHIP_LOG_ERROR("Failed to serialize operational keypair: %s", ErrorStr(err));
                return;
            }
        }

        NSData * oldIntermediateCert = nil;
        {
            ByteSpan icaCert;
            CHIP_ERROR err = fabric->GetICACert(icaCert);
            if (err != CHIP_NO_ERROR) {
                CHIP_LOG_ERROR("Failed to get existing intermediate certificate: %s", ErrorStr(err));
                return;
            }
            // There might not be an ICA cert for this fabric.
            if (!icaCert.empty()) {
                oldIntermediateCert = MatterCertToX509Data(icaCert);
                if (oldIntermediateCert == nil) {
                    return;
                }
            }
        }

        if (params.intermediateCertificate == nil && oldIntermediateCert != nil) {
            // It's possible that we are switching from using an ICA cert to
            // not using one.  We can detect this case by checking whether the
            // provided nocSigner matches the ICA cert.
            if ([MTRCertificates keypair:params.nocSigner matchesCertificate:oldIntermediateCert] == YES) {
                // Keep using the existing intermediate certificate.
                params.intermediateCertificate = oldIntermediateCert;
            }
            // else presumably the nocSigner matches the root (will be
            // verified later) and we are no longer using an intermediate.
        }

        // If we are changing from having an ICA to not having one, or changing
        // from having one to not having one, or changing the identity of our
        // ICA, we need to generate a new NOC.  But we can keep our existing
        // operational keypair and node id; nothing is forcing us to rotate
        // those.
        if ((oldIntermediateCert == nil) != (params.intermediateCertificate == nil)
            || ((oldIntermediateCert != nil) &&
                [MTRCertificates isCertificate:oldIntermediateCert equalTo:params.intermediateCertificate] == NO)) {
            params.operationalCertificate = nil;
        }

        NSData * oldRootCert;
        {
            ByteSpan rootCert;
            CHIP_ERROR err = fabric->GetRootCert(rootCert);
            if (err != CHIP_NO_ERROR) {
                CHIP_LOG_ERROR("Failed to get existing root certificate: %s", ErrorStr(err));
                return;
            }
            oldRootCert = MatterCertToX509Data(rootCert);
            if (oldRootCert == nil) {
                return;
            }
        }

        if (params.rootCertificate == nil) {
            params.rootCertificate = oldRootCert;
        } else if ([MTRCertificates isCertificate:oldRootCert equalTo:params.rootCertificate] == NO) {
            CHIP_LOG_ERROR("Root certificate identity does not match existing root certificate");
            return;
        }

        okToStart = YES;
    });

    if (okToStart == NO) {
        [self controllerShuttingDown:controller];
        return nil;
    }

    BOOL ok = [controller startup:params];
    if (ok == NO) {
        return nil;
    }

    return controller;
}

- (CHIPDeviceController * _Nullable)startControllerOnNewFabric:(CHIPDeviceControllerStartupParams *)startupParams
{
    if (![self isRunning]) {
        CHIP_LOG_ERROR("Trying to start controller while Matter controller factory is not running");
        return nil;
    }

    if (startupParams.vendorId == nil) {
        CHIP_LOG_ERROR("Must provide vendor id when starting controller on new fabric");
        return nil;
    }

    if (startupParams.intermediateCertificate != nil && startupParams.rootCertificate == nil) {
        CHIP_LOG_ERROR("Must provide a root certificate when using an intermediate certificate");
        return nil;
    }

    // Make a copy of the startup params, because we're going to fill
    // out various optional fields and we don't want to modify what
    // the caller passed us, especially from another work queue.
    auto * params = [[CHIPDeviceControllerStartupParamsInternal alloc] initWithKeypair:startupParams.nocSigner
                                                                              fabricId:startupParams.fabricId
                                                                                   ipk:startupParams.ipk];
    if (params == nil) {
        return nil;
    }
    params.vendorId = startupParams.vendorId;
    params.nodeId = startupParams.nodeId;
    params.rootCertificate = startupParams.rootCertificate;
    params.intermediateCertificate = startupParams.intermediateCertificate;

    // Create the controller, so we start the event loop, since we plan to do our fabric table operations there.
    auto * controller = [self createController];
    if (controller == nil) {
        return nil;
    }

    __block BOOL okToStart = NO;
    dispatch_sync(_chipWorkQueue, ^{
        FabricTable fabricTable;
        FabricInfo * fabric = nullptr;
        BOOL ok = [self findMatchingFabric:fabricTable params:params fabric:&fabric];
        if (!ok) {
            CHIP_LOG_ERROR("Can't start on new fabric: fabric matching failed");
            return;
        }

        if (fabric != nullptr) {
            CHIP_LOG_ERROR("Can't start on new fabric that matches existing fabric");
            return;
        }

        if (params.nodeId == nil) {
            // Just avoid setting the top bit, to avoid issues with node
            // ids outside the operational range.
            uint64_t nodeId = arc4random();
            nodeId = (nodeId << 31) | (arc4random() >> 1);
            params.nodeId = @(nodeId);
        }

        if (params.rootCertificate == nil) {
            NSError * error;
            params.rootCertificate = [MTRCertificates generateRootCertificate:params.nocSigner
                                                                     issuerId:nil
                                                                     fabricId:@(params.fabricId)
                                                                        error:&error];
            if (error != nil || params.rootCertificate == nil) {
                CHIP_LOG_ERROR("Failed to generate root certificate: %@", error);
                return;
            }
        }

        okToStart = YES;
    });

    if (okToStart == NO) {
        [self controllerShuttingDown:controller];
        return nil;
    }

    BOOL ok = [controller startup:params];
    if (ok == NO) {
        return nil;
    }

    return controller;
}

- (CHIPDeviceController * _Nullable)createController
{
    CHIPDeviceController * controller = [[CHIPDeviceController alloc] initWithFactory:self queue:_chipWorkQueue];
    if (controller == nil) {
        CHIP_LOG_ERROR("Failed to init controller");
        return nil;
    }

    if ([_controllers count] == 0) {
        // Bringing up the first controller.  Start the event loop now.  If we
        // fail to bring it up, its cleanup will stop the event loop again.
        chip::DeviceLayer::PlatformMgrImpl().StartEventLoopTask();
    }

    // Add the controller to _controllers now, so if we fail partway through its
    // startup we will still do the right cleanups.
    [_controllers addObject:controller];

    return controller;
}

// Finds a fabric that matches the given params, if one exists.
//
// Returns NO on failure, YES on success.  If YES is returned, the
// outparam will be written to, but possibly with a null value.
//
// fabricTable should be an un-initialized fabric table.  It needs to
// outlive the consumer's use of the FabricInfo we return, which is
// why it's provided by the caller.
- (BOOL)findMatchingFabric:(FabricTable &)fabricTable
                    params:(CHIPDeviceControllerStartupParams *)params
                    fabric:(FabricInfo * _Nullable * _Nonnull)fabric
{
    CHIP_ERROR err = fabricTable.Init(_persistentStorageDelegateBridge);
    if (err != CHIP_NO_ERROR) {
        CHIP_LOG_ERROR("Can't initialize fabric table: %s", ErrorStr(err));
        return NO;
    }

    Crypto::P256PublicKey pubKey;
    if (params.rootCertificate != nil) {
        err = ExtractPubkeyFromX509Cert(AsByteSpan(params.rootCertificate), pubKey);
        if (err != CHIP_NO_ERROR) {
            CHIP_LOG_ERROR("Can't extract public key from root certificate: %s", ErrorStr(err));
            return NO;
        }
    } else {
        // No root certificate means the nocSigner is using the root keys, because
        // consumers must provide a root certificate whenever an ICA is used.
        err = CHIPP256KeypairBridge::MatterPubKeyFromSecKeyRef(params.nocSigner.pubkey, &pubKey);
        if (err != CHIP_NO_ERROR) {
            CHIP_LOG_ERROR("Can't extract public key from CHIPKeypair: %s", ErrorStr(err));
            return NO;
        }
    }

    *fabric = fabricTable.FindFabric(Credentials::P256PublicKeySpan(pubKey.ConstBytes()), params.fabricId);
    return YES;
}

@end

@implementation MatterControllerFactory (InternalMethods)

- (void)controllerShuttingDown:(CHIPDeviceController *)controller
{
    if (![_controllers containsObject:controller]) {
        CHIP_LOG_ERROR("Controller we don't know about shutting down");
        return;
    }

    if (_groupDataProvider != nullptr) {
        dispatch_sync(_chipWorkQueue, ^{
            FabricIndex idx = [controller fabricIndex];
            if (idx != kUndefinedFabricIndex) {
                // Clear out out group keys for this fabric index, just in case fabric
                // indices get reused later.  If a new controller is started on the
                // same fabric it will be handed the IPK at that point.
                self->_groupDataProvider->RemoveGroupKeys(idx);
            }
        });
    }

    [_controllers removeObject:controller];

    if ([_controllers count] == 0) {
        // That was our last controller.  Stop the event loop before it
        // shuts down, because shutdown of the last controller will tear
        // down most of the world.
        DeviceLayer::PlatformMgrImpl().StopEventLoopTask();
    }
}

- (CHIPPersistentStorageDelegateBridge *)storageDelegateBridge
{
    return _persistentStorageDelegateBridge;
}

- (Credentials::GroupDataProvider *)groupData
{
    return _groupDataProvider;
}

@end

@implementation MatterControllerFactoryParams

- (instancetype)initWithStorage:(id<CHIPPersistentStorageDelegate>)storageDelegate
{
    if (!(self = [super init])) {
        return nil;
    }

    _storageDelegate = storageDelegate;
    _paaCerts = nil;
    _port = nil;
    _startServer = NO;

    return self;
}

@end