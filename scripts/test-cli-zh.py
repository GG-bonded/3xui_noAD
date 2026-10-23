"""验证中文命令行文案和安装、更新脚本之间的兼容约定，不执行安装。"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unicodedata
import unittest

from tree_sitter import Language, Parser
import tree_sitter_bash


ROOT = Path(__file__).resolve().parents[1]
PARSER = Parser(Language(tree_sitter_bash.language()))
BASH = os.environ.get('BASH_BINARY', 'bash')
BINARY = None


def shell_function(filename, name):
    source = (ROOT / filename).read_text(encoding='utf-8').encode('utf-8')
    cursor = [PARSER.parse(source).root_node]
    while cursor:
        node = cursor.pop()
        if node.type == 'function_definition':
            function_name = node.child_by_field_name('name')
            if function_name.text.decode('utf-8') == name:
                if node.has_error:
                    raise AssertionError(f'{filename}: 无法安全提取函数 {name}')
                return node.text.decode('utf-8')
        cursor.extend(node.named_children)
    raise AssertionError(f'{filename}: 找不到函数 {name}')


def shell(source, input_text=''):
    # 使用字节输入，避免 Windows 将 LF 转成 CRLF，污染 Bash 的 read 结果。
    result = subprocess.run([BASH, '--noprofile', '--norc', '-c', source],
                            input=input_text.encode('utf-8'), capture_output=True, timeout=20)
    result.stdout = result.stdout.decode('utf-8')
    result.stderr = result.stderr.decode('utf-8')
    return result


class ChineseShellTests(unittest.TestCase):
    def assert_aligned_box(self, output):
        # 中文按双列计算宽度，防止只替换文字后边框错位。
        rows = [line for line in output.splitlines() if line.startswith(('│', '┌', '└', '╔', '╚'))]
        widths = {sum(2 if unicodedata.east_asian_width(char) in 'WF' else 1 for char in row)
                  for row in rows}
        self.assertEqual(len(widths), 1, f'菜单边框宽度不一致：{widths}')

    def test_main_menu_is_chinese_and_exit_does_not_run_actions(self):
        source = shell_function('x-ui.sh', 'show_menu')
        result = shell('show_status() { :; }; ' + source + '\nshow_menu', '0\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        for label in ['面板管理脚本', '退出脚本', '重置用户名和密码',
                      'SSL 证书管理', '防火墙管理', 'PostgreSQL 管理', '更新地理数据']:
            self.assertIn(label, result.stdout)
        self.assertNotIn('Install', result.stdout)
        self.assert_aligned_box(result.stdout)

    def test_usage_keeps_subcommands_but_translates_descriptions(self):
        result = shell(shell_function('x-ui.sh', 'show_usage') + '\nshow_usage')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('子命令', result.stdout)
        self.assertIn('x-ui restart-xray', result.stdout)
        self.assertIn('x-ui migrateDB [file]', result.stdout)
        self.assertIn('重启 Xray', result.stdout)
        self.assertNotIn('Admin Management Script', result.stdout)
        self.assert_aligned_box(result.stdout)

    def test_confirmation_retains_yes_no_and_default_behavior(self):
        source = shell_function('x-ui.sh', 'confirm')
        for answer, default, expected in [('y', '', 0), ('Y', '', 0), ('n', '', 1),
                                          ('', 'y', 0), ('', 'n', 1)]:
            with self.subTest(answer=answer, default=default):
                args = ' "y"' if default == 'y' else ' "n"' if default else ''
                result = shell(source + '\nconfirm "是否继续？"' + args, answer + '\n')
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_confirmation_prompt_displays_chinese_default(self):
        source = shell_function('x-ui.sh', 'confirm')
        # 仅拦截 read 以记录提示文本；实际输入行为由上一项测试覆盖。
        result = shell(source + '\nread() { printf "%s" "$2"; temp=y; }; '
                       'confirm "是否继续？" "y"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('默认 y', result.stdout)
        self.assertNotIn('Default', result.stdout)

    def test_noninteractive_install_preserves_defaults_and_env_overrides(self):
        source = shell_function('install.sh', 'prompt_or_default')
        result = shell(source + '\nNONINTERACTIVE=1; unset XUI_ACME_HTTP_PORT; '
                       'prompt_or_default port "监听端口：" "80" XUI_ACME_HTTP_PORT; '
                       'printf "%s\\n" "$port"; XUI_ACME_HTTP_PORT=18080; '
                       'prompt_or_default port "监听端口：" "80" XUI_ACME_HTTP_PORT; '
                       'printf "%s\\n" "$port"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['80', '18080'])

    def test_update_status_remains_machine_readable(self):
        source = shell_function('update.sh', '_write_update_status')
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / 'status.json'
            path = status_file.as_posix()
            for state, code in [('success', 0), ('failed', 2)]:
                result = shell(source + '\nxui_update_run_id=42; '
                               f'xui_update_status_file="{path}"; '
                               f'_write_update_status {state} {code}')
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(status_file.read_text(encoding='utf-8'))
                self.assertEqual(value['runId'], '42')
                self.assertEqual(value['state'], state)
                self.assertEqual(value['exitCode'], code)
                self.assertIsInstance(value['finishedAt'], int)

    def test_shell_syntax_without_running_installers(self):
        for filename in ['x-ui.sh', 'install.sh', 'update.sh', 'DockerInit.sh']:
            with self.subTest(filename=filename):
                result = subprocess.run([BASH, '-n', str(ROOT / filename)],
                                        capture_output=True, encoding='utf-8', timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)


@unittest.skipUnless(BINARY, '未指定 --binary，跳过编译后命令行检查')
class ChineseBinaryTests(unittest.TestCase):
    def command(self, *args):
        # 使用独立目录并清除数据库连接变量，禁止访问任何实际业务数据库。
        with tempfile.TemporaryDirectory() as directory:
            env = {key: value for key, value in os.environ.items() if not key.startswith('XUI_')}
            env.update(XUI_DB_FOLDER=directory, XUI_LOG_FOLDER=directory)
            return subprocess.run([str(BINARY), *args], cwd=directory, env=env,
                                  capture_output=True, encoding='utf-8', timeout=30)

    def test_help_is_chinese_and_flags_are_unchanged(self):
        for args, expected in [(('-h',), ['用法', '命令', '显示版本']),
                               (('setting', '-h'), ['用法', '-getApiToken', '设置登录用户名']),
                               (('migrate-db', '-h'), ['用法', '--restore', '目标 PostgreSQL'])]:
            with self.subTest(args=args):
                result = self.command(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                output = result.stdout + result.stderr
                for text in expected:
                    self.assertIn(text, output)
                self.assertNotIn('Usage of', output)

    def test_settings_and_certificates_keep_machine_field_names(self):
        for args, expected in [(('setting', '-show'), ['hasDefaultCredential: true', 'port:', 'webBasePath:']),
                               (('setting', '-getCert'), ['cert:', 'key:']),
                               (('setting', '-getListen'), ['listenIP:'])]:
            with self.subTest(args=args):
                result = self.command(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                for text in expected:
                    self.assertIn(text, result.stdout)

    def test_missing_restore_output_reports_chinese_without_writing_database(self):
        result = self.command('migrate-db', '--restore', 'missing.dump')
        self.assertIn('--out', result.stdout)
        self.assertIn('必须', result.stdout)
        self.assertNotIn('is required', result.stdout)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, help='待检查的 Linux 面板程序')
    args = parser.parse_args()
    BINARY = args.binary.resolve() if args.binary else None
    ChineseBinaryTests.__unittest_skip__ = BINARY is None
    unittest.main(argv=[__file__], verbosity=2)
