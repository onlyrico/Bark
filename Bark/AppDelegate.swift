//
//  AppDelegate.swift
//  Bark
//
//  Created by huangfeng on 2018/3/7.
//  Copyright © 2018年 Fin. All rights reserved.
//

import CrashReporter
import IQKeyboardManagerSwift
import IQKeyboardToolbarManager
import SwiftyStoreKit
import UIKit
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
//    var syncEngine: SyncEngine?
    func setupRealm() {
        // Tell Realm to use this new configuration object for the default Realm
        Realm.Configuration.defaultConfiguration = kRealmDefaultConfiguration

//        // iCloud 同步
//        syncEngine = SyncEngine(objects: [
//            SyncObject(type: Message.self)
//        ], databaseScope: .private)

        #if DEBUG
            let realm = try? Realm()
            print("message count: \(realm?.objects(Message.self).count ?? 0)")
        #endif
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        self.window = UIWindow(frame: UIScreen.main.bounds)
        self.window?.backgroundColor = UIColor.black
        
        #if !DEBUG
            let config = PLCrashReporterConfig(signalHandlerType: .mach, symbolicationStrategy: [])
            if let crashReporter = PLCrashReporter(configuration: config) {
                // Enable the Crash Reporter.
                do {
                    try crashReporter.enableAndReturnError()
                } catch {
                    print("Warning: Could not enable crash reporter: \(error)")
                }

                if crashReporter.hasPendingCrashReport() {
                    let reportController = CrashReportViewController()
                    do {
                        let data = try crashReporter.loadPendingCrashReportDataAndReturnError()

                        // Retrieving crash reporter data.
                        let report = try PLCrashReport(data: data)

                        if let text = PLCrashReportTextFormatter.stringValue(for: report, with: PLCrashReportTextFormatiOS) {
                            reportController.crashLog = text
                        } else {
                            print("CrashReporter: can't convert report to text")
                        }
                    } catch {
                        print("CrashReporter failed to load and parse with error: \(error)")
                    }

                    // Purge the report.
                    crashReporter.purgePendingCrashReport()
                    self.window?.rootViewController = reportController
                    self.window?.makeKeyAndVisible()
                    return true
                }
            } else {
                print("Could not create an instance of PLCrashReporter")
            }
        #endif
        
        // 必须在应用一开始就配置，否则应用可能提前在配置之前试用了 Realm() ，则会创建两个独立数据库。
        setupRealm()

        IQKeyboardManager.shared.isEnabled = true
        IQKeyboardToolbarManager.shared.isEnabled = true
        if #available(iOS 14, *), UIDevice.current.userInterfaceIdiom == .pad {
            let splitViewController = BarkSplitViewController(style: .doubleColumn)
            self.window?.rootViewController = BarkSnackbarController(rootViewController: splitViewController)
        } else {
            let tabBarController = BarkTabBarController()
            self.window?.rootViewController = BarkSnackbarController(
                rootViewController: tabBarController
            )
        }
        
        // 需先配置好 tabBarController 的 viewControllers，显示时会默认显示上次打开的页面
        self.window?.makeKeyAndVisible()
        
        UNUserNotificationCenter.current().delegate = self
        var actions = [
            UNNotificationAction(identifier: "copy", title: NSLocalizedString("Copy2"), options: UNNotificationActionOptions.foreground)
        ]
        if #available(iOSApplicationExtension 15.0, *) {
            actions.append(UNNotificationAction(identifier: "mute", title: NSLocalizedString("muteGroup1Hour"), options: UNNotificationActionOptions.foreground))
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            // customDismissAction 会在 clear 推送时，调起APP，这时可以顺便更新下 DeviceToken，防止过期。
            UNNotificationCategory(identifier: "myNotificationCategory", actions: actions, intentIdentifiers: [], options: .customDismissAction)
        ])

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            dispatch_sync_safely_main_queue {
                if settings.authorizationStatus == .authorized {
                    Client.shared.registerForRemoteNotifications()
                }
            }
        }

        // 调整返回按钮样式
        let bar = UINavigationBar.appearance(whenContainedInInstancesOf: [BarkNavigationController.self])
        bar.backIndicatorImage = UIImage(named: "back")
        bar.backIndicatorTransitionMaskImage = UIImage(named: "back")
        bar.tintColor = BKColor.grey.darken4

        // 内购
        SwiftyStoreKit.completeTransactions { _ in }
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print(error)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let deviceTokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Client.shared.deviceToken.accept(deviceTokenString)

        // 注册设备
        ServerManager.shared.syncAllServers()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            // clear 推送时，不要弹出提示框
            return
        }
        notificatonHandler(userInfo: response.notification.request.content.userInfo)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if UIApplication.shared.applicationState == .active {
            stopCallNotificationProcessor()
        }
        return .alert
    }
    
    private func notificatonHandler(userInfo: [AnyHashable: Any]) {
        let viewController = Client.shared.currentSnackbarController
        func presentController() {
            let alert = (userInfo["aps"] as? [String: Any])?["alert"] as? [String: Any]
            let title = alert?["title"] as? String
            let subtitle = alert?["subtitle"] as? String
            let body = alert?["body"] as? String
            let url: URL? = {
                if let url = userInfo["url"] as? String {
                    return URL(string: url)
                }
                return nil
            }()
            
            if let action = userInfo["action"] as? String, action == "none" {
                return
            }

            // URL 直接打开
            if let url = url {
                Client.shared.openUrl(url: url)
                return
            }

            let alertController = UIAlertController(title: title, message: body, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("CopyContent"), style: .default, handler: { _ in
                if let copy = userInfo["copy"] as? String {
                    UIPasteboard.general.string = copy
                } else {
                    UIPasteboard.general.string = body
                }
            }))
            alertController.addAction(UIAlertAction(title: NSLocalizedString("MoreActions"), style: .default, handler: { _ in
                var shareContent = ""
                if let title = title {
                    shareContent += "\(title)\n"
                }
                if let subtitle = subtitle {
                    shareContent += "\(subtitle)\n"
                }
                if let body = body {
                    shareContent += "\(body)\n"
                }
                for (key, value) in userInfo {
                    if ["aps", "title", "subtitle", "body", "url"].contains((key as? String) ?? "") {
                        continue
                    }
                    shareContent += "\(key): \(value) \n"
                }
                var items: [Any] = []
                items.append(shareContent)
                if let url = url {
                    items.append(url)
                }
                let controller = Client.shared.window?.rootViewController
                let activityController = UIActivityViewController(activityItems: items,
                                                                  applicationActivities: nil)
                if let popover = activityController.popoverPresentationController {
                    popover.sourceView = controller?.view
                    popover.sourceRect = CGRect(x: controller?.view.bounds.midX ?? 0, y: controller?.view.bounds.midY ?? 0, width: 0, height: 0)
                }
                controller?.present(activityController, animated: true, completion: nil)
            }))
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel"), style: .cancel, handler: nil))

            viewController?.present(alertController, animated: true, completion: nil)
        }

        if let presentedController = viewController?.presentedViewController {
            presentedController.dismiss(animated: false) {
                presentController()
            }
        } else {
            presentController()
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // 设置 -1 可以清除应用角标，但不清除通知中心的推送
        // 设置 0 会将通知中心的所有推送一起清空掉
        UIApplication.shared.applicationIconBadgeNumber = -1
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 如果有响铃通知，则关闭响铃
        stopCallNotificationProcessor()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if url.scheme?.lowercased() == "bark" && url.host?.lowercased() == "addserver" {
            // 提取参数
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let address = queryItems?.first(where: { $0.name == "address" })?.value

            // 处理添加服务器的逻辑
            if let serverAddress = try? address?.asURL() {
                let server = Server(address: serverAddress.absoluteString, key: "")
                ServerManager.shared.addServer(server: server)
                ServerManager.shared.setCurrentServer(serverId: server.id)
                ServerManager.shared.syncAllServers()
                HUDSuccess(NSLocalizedString("AddedSuccessfully"))
            }
            return true
        }
        return false
    }
    
    /// 停止响铃
    func stopCallNotificationProcessor() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(kStopCallProcessorKey as CFString), nil, nil, true)
    }
}
