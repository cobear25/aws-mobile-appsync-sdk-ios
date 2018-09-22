//
//  AWSAppSyncDeltaSubscription.swift
//  AWSAppSync
//

import Foundation
import Reachability

public enum DeltaSyncState {
    case active, failed(error: Error), interrupted, terminated(error: Error), cancelled
}

public typealias DeltaSyncStatusCallback = ((_ currentState: DeltaSyncState) -> Void)

public class SyncConfiguration {
    
    internal let seconds: Int
    internal let initialSyncTime: Date?
    
    internal var syncIntervalInSeconds: Int {
        return seconds
    }
    
    public init(seconds: Int, initialSyncTime: Date? = nil) {
        self.seconds = seconds
        self.initialSyncTime = initialSyncTime
    }
    
    // utility for setting default sync to 1 day
    public class func defaultSyncConfiguration() -> SyncConfiguration {
        return SyncConfiguration(seconds: 86400)
    }
}

public typealias DeltaQueryResultHandler<Operation: GraphQLQuery> = (_ result: GraphQLResult<Operation.Data>?, _ transaction: ApolloStore.ReadWriteTransaction?, _ error: Error?) -> Void

internal class AppSyncDeltaSubscription<Subscription: GraphQLSubscription, BaseQuery: GraphQLQuery, DeltaQuery: GraphQLQuery>: Cancellable {
    
    weak var appsyncClient: AWSAppSyncClient?
    weak var subscriptionMetadataCache: AWSSubscriptionMetaDataCache?
    var syncConfiguration: SyncConfiguration
    var subscription: Subscription?
    var baseQuery: BaseQuery?
    var deltaQuery: DeltaQuery?
    var subscriptionHandler: SubscriptionResultHandler<Subscription>?
    var baseQueryHandler: OperationResultHandler<BaseQuery>?
    var deltaQueryHandler: DeltaQueryResultHandler<DeltaQuery>?
    var subscriptionWatcher: AWSAppSyncSubscriptionWatcher<Subscription>?
    var userCancelledSubscription: Bool = false
    var shouldQueueSubscriptionMessages: Bool = false
    var subscriptionMessagesQueue: [(GraphQLResult<Subscription.Data>, Date)] = []
    var reachability: Reachability? = Reachability.init()
    var isNetworkAvailable: Bool = true
    var lastSyncTime: Date?
    var lastBaseQueryFetchTime: Date?
    var serialQueue: DispatchQueue?
    var deltaSyncQueue: DispatchQueue?
    var deltaSyncOperationQueue: OperationQueue?
    var deltaSyncSerialQueue: DispatchQueue?
    weak var handlerQueue: DispatchQueue?
    var activeTimer: DispatchSourceTimer?
    var deltaSyncStatusCallback: DeltaSyncStatusCallback?
    var isFirstSync: Bool = true
    var isFirstSyncOperation: Bool = true
    var initialNetworkState: Bool = true
    var didBaseQueryRunFromNetwork: Bool = false
    
