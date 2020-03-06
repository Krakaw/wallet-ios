/*
 * Onion Browser
 * Copyright (c) 2012-2018, Tigas Ventures, LLC (Mike Tigas)
 *
 * This file is part of Onion Browser. See LICENSE file for redistribution terms.
 */
// swiftlint:disable all
import Foundation
import Reachability
import Tor

enum OnionManagerErrors: Error {
    case missingCookieFile
}

protocol OnionManagerDelegate {
    func torConnProgress(_: Int)
    func torConnFinished(configuration: URLSessionConfiguration)
    func torConnError()
}

public class OnionManager: NSObject {
    public enum TorState: Int {
        case none
        case started
        case connected
        case stopped
    }

    public static let shared = OnionManager()
    
    public static let CONTROL_ADDRESS = "127.0.0.1"
    public static let CONTROL_PORT = "39069"

    public static func getCookie() throws -> Data {
        if let cookieURL = OnionManager.torBaseConf.dataDirectory?.appendingPathComponent("control_auth_cookie") {
            let cookie = try Data(contentsOf: cookieURL)
            
            #if DEBUG
            print("[\(String(describing: OnionManager.self))] cookieURL=", cookieURL as Any)
            print("[\(String(describing: OnionManager.self))] cookie=", cookie)
            #endif
            
            return cookie
        } else {
            throw OnionManagerErrors.missingCookieFile
        }
    }
    
    private var reachability: Reachability?
    
    // Show Tor log in iOS' app log.
    private static let TOR_LOGGING = false

