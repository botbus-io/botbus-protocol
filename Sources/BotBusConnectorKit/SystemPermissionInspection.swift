import Foundation
import BotBusProtocol

/// app 提供的失败后诊断：只检查已经显示的系统授权弹窗，可返回已经上传的截图引用。
/// nil 表示未发现弹窗或本机未启用诊断；Core 不请求权限、不操作弹窗。
public typealias SystemPermissionInspector = @Sendable () async -> SystemPermissionNotice?

/// 不让系统 API 或上传卡住命令回执。单次完成盒子允许超时/取消先返回，即使注入的检查不响应取消。
/// app 仍须给原生检查与上传各自设时限，避免后台工作长期占用资源。
public func inspectSystemPermission(using inspector: @escaping SystemPermissionInspector,
                             timeout: TimeInterval) async -> SystemPermissionNotice? {
    guard !Task.isCancelled else { return nil }
    let completion = OneShotContinuation<SystemPermissionNotice?>()
    let inspection = Task { completion.resume(returning: await inspector()) }
    let deadline = Task {
        do { try await Task.sleep(for: .seconds(max(0, timeout))) }
        catch { return }
        completion.resume(returning: nil)
    }
    return await withTaskCancellationHandler {
        defer { inspection.cancel(); deadline.cancel() }
        return try? await completion.value()
    } onCancel: {
        inspection.cancel()
        deadline.cancel()
        completion.resume(returning: nil)
    }
}