    internal init(appsyncClient: AWSAppSyncClient,
                  isNetworkAvailable: Bool,
                  baseQuery: BaseQuery,
                  deltaQuery: DeltaQuery,
                  subscription: Subscription,
                  baseQueryHandler: @escaping OperationResultHandler<BaseQuery>,
                  deltaQueryHandler: @escaping DeltaQueryResultHandler<DeltaQuery>,
                  subscriptionResultHandler: @escaping SubscriptionResultHandler<Subscription>,
                  subscriptionMetadataCache: AWSSubscriptionMetaDataCache?,
                  syncConfiguration: SyncConfiguration,
                  handlerQueue: DispatchQueue) {
        self.appsyncClient = appsyncClient
        self.subscriptionMetadataCache = subscriptionMetadataCache
        self.syncConfiguration = syncConfiguration
        self.handlerQueue = handlerQueue
        self.baseQuery = baseQuery
        
        if Subscription.operationString != "No-op" {
            self.subscription = subscription
            self.subscriptionHandler = subscriptionResultHandler
        }
        if DeltaQuery.operationString != "No-op" {
            self.deltaQuery = deltaQuery
            self.deltaQueryHandler = deltaQueryHandler
        }
        self.baseQueryHandler = baseQueryHandler
        self.initialNetworkState = isNetworkAvailable
        // self.deltaSyncStatusCallback = deltaSyncStatusCallback
        self.serialQueue = DispatchQueue(label: "AppSync.LastSyncTimeSerialQueue")
        self.deltaSyncQueue = DispatchQueue(label: "AppSync.DeltaSyncAsyncQueue.\(getOperationHash())")
        self.deltaSyncOperationQueue = OperationQueue()
        deltaSyncOperationQueue?.maxConcurrentOperationCount = 1
        deltaSyncOperationQueue?.name = "AppSync.DeltaSyncOperationQueue.\(getOperationHash())"
        self.deltaSyncSerialQueue = DispatchQueue(label: "AppSync.DeltaSyncSerialQueue.\(getOperationHash())")
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(AppSyncDeltaSubscription.applicationWillEnterForeground),
                                               name: .UIApplicationWillEnterForeground, object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(AppSyncDeltaSubscription.didConnectivityChange(notification:)),
                                               name: .appSyncReachabilityChanged, object: nil)
        
