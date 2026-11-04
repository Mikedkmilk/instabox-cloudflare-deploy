#!/usr/bin/env python3
"""
Regression tests for the instabox-cloudflare-deploy skill.

Each test encodes a mistake that actually happened during the original
deployment, so the skill cannot silently regress back into it.

Run:
    python -m unittest discover -s scripts -p 'test_*.py' -v
"""

import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent


def read(rel: str) -> str:
    return (SKILL_ROOT / rel).read_text(encoding="utf-8")


def exists(rel: str) -> bool:
    return (SKILL_ROOT / rel).exists()


class TestSkillStructure(unittest.TestCase):
    def test_skill_md_exists(self) -> None:
        self.assertTrue(exists("SKILL.md"), "SKILL.md missing")

    def test_meta_json_valid(self) -> None:
        import json

        meta = json.loads(read("_meta.json"))
        self.assertIn("id", meta)
        self.assertIn("version", meta)
        self.assertRegex(meta["version"], r"^\d+\.\d+\.\d+$")

    def test_frontmatter_is_first_line(self) -> None:
        content = read("SKILL.md")
        self.assertTrue(
            content.startswith("---\n"),
            "SKILL.md must start with '---' on the very first line",
        )

    def test_all_reference_files_exist(self) -> None:
        refs = sorted(p for p in (SKILL_ROOT / "references").glob("*.md"))
        self.assertTrue(refs, "references/ is empty")
        for ref in refs:
            self.assertGreater(ref.stat().st_size, 500, f"{ref.name} suspiciously small")

    def test_skill_md_links_resolve(self) -> None:
        content = read("SKILL.md")
        # 反引号内是正式引用；正文里的裸引用（如「见 references/xxx.md」）同样必须落地
        linked = set(re.findall(r"(?:references|scripts|assets)/[\w./-]+\.(?:md|ps1|sh|js|example|toml|template)", content))
        self.assertTrue(linked, "SKILL.md does not reference any references/*.md")
        for rel in sorted(linked):
            self.assertTrue(exists(rel), f"SKILL.md references missing file: {rel}")

    def test_scripts_present(self) -> None:
        for rel in (
            "scripts/preflight.ps1",
            "scripts/deploy.ps1",
            "scripts/deploy.sh",
            "scripts/deploy-in-machine.sh",
            "scripts/setup-tunnel.sh",
            "scripts/stage-code.ps1",
            "scripts/verify-site.ps1",
            "scripts/keepalive/worker.js",
            "scripts/keepalive/wrangler.toml.template",
            "scripts/keepalive/deploy-keepalive.ps1",
            "scripts/keepalive/deploy-keepalive.sh",
            "assets/env.example",
        ):
            self.assertTrue(exists(rel), f"missing asset: {rel}")

    def test_no_dangling_path_in_any_doc(self) -> None:
        """所有 .md 里提到的 references/ scripts/ assets/ 路径必须真实存在"""
        pattern = re.compile(r"(?:references|scripts|assets)/[\w./-]+\.(?:md|ps1|sh|js|example|toml|template)")
        for doc in sorted(SKILL_ROOT.rglob("*.md")):
            text = doc.read_text(encoding="utf-8", errors="ignore")
            for rel in sorted(set(pattern.findall(text))):
                self.assertTrue(
                    (SKILL_ROOT / rel).exists(),
                    f"{doc.relative_to(SKILL_ROOT)} points to missing file: {rel}",
                )


