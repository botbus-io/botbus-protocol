// Bridges：给不原生支持 ACP 的 agent 用的 Mac 端桥接器（开源连接器设计 §8），目前还没有任何一个。
//
// 一个桥接器交给 `AcpHub` 一份 `origin: .bridge` 的 `AcpAgentSpec` 和一个 `AcpLauncherFactory`：可以起真实子进程，
// 也可以在进程内实现 ACP 的 agent 一端、用内存管道对接。电脑上 agent 自己开的会话由桥接器自己发现与观察
// （做法同 DeepSeek Harness 连接器），再经反向扩展上报。它只是 Mac 端代码，手机永远看不到 agent 的原生协议。
//
// 这个文件只占住目录：放 README.md 会让 SwiftPM 报「未处理的文件」警告。
