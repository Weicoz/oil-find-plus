from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE = "OilFind" + "Pro"


class OpenCoreTests(unittest.TestCase):
    def test_pro_extension_ships_with_this_repository(self):
        # Pro 已随本仓库开源发布：目录必须被 Git 跟踪，且不得被 .gitignore 忽略。
        files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
        self.assertTrue([name for name in files if name.startswith("Pro/")],
                        "Pro/ 应随本仓库跟踪；若改为独立私有仓库，需同时更新本用例与文档")
        ignored = subprocess.run(["git", "check-ignore", "Pro/Sources/placeholder.swift"], cwd=ROOT,
                                 capture_output=True, text=True)
        self.assertNotEqual(ignored.returncode, 0, f"Pro/ 不得被忽略：{ignored.stdout}{ignored.stderr}")

    def test_public_module_boundary(self):
        allowed = {"Package.swift", "Sources/OilFind/main.swift"}
        # Include new source files before they have been staged. Never inspect secrets or build products.
        paths = [ROOT / "Package.swift"]
        for directory in ("Sources", "Tests", "scripts", ".github", "Resources"):
            paths.extend(path for path in (ROOT / directory).rglob("*")
                         if path.is_file() and not path.name.startswith(".env"))
        offenders = []
        for path in paths:
            if path.relative_to(ROOT).as_posix() in allowed:
                continue
            try:
                if MODULE in path.read_text():
                    offenders.append(path.relative_to(ROOT).as_posix())
            except UnicodeDecodeError:
                continue
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