        loadSyncTimeFromCache()
        self.deltaSyncOperationQueue?.addOperation {
            AppSyncLog.debug("DS: =============== Perform Sync Main =============== ")
            self.performDeltaSync()
        }
    }
    
    func getUniqueIdentifierForOperation() -> String {
        return getOperationHash()
    }
    
    func performDeltaSync() {
        AppSyncLog.debug("DS: =============== Perform Sync =============== ")
         self.deltaSyncSerialQueue!.sync {
            AppSyncLog.debug("DS: =============== Got Thread =============== ")
            shouldQueueSubscriptionMessages = true
            didBaseQueryRunFromNetwork = false
            
            defer{
                // setup the timer to force catch up using the base query
                activeTimer = setupAsyncPoll(pollDuration: syncConfiguration.syncIntervalInSeconds)
                // deltaSyncStatusCallback?(.active)
                shouldQueueSubscriptionMessages = false
                drainSubscriptionMessagesQueue()
            }
            
            if (isFirstSyncOperation) {
                runBaseQueryFromCache()
                isFirstSyncOperation = false
            }
            
            guard startSubscription() == true else {
                return
            }
            
            guard runBaseQuery() == true else {
                return
            }
            
            // If we ran baseQuery in this iteration of sync, we do not run the delta query
            if !self.didBaseQueryRunFromNetwork {
                guard runDeltaQuery() == true else {
                    return
                }
            }
        }
    }
    
    func executeAfter(milliseconds interval: Int, queue: DispatchQueue, block: @escaping () -> Void ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: 0), queue: queue)
        #if swift(>=4)
        timer.schedule(deadline: .now() + .milliseconds(interval))
        #else
        timer.scheduleOneshot(deadline: .now() + .milliseconds(interval))
        #endif
        timer.setEventHandler(handler: block)
        timer.resume()
        return timer
    }
    
    func setupAsyncPoll(pollDuration: Int) -> DispatchSourceTimer {
        // Invalidate existing time and restart again
        activeTimer?.cancel()
        
        return executeAfter(milliseconds: pollDuration * 1000, queue: self.handlerQueue!) {
            AppSyncLog.debug("DS: Timer fired. Performing sync.")
            self.deltaSyncOperationQueue?.addOperation {
                AppSyncLog.debug("DS: =============== Perform Sync Timer =============== ")
                self.performDeltaSync()
            }
        }
    }
    
    // for first call, always try to fetch and return from cache.
    func runBaseQueryFromCache() {
        if let baseQuery = baseQuery {
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()
            AppSyncLog.info("DS: Running base query from cache.")
            appsyncClient?.fetch(query: baseQuery, cachePolicy: CachePolicy.returnCacheDataDontFetch, resultHandler: {[weak self] (result, error) in
                self?.baseQueryHandler?(result, error)
                dispatchGroup.leave()
            })
            dispatchGroup.wait()
            isFirstSyncOperation = false
        }
    }
    
    // Each step represents whether to proceed to next step.
    func runBaseQuery() -> Bool {
        var success: Bool = true
        if let baseQuery = baseQuery {
            // If within time frame, fetch from cache
            if lastSyncTime == nil || (Date() > Date(timeInterval: TimeInterval(exactly: syncConfiguration.syncIntervalInSeconds)!, since: self.lastSyncTime!)){
                AppSyncLog.info("DS: Running Base Query Now")
                self.didBaseQueryRunFromNetwork = true
                let dispatchGroup = DispatchGroup()
                dispatchGroup.enter()
                let networkFetchTime = Date()
                AppSyncLog.info("DS: Running base query from network.")
                appsyncClient?.fetch(query: baseQuery, cachePolicy: .fetchIgnoringCacheData, resultHandler: {[weak self] (result, error) in
                    // call customer if successful or error
                    // return false to parent if failed
                    if error == nil {
                        self?.baseQueryHandler?(result, error)
                        success = true
                    } else if error != nil && result != nil {
                        self?.baseQueryHandler?(result, error)
                        success = true
                    } else {
                        self?.baseQueryHandler?(result, error)
                        success = false
                    }
                    if (success) {
                        AppSyncLog.debug("DS: Updating base query fetch time and last sync time.")
                        self?.updateLastBaseQueryFetchTimeInMemoryAndCache(date: networkFetchTime)
                        self?.updateLastSyncTimeInMemoryAndCache(date: networkFetchTime)
                    }
                    dispatchGroup.leave()
                })
                dispatchGroup.wait()
            }
        }
        return success
    }
    
    
    /// Runs the delta query based on the given criterias.
    ///
    /// - Returns: true if the operation is executed successfully.
    func runDeltaQuery() -> Bool {
        if let deltaQuery = deltaQuery, let lastSyncTime = self.lastSyncTime {
            let dispatchGroup = DispatchGroup()
            AppSyncLog.info("DS: Running Delta Query Now \(self.didBaseQueryRunFromNetwork)")
            if let networkTransport = appsyncClient?.httpTransport as? AWSAppSyncHTTPNetworkTransport {
                dispatchGroup.enter()
                var overrideMap: [String:Int] = [:]
                // we allow developer to override the previous sync time while making the request.
                if isFirstSync && syncConfiguration.initialSyncTime != nil {
                    AppSyncLog.debug("DS: Using the specified override time. \(syncConfiguration.initialSyncTime!.description)")
                    overrideMap = ["lastSync": Int(Float(syncConfiguration.initialSyncTime!.timeIntervalSince1970.description)!)]
                } else if let lastSyncTime = self.lastSyncTime {
                    AppSyncLog.debug("DS: Using last sync time from cache. \(lastSyncTime.description)")
                    overrideMap = ["lastSync": Int(Float(lastSyncTime.timeIntervalSince1970.description)!)]
                } else {
                    AppSyncLog.debug("DS: No last sync time available")
                }
                
                func notifyResultHandler(result: GraphQLResult<DeltaQuery.Data>?, transaction: ApolloStore.ReadWriteTransaction?, error: Error?) {
                    handlerQueue?.async {
                        let _ = self.appsyncClient?.store?.withinReadWriteTransaction { transaction in
                            self.deltaQueryHandler?(result, transaction, error)
                            if (error == nil) {
                                self.updateLastSyncTimeInMemoryAndCache(date: Date())
                            }
                        }
                    }
                }
                
                let _ = networkTransport.send(operation: deltaQuery, overrideMap: overrideMap) {[weak self] (response, error) in
                    guard let response = response else {
                        notifyResultHandler(result: nil, transaction: nil, error: error)
                        return
                    }
                    // we have the parsing logic here to perform custom actions in cache, e.g. if we receive a delete type event, we can remove from store.
                    firstly {
                        try response.parseResult(cacheKeyForObject: self?.appsyncClient?.store!.cacheKeyForObject)
                        }.andThen { (result, records) in
                            notifyResultHandler(result: result, transaction: nil, error: nil)
                            if let records = records {
                                self?.appsyncClient?.store?.publish(records: records, context: nil).catch { error in
                                    preconditionFailure(String(describing: error))
                                }
                            }
                        }.catch { error in
                            notifyResultHandler(result: nil, transaction: nil, error: error)
                    }
                    dispatchGroup.leave()
                }
                dispatchGroup.wait()
            }
        }
        return true
    }
    
    func startSubscription() -> Bool {
        var success = false
        if let subscription = subscription {
            AppSyncLog.info("DS: Starting Sub Now")
            let dispatchGroup = DispatchGroup()
            var updatedSubscriptionWatcher: AWSAppSyncSubscriptionWatcher<Subscription>?
            var isSubscriptionWatcherUpdated: Bool = false
            do {
                dispatchGroup.enter()
                updatedSubscriptionWatcher = try appsyncClient?.subscribeWithConnectCallback(subscription: subscription, connectCallback: ({
                    success = true
                    if (!isSubscriptionWatcherUpdated) {
                        isSubscriptionWatcherUpdated = true
                        self.subscriptionWatcher?.cancel()
                        self.subscriptionWatcher = nil
                        self.subscriptionWatcher = updatedSubscriptionWatcher
                        // self.deltaSyncStatusCallback?(.active)
                        dispatchGroup.leave()
                    }
                }), resultHandler: {[weak self] (result, transaction, error) in
                    self?.handleSubscriptionCallback(result, transaction, error)
                })
                
            } catch {
                self.handleSubscriptionCallback(nil, nil, error)
                success = false
                dispatchGroup.leave()
            }
            dispatchGroup.wait()
        } else {
            success = true
        }
        return success
    }
    
    func handleSubscriptionCallback(_ result: GraphQLResult<Subscription.Data>?, _ transaction: ApolloStore.ReadWriteTransaction?, _ error: Error?) {
        if let error = error as? AWSAppSyncSubscriptionError, error.additionalInfo == "Subscription Terminated." {
            // Do not give the developer a disconnect callback here. We have to retry the subscription once app comes from background to foreground or internet becomes available.
            AppSyncLog.debug("DS: Subscription terminated. Waiting for network to restart.")
            deltaSyncStatusCallback?(.interrupted)
        } else if let result = result, let transaction = transaction {
            if shouldQueueSubscriptionMessages {
                // store arriaval timestamp as well to make sure we use it for maintaining last sync time.
                AppSyncLog.debug("DS: Received subscription message, saving subscription message in queue.")
                subscriptionMessagesQueue.append((result, Date()))
            } else {
                AppSyncLog.debug("DS: Received subscription message, invoking customer callback.")
                subscriptionHandler?(result, transaction, nil)
                updateLastSyncTimeInMemoryAndCache(date: Date())
            }
        } else {
            AppSyncLog.error("DS: Unable to start subscription.")
            deltaSyncStatusCallback?(.interrupted)
        }
    }
    
    /// Drains any messages from the subscription messages queue and updates last sync time to current time.
    func drainSubscriptionMessagesQueue() {
        if let subscriptionHandler = subscriptionHandler {
            AppSyncLog.debug("DS: Dequeuing any available messages from subscription messages queue.")
            AppSyncLog.debug("DS: Found \(subscriptionMessagesQueue.count) messages in queue.")
            for message in subscriptionMessagesQueue {
                do {
                    try self.appsyncClient?.store?.withinReadWriteTransaction({ (transaction) in
                        subscriptionHandler(message.0, transaction, nil)
                    }).await()
                    updateLastSyncTimeInMemoryAndCache(date: message.1)
                } catch {
                    subscriptionHandler(nil, nil, error)
                }
            }
        }
        
        AppSyncLog.debug("DS: Clearing subscription messages queue.")
        subscriptionMessagesQueue = []
    }
    
    
    /// This function generates a unique identifier hash for the combination of specified parameters including the GraphQL variables.
    /// The hash is always same for the same set of operations.
    ///
    /// - Returns: The unique hash for the specified queries & subscription.
    func getOperationHash() -> String {
        
        var baseString = ""
        
        if let baseQuery = baseQuery {
            let variables = baseQuery.variables?.description ?? ""
            baseString =  type(of: baseQuery).requestString + variables
        }
        
        if let subscription = subscription {
            let variables = subscription.variables?.description ?? ""
            baseString = type(of: subscription).requestString + variables
        }
        
        if let deltaQuery = deltaQuery {
            let variables = deltaQuery.variables?.description ?? ""
            baseString =  type(of: deltaQuery).requestString + variables
        }
        
        return AWSSignatureSignerUtility.hash(baseString.data(using: .utf8)!)!.base64EncodedString()
    }
    
    /// Responsible to update the last sync time in cache. Expected to be called when subs message is given to the customer or if base query or delta query is run.
    func updateLastSyncTimeInMemoryAndCache(date: Date) {
        serialQueue!.sync {
            do {
                let adjustedDate = date.addingTimeInterval(TimeInterval.init(exactly: -2)!)
                self.lastSyncTime = adjustedDate
                AppSyncLog.debug("DS: Updating lastSync time \(self.lastSyncTime.debugDescription)")
                try self.subscriptionMetadataCache?.updateLasySyncTime(operationHash: getOperationHash(), lastSyncDate: adjustedDate)
            } catch {
                // ignore cache write failure, will be updated in next operation, is backed up by in-memory cache
            }
        }
    }
    
    /// Responsible to update the last base query fetch time in cache. Expected to be called when base query fetch is done from network.
    func updateLastBaseQueryFetchTimeInMemoryAndCache(date: Date) {
        serialQueue!.sync {
            do {
                let adjustedDate = date.addingTimeInterval(TimeInterval.init(exactly: -2)!)
                self.lastBaseQueryFetchTime = adjustedDate
                try self.subscriptionMetadataCache?.updateBaseQueryFetchTime(operationHash: getOperationHash(), baseQueryFetchTime: adjustedDate)
            } catch {
                // ignore cache write failure, will be updated in next operation, is backed up by in-memory cache time
            }
            
        }
    }
    
    /// Fetches last sync time from the cache.
    func loadSyncTimeFromCache() {
        serialQueue!.sync {
            do {
                self.lastSyncTime = try self.subscriptionMetadataCache?.getLastSyncTime(operationHash: getOperationHash())
                AppSyncLog.debug("DS: lastSync \(self.lastSyncTime.debugDescription)")
            } catch {
                // could not find it in cache, do not update the instance variable of lasy sync time; assume no sync was done previously
            }
            do {
                self.lastBaseQueryFetchTime = try self.subscriptionMetadataCache?.getLastBaseQueryFetchTime(operationHash: getOperationHash())
                AppSyncLog.debug("DS: lastBaseQuery \(self.lastBaseQueryFetchTime.debugDescription)")
            } catch {
                // could not find it in cache, do not update the instance variable of lasy base query fetch time; assume was not fetched previously
            }
        }
    }
    
    @objc func applicationWillEnterForeground() {
        // perform delta sync here
        // disconnect from sub and reconnect
        self.deltaSyncOperationQueue?.addOperation {
            AppSyncLog.debug("DS: =============== Perform Sync Foreground =============== ")
            self.performDeltaSync()
        }
    }
    
    @objc func didConnectivityChange(notification: Notification) {
        // If internet was disconnected and is available now, perform deltaSync
        let connectionInfo = notification.object as! AppSyncConnectionInfo
        
        isNetworkAvailable = connectionInfo.isConnectionAvailable
        
        if (connectionInfo.isConnectionAvailable) {
            self.deltaSyncOperationQueue?.addOperation {
                AppSyncLog.debug("DS: =============== Perform Sync Network =============== ")
                self.performDeltaSync()
            }
        }
    }
    
    deinit {
        internalCancel()
    }
    
    func internalCancel() {
        // handle cancel logic here.
        subscriptionWatcher?.cancel()
        subscriptionWatcher = nil
        NotificationCenter.default.removeObserver(self)
        activeTimer?.cancel()
    }
    
    // This is user-initiated cancel
    func cancel() {
        // perform user-cancelled tasks in this block
        userCancelledSubscription = true
        deltaSyncStatusCallback?(.cancelled)
        internalCancel()
    }
}