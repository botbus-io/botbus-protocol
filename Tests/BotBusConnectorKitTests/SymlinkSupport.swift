import Foundation
import XCTest

extension XCTestCase {
    /// 建符号链接。Windows 上没开开发者模式（也没以管理员运行）时建不了（`ERROR_PRIVILEGE_NOT_HELD`）：
    /// 这条用例跳过而不是失败，其余平台出错照常抛。
    func makeSymbolicLink(at url: URL, withDestinationURL destination: URL) throws {
        do {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        } catch {
            #if os(Windows)
            throw XCTSkip("这台 Windows 上建不了符号链接（要开开发者模式）：\(error)")
            #else
            throw error
            #endif
        }
    }
}