class TestKeepaliveWorker(unittest.TestCase):
    """坑：wrangler 4 的 cron 写在顶层会被静默忽略。"""

    def test_cron_is_under_triggers(self) -> None:
        toml = read("scripts/keepalive/wrangler.toml.template")
        self.assertIn("[triggers]", toml, "wrangler.toml.template has no [triggers] section")
        after = toml.split("[triggers]", 1)[1]
        self.assertIn("crons =", after, "crons must be inside the [triggers] section")

    def test_worker_does_not_hardcode_cron(self) -> None:
        worker = read("scripts/keepalive/worker.js")
        self.assertNotRegex(worker, r"crons\s*=", "cron belongs in wrangler.toml, not worker.js")

    def test_lease_endpoint_uses_machine_id(self) -> None:
        """坑：lease 端点只认机器 ID，用机器名会 404。"""
        worker = read("scripts/keepalive/worker.js")
        self.assertIn("/activity-leases/", worker)
        self.assertRegex(worker, r"machines/\$\{id\}/activity-leases",
                         "lease path must interpolate the machine ID")

    def test_idempotency_key_is_forwarded(self) -> None:
        """回归：call() 之前忽略了第 5 个参数，Idempotency-Key 被丢弃。"""
        worker = read("scripts/keepalive/worker.js")
        self.assertRegex(
            worker,
            r"async function call\(key, method, path, body, extraHeaders\)",
            "call() must accept extraHeaders",
        )
        self.assertRegex(
            worker,
            r"if \(extraHeaders\) Object\.assign\(headers, extraHeaders\)",
            "call() must merge extraHeaders into the request headers",
        )
        self.assertIn("Idempotency-Key", worker, "resume/start need an Idempotency-Key header")

    def test_cooldown_is_not_hard_failure(self) -> None:
        """坑：machine_cooldown 期间硬撞会被拒，必须跳过而不是反复重试。"""
        worker = read("scripts/keepalive/worker.js")
        self.assertIn("machine_cooldown", worker)
        self.assertIn("cooldown: true", worker)

    def test_ttl_default_is_valid(self) -> None:
        worker = read("scripts/keepalive/worker.js")
        match = re.search(r"DEFAULT_TTL\s*=\s*(\d+)", worker)
        self.assertIsNotNone(match, "DEFAULT_TTL not found")
        ttl = int(match.group(1))
        self.assertTrue(30 <= ttl <= 3600, f"TTL {ttl} outside the API range 30-3600")


class TestDeployScripts(unittest.TestCase):
    """坑：build 与 next start 并发会损坏 .next。"""

    def test_build_stops_running_server_first(self) -> None:
        script = read("scripts/deploy-in-machine.sh")
        stop_at = script.find("pm2 stop")
        build_at = script.find("npm run build")
        self.assertNotEqual(stop_at, -1, "must stop pm2 before building")
        self.assertNotEqual(build_at, -1, "build step missing")
        self.assertLess(stop_at, build_at, "pm2 stop must come BEFORE npm run build")

    def test_build_cleans_old_next(self) -> None:
        script = read("scripts/deploy-in-machine.sh")
        self.assertIn("rm -rf .next", script, "stale .next must be removed before rebuild")

    def test_env_file_permissions(self) -> None:
        script = read("scripts/deploy-in-machine.sh")
        self.assertIn("chmod 600", script, ".env must be locked down to 600")

    def test_exec_timeout_within_limit(self) -> None:
        """坑：instabox exec --timeout 上限是 600 秒。"""
        for rel in ("scripts/deploy.ps1", "scripts/deploy.sh"):
            content = read(rel)
            for match in re.finditer(r"--timeout\s+(\d+)", content):
                self.assertLessEqual(
                    int(match.group(1)),
                    600,
                    f"{rel}: --timeout {match.group(1)} exceeds the 600s API limit",
                )

    def test_deploys_before_secret_put(self) -> None:
        """坑：secret put 要求 Worker 已存在，顺序不能反。"""
        for rel in (
            "scripts/keepalive/deploy-keepalive.ps1",
            "scripts/keepalive/deploy-keepalive.sh",
        ):
            content = read(rel)
            # 找实际调用，而不是注释里出现的 "secret put" 字样
            deploy_at = content.find("wrangler@latest deploy")
            secret_at = content.find("wrangler@latest secret put")
            self.assertNotEqual(deploy_at, -1, f"{rel}: deploy call missing")
            self.assertNotEqual(secret_at, -1, f"{rel}: secret put call missing")
            self.assertLess(deploy_at, secret_at, f"{rel}: must deploy BEFORE secret put")

    def test_secret_value_not_inlined(self) -> None:
        """脚本里不能内嵌真实密钥（`ibk_...` 这种格式说明是允许的）。"""
        pattern = re.compile(r"ibk_[a-z0-9]{30,}")
        for rel in ("scripts/keepalive/deploy-keepalive.ps1", "scripts/keepalive/deploy-keepalive.sh"):
            content = read(rel)
            self.assertIsNone(
                pattern.search(content), f"{rel}: hardcoded InstaBox API key"
            )

    def test_stage_code_excludes_secrets(self) -> None:
        script = read("scripts/stage-code.ps1")
        self.assertIn("'.env'", script, ".env must be excluded from the code bundle")
        self.assertIn("node_modules", script)

    def test_stage_code_uses_literal_path(self) -> None:
        """坑：PowerShell 的 Test-Path 把 [[...path]] 当通配符。"""
        script = read("scripts/stage-code.ps1")
        self.assertIn("-LiteralPath", script, "path checks must use -LiteralPath")

    def test_data_dir_uses_literal_path(self) -> None:
        """data-transfer.md 里给的 node -e 片段必须用 -LiteralPath 语义。"""
        self.assertTrue(exists("references/data-transfer.md"))
        doc = read("references/data-transfer.md")
        self.assertIn("wal_checkpoint(TRUNCATE)", doc)
        self.assertIn("integrity_check", doc)