    private static let torBaseConf: TorConfiguration = {
        // Store data in <appdir>/Library/Caches/tor (Library/Caches/ is for things that can persist between
        // launches -- which we'd like so we keep descriptors & etc -- but don't need to be backed up because
        // they can be regenerated by the app)
        let dirPaths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let docsDir = dirPaths[0].path
        let dataDir = URL(fileURLWithPath: docsDir, isDirectory: true).appendingPathComponent("tor", isDirectory: true)
        #if DEBUG
        print("[\(String(describing: OnionManager.self))] dataDir=\(dataDir)")
        #endif

        // Create tor data directory if it does not yet exist
        do {
            try FileManager.default.createDirectory(atPath: dataDir.path, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            print("[\(String(describing: OnionManager.self))] error=\(error.localizedDescription))")
        }
        // Create tor v3 auth directory if it does not yet exist
        let authDir = URL(fileURLWithPath: dataDir.path, isDirectory: true).appendingPathComponent("auth", isDirectory: true)
        do {
            try FileManager.default.createDirectory(atPath: authDir.path, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            print("[\(String(describing: OnionManager.self))] error=\(error.localizedDescription))")
        }

        // Configure tor and return the configuration object
        let configuration = TorConfiguration()
        configuration.cookieAuthentication = true
        configuration.dataDirectory = dataDir

        #if DEBUG
        let log_loc = "notice stdout"
        #else
        let log_loc = "notice file /dev/null"
        #endif

        var config_args = [
            "--allow-missing-torrc",
            "--ignore-missing-torrc",
            "--clientonly", "1",
            "--socksport", "39059",
            "--controlport", "\(OnionManager.CONTROL_ADDRESS):\(OnionManager.CONTROL_PORT)",
            "--log", log_loc,
            "--clientuseipv6", "1",
            "--ClientTransportPlugin", "obfs4 socks5 127.0.0.1:47351",
            "--ClientTransportPlugin", "meek_lite socks5 127.0.0.1:47352",
            "--ClientOnionAuthDir", authDir.path
        ]

        configuration.arguments = config_args
        return configuration
    }()

    // MARK: - OnionManager instance
    private var torController: TorController?

    private var torThread: TorThread?

    public var state = TorState.none
    private var initRetry: DispatchWorkItem?
    private var failGuard: DispatchWorkItem?

    private var customBridges: [String]?
    private var needsReconfiguration: Bool = false

    @objc func networkChange() {
        var confs: [Dictionary<String, String>] = []

        confs.append(["key": "ClientPreferIPv6DirPort", "value": "auto"])
        confs.append(["key": "ClientPreferIPv6ORPort", "value": "auto"])
        confs.append(["key": "clientuseipv4", "value": "1"])

        torController?.setConfs(confs, completion: { _, _ in
        })
        torReconnect()
    }

    func torReconnect() {
        torController?.sendCommand("RELOAD", arguments: nil, data: nil, observer: { _, _, _ -> Bool in
            true
        })
        torController?.sendCommand("SIGNAL NEWNYM", arguments: nil, data: nil, observer: { _, _, _ -> Bool in
            true
        })
    }

    func startTor(delegate: OnionManagerDelegate?) {
        cancelInitRetry()
        cancelFailGuard()
        state = .started

        if (self.torController == nil) {
            self.torController = TorController(socketHost: "127.0.0.1", port: 39069)
        }
  
        do {
            reachability = try Reachability()
        } catch {
            print("[\(String(describing: OnionManager.self))] error=\(error)")
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.networkChange), name: NSNotification.Name.reachabilityChanged, object: nil)
        try? reachability?.startNotifier()

        if ((self.torThread == nil) || (self.torThread?.isCancelled ?? true)) {
            self.torThread = nil

            let torConf = OnionManager.torBaseConf

            let args = torConf.arguments

            #if DEBUG
            dump("\n\n\(String(describing: args))\n\n")
            #endif
            torConf.arguments = args
            self.torThread = TorThread(configuration: torConf)
            needsReconfiguration = false

            self.torThread?.start()

            print("[\(String(describing: OnionManager.self))] Starting Tor")
        } else {
            if needsReconfiguration {
                // Not using bridges, so null out the "Bridge" conf
                torController?.setConfForKey("usebridges", withValue: "0", completion: { _, _ in
                })
                torController?.resetConf(forKey: "bridge", completion: { _, _ in
                })
            }
        }

        // Wait long enough for tor itself to have started. It's OK to wait for this
        // because Tor is already trying to connect; this is just the part that polls for
        // progress.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: { [weak self] in
            guard let self = self else { return }
            
            if OnionManager.TOR_LOGGING {
                // Show Tor log in iOS' app log.
                TORInstallTorLogging()
                TORInstallEventLogging()
            }

            if !(self.torController?.isConnected ?? false) {
                do {
                    try self.torController?.connect()
                } catch {
                    print("[\(String(describing: OnionManager.self))] error=\(error)")
                }
            }
            
            do {
                let cookie = try OnionManager.getCookie()
                
                self.torController?.authenticate(with: cookie, completion: { [weak self] success, _ in
                    guard let self = self else { return }
                    
                    if success {
                        var completeObs: Any?
                        completeObs = self.torController?.addObserver(forCircuitEstablished: { established in
                            if established {
                                self.state = .connected
                                self.torController?.removeObserver(completeObs)
                                self.cancelInitRetry()
                                self.cancelFailGuard()
                                #if DEBUG
                                print("[\(String(describing: OnionManager.self))] connection established")
                                #endif
                                
                                self.torController?.getSessionConfiguration({ configuration in
                                    //TODO once below issue is resolved we can update to < 400.6.3 then the session config will not be nil
                                    //https://github.com/iCepa/Tor.framework/issues/60
                                    delegate?.torConnFinished(configuration: configuration ?? URLSessionConfiguration.default)
                                })
                            }
                        }) // torController.addObserver
                        var progressObs: Any?
                        progressObs = self.torController?.addObserver(forStatusEvents: { [weak self]
                            (type: String, _: String, action: String, arguments: [String: String]?) -> Bool in
                            guard let self = self else { return false }

                            if type == "STATUS_CLIENT" && action == "BOOTSTRAP" {
                                guard let args = arguments else { return false }
                                guard let progressArg = args["PROGRESS"] else { return false }
                                guard let progress = Int(progressArg) else { return false }
                                
                                #if DEBUG
                                print("[\(String(describing: OnionManager.self))] progress=\(progress)")
                                #endif

                                delegate?.torConnProgress(progress)

                                if progress >= 100 {
                                    self.torController?.removeObserver(progressObs)
                                }

                                return true
                            }

                            return false
                        }) // torController.addObserver
                    } // if success (authenticate)
                    else { print("[\(String(describing: OnionManager.self))] Didn't connect to control port.") }
                }) // controller authenticate
            } catch {
                print("[\(String(describing: OnionManager.self))] error=\(error)")
            }
        }) //delay
        initRetry = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            #if DEBUG
            print("[\(String(describing: OnionManager.self))] Triggering Tor connection retry.")
            #endif
            self.torController?.setConfForKey("DisableNetwork", withValue: "1", completion: { _, _ in
            })

            self.torController?.setConfForKey("DisableNetwork", withValue: "0", completion: { _, _ in
            })

            self.failGuard = DispatchWorkItem {
                if self.state != .connected {
                    delegate?.torConnError()
                }
            }

            // Show error to user, when, after 90 seconds (30 sec + one retry of 60 sec), Tor has still not started.
            guard let executeFailGuard = self.failGuard else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: executeFailGuard)
        }

        // On first load: If Tor hasn't finished bootstrap in 30 seconds,
        // HUP tor once in case we have partially bootstrapped but got stuck.
        guard let executeRetry = initRetry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: executeRetry)

    }// startTor
    /**
     Experimental Tor shutdown.
     */
    @objc func stopTor() {
        print("[\(String(describing: OnionManager.self))] #stopTor")

        // under the hood, TORController will SIGNAL SHUTDOWN and set it's channel to nil, so
        // we actually rely on that to stop tor and reset the state of torController. (we can
        // SIGNAL SHUTDOWN here, but we can't reset the torController "isConnected" state.)
        self.torController?.disconnect()

        self.torController = nil

        // More cleanup
        self.torThread?.cancel()
        self.state = .stopped
    }

    /**
     Cancel the connection retry
     */
    private func cancelInitRetry() {
        initRetry?.cancel()
        initRetry = nil
    }
    
    /**
     Cancel the fail guard.
     */
    private func cancelFailGuard() {
        failGuard?.cancel()
        failGuard = nil
    }
}