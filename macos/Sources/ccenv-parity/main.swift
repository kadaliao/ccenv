// 对拍用的最小 CLI：跑一遍 Swift 引擎，输出和 Node CLI 相同 schema 的 JSON。
import Foundation
import CCEnvCore

let offline = CommandLine.arguments.contains("--offline")
let sem = DispatchSemaphore(value: 0)
Task {
    let report = await CCEnv.check(options: CheckOptions(offline: offline))
    print(CCEnv.json(report))
    sem.signal()
}
sem.wait()