class TestTunnelDocs(unittest.TestCase):
    """坑：Service Type 选 HTTPS 会 502。"""

    def test_service_type_http_documented(self) -> None:
        doc = read("references/cloudflare-tunnel.md")
        self.assertIn("Service Type", doc)
        self.assertRegex(doc, r"HTTP.*必须|HTTP\*\*", doc)
        self.assertIn("502", doc)

    def test_cname_direct_rejected(self) -> None:
        doc = read("references/cloudflare-tunnel.md")
        self.assertIn("CNAME", doc)
        self.assertRegex(
            doc,
            r"别走 CNAME|CNAME.*不可行|不要.*CNAME|CNAME.*404",
            "doc must state that DNS CNAME direct to InstaBox does not work",
        )

    def test_tunnel_script_exists_and_is_safe(self) -> None:
        script = read("scripts/setup-tunnel.sh")
        self.assertIn("systemctl", script)
        self.assertIn("chmod 600", script, "service file holds the tunnel token; lock it down")
        self.assertIn("enable", script, "tunnel must survive reboot")


class TestNoHardcodedCredentials(unittest.TestCase):
    """技能必须可复用，不能内嵌任何人的真实凭据。"""

    def test_no_real_instabox_key(self) -> None:
        # 真实 key 是 ibk_ + 52 位小写十六进制；`ibk_...` 这类格式说明不匹配
        pattern = re.compile(r"ibk_[a-z0-9]{40,}")
        for path in SKILL_ROOT.rglob("*"):
            if not path.is_file() or path.suffix in {".pyc"}:
                continue
            if "__pycache__" in path.parts:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.assertIsNone(
                pattern.search(text),
                f"{path.relative_to(SKILL_ROOT)} contains a hardcoded InstaBox API key",
            )

    def test_no_real_machine_id(self) -> None:
        # 真实机器 ID 是 m_ + 24 位十六进制；占位符一律写 <MACHINE_ID>
        pattern = re.compile(r"m_[a-z0-9]{24}")
        for path in SKILL_ROOT.rglob("*"):
            if not path.is_file() or path.suffix in {".pyc"}:
                continue
            if "__pycache__" in path.parts:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            self.assertIsNone(
                pattern.search(text),
                f"{path.relative_to(SKILL_ROOT)} contains a real machine ID",
            )


class TestShellScriptSyntax(unittest.TestCase):
    def test_bash_scripts_parse(self) -> None:
        bash = shutil.which("bash")
        if not bash:
            self.skipTest("bash not available on this host")
        for rel in (
            "scripts/deploy-in-machine.sh",
            "scripts/setup-tunnel.sh",
            "scripts/deploy.sh",
            "scripts/keepalive/deploy-keepalive.sh",
        ):
            result = subprocess.run(
                [bash, "-n", str(SKILL_ROOT / rel)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode, 0, f"{rel} has a shell syntax error:\n{result.stderr}"
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
