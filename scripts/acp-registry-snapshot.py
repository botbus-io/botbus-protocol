#!/usr/bin/env python3
"""从 ACP 官方注册表生成 BotBusConnectors 内置的注册表快照（AcpRegistrySnapshot.swift）。

发版前跑一次：./scripts/acp-registry-snapshot.py
运行时 app 不联网拉注册表（spec「发现」）：离线也能用，注册表内容也不会直接变成本机执行的命令。
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

REGISTRY_URL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "BotBusConnectors", "Acp", "AcpRegistrySnapshot.swift")
# 一档已经深度适配的（它们的 ACP 适配器）：跳过，免得同一个 agent 在手机上出现两遍。
RESERVED = {"codex", "claude", "hermes", "pi", "openclaw", "acp", "dsh", "claude-acp", "codex-acp", "pi-acp"}
# 默认关闭的（spec「默认开关」）。目前没有；OpenClaw 若进了注册表要加在这里。
DEFAULT_OFF = {"openclaw"}
ID_PATTERN = re.compile(r"^[a-z0-9-]{1,32}$")


def npm_package_name(package: str) -> str:
    return re.sub(r"@[^@/]+$", "", package)  # 去掉 @版本号，保留 @scope/


def npm_bins(package: str) -> list[str]:
    name = npm_package_name(package)
    try:
        out = subprocess.run(["npm", "view", name, "bin", "--json"], capture_output=True, text=True, timeout=60,
                             check=True).stdout.strip()
    except (subprocess.SubprocessError, FileNotFoundError) as error:
        print(f"  ! npm view {name} 失败：{error}", file=sys.stderr)
        return []
    if not out:
        return []
    value = json.loads(out)
    if isinstance(value, dict):
        return sorted(value.keys())
    if isinstance(value, str):
        return [name.split("/")[-1]]
    return []


def rank_npm_bins(bins: list[str], agent_id: str, package: str) -> list[str]:
    """npm 包名和"装好后敲哪个命令"不一定对得上：`nova` 的包里还带着一个老工具叫 `compass`
    （撞了 Sass 的同名命令），`codebuddy-code` 装出来的 `cbc-prewarm` / `codebuddy-lowmem` 是内部
    预热/低内存变体，不是给用户敲的入口。按跟 agent id、包名的贴合程度排序，先去掉一望而知的
    辅助可执行文件，最多留两个候选（真正认不认，最终看 `AcpDiscovery` 的 node_modules 校验）。
    """
    package_leaf = npm_package_name(package).split("/")[-1]
    filtered = [name for name in bins if "prewarm" not in name and "lowmem" not in name and not name.endswith("-tools")]

    def rank(name: str) -> int:
        if name == agent_id:
            return 0
        if name == package_leaf:
            return 1
        if name.startswith(agent_id):
            return 2
        return 3

    return sorted(filtered, key=lambda name: (rank(name), name))[:2]


def binaries_and_args(agent_id: str, distribution: dict) -> tuple[list[str], list[str], "str | None"]:
    if "binary" in distribution:
        for platform in ("darwin-aarch64", "darwin-x86_64"):
            target = distribution["binary"].get(platform)
            if target:
                return [os.path.basename(target["cmd"])], target.get("args", []), None
        return [], [], None
    if "npx" in distribution:
        spec = distribution["npx"]
        package = spec["package"]
        bins = rank_npm_bins(npm_bins(package), agent_id, package)
        return bins, spec.get("args", []), npm_package_name(package)
    if "uvx" in distribution:
        spec = distribution["uvx"]
        return [re.split(r"[=<>@\[]", spec["package"])[0]], spec.get("args", []), None
    return [], [], None


def swift_string(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)


def main() -> None:
    # CDN 对默认的 Python-urllib UA 返回 403；伪装成 curl 才放行。
    request = urllib.request.Request(REGISTRY_URL, headers={"User-Agent": "curl/8.7.1"})
    with urllib.request.urlopen(request, timeout=30) as response:
        registry = json.load(response)
    lines = []
    for agent in sorted(registry["agents"], key=lambda a: a["id"]):
        agent_id = agent["id"]
        if agent_id in RESERVED or not ID_PATTERN.match(agent_id):
            print(f"- 跳过 {agent_id}", file=sys.stderr)
            continue
        binaries, args, npm_package = binaries_and_args(agent_id, agent["distribution"])
        if not binaries:
            print(f"- 跳过 {agent_id}：认不出本机可执行文件名", file=sys.stderr)
            continue
        enabled = "false" if agent_id in DEFAULT_OFF else "true"
        npm_package_field = f", npmPackage: {swift_string(npm_package)}" if npm_package else ""
        # 官网只给设置窗口的「下载」按钮用；不是 https 的不收（不在 app 里打开明文链接）。
        website = agent.get("website") or agent.get("repository") or ""
        website_field = f", website: {swift_string(website)}" if website.startswith("https://") else ""
        lines.append(
            f"        AcpRegistryEntry(id: {swift_string(agent_id)}, name: {swift_string(agent['name'])}, "
            f"binaries: [{', '.join(map(swift_string, binaries))}], args: [{', '.join(map(swift_string, args))}], "
            f"defaultEnabled: {enabled}{npm_package_field}{website_field}),")
        suffix = f" npmPackage={npm_package}" if npm_package else ""
        print(f"+ {agent_id}: {binaries} {args}{suffix}", file=sys.stderr)
    body = "\n".join(lines)
    swift = f"""// 由 scripts/acp-registry-snapshot.py 生成，不要手改。
// 来源：{REGISTRY_URL}（registry version {registry.get('version', '?')}）
import Foundation

public enum AcpRegistrySnapshot {{
    public static let entries: [AcpRegistryEntry] = [
{body}
    ]
}}
"""
    with open(OUTPUT, "w", encoding="utf-8") as handle:
        handle.write(swift)
    print(f"写入 {os.path.normpath(OUTPUT)}，{len(lines)} 条", file=sys.stderr)


if __name__ == "__main__":
    main()
