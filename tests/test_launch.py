"""Tests for the launch-composition rules.

These mirror `plugin/agent_harness/lib/launch.luau`. The quoting test does not merely compare
strings: it round-trips each hostile input through a real POSIX shell, which is the property
that actually matters. If Luau tooling becomes available in CI these cases should run against
the Luau implementation directly.

Run from the repo root:  python3 -m unittest -v tests.test_launch
"""

import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAUNCH_LUA = os.path.join(REPO, "plugin", "agent_harness", "lib", "launch.luau")

# Inputs a user could plausibly type into a prompt box.
HOSTILE = [
    "plain",
    "two words",
    "it's quoted",
    'double "quotes"',
    "semi;colon",
    "pipe | char",
    "sub $(id -u)",
    "back `tick`",
    "dollar $HOME",
    "newline\ninside",
    "glob * ? [a-z]",
    "amp & and &&",
    "redirect > file",
    "tilde ~ and !bang",
    "back\\slash",
    "unicode \u2713 \u00e9",
    "rm -rf ~ # not today",
]


def shell_quote(value):
    """Mirror of launch.shellQuote."""
    return "'" + str(value).replace("'", "'\\''") + "'"


def shell_argv(argv):
    """Mirror of launch.shellArgv."""
    return " ".join(shell_quote(item) for item in argv)


def compose(delivery, argv, prompt_file):
    """Mirror of launch.compose: returns the command string tail."""
    argv = list(argv)
    if delivery == "cat-file":
        prompt_expr = '"$(cat ' + shell_quote(prompt_file) + ')"'
    else:
        argv.append("--query-file")
        prompt_expr = shell_quote(prompt_file)
    return shell_argv(argv) + " " + prompt_expr


def round_trip(value):
    """Send `value` through a real shell using our quoting; return what the shell saw."""
    cmd = "printf %s " + shell_quote(value)
    result = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, check=True)
    return result.stdout.decode()


class TestShellQuote(unittest.TestCase):
    def test_quotes_are_balanced(self):
        for value in HOSTILE:
            quoted = shell_quote(value)
            self.assertTrue(quoted.startswith("'") and quoted.endswith("'"))

    def test_round_trip_preserves_bytes(self):
        for value in HOSTILE:
            self.assertEqual(round_trip(value), value, "failed for %r" % value)

    def test_empty_string_round_trips(self):
        self.assertEqual(round_trip(""), "")

    def test_argv_round_trip(self):
        argv = ["pi", "--model", "a model with spaces", "it's", "$(id -u)"]
        cmd = "printf '%s\\n' " + shell_argv(argv)
        result = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, check=True)
        self.assertEqual(result.stdout.decode().splitlines(), argv)


class TestCompose(unittest.TestCase):
    def test_pi_uses_cat_file_and_no_prompt_text(self):
        prompt = "please run $(touch /tmp/pwned) and rm -rf ~"
        command = compose("cat-file", ["pi", "--model", "m"], "/data/prompts/abc.txt")
        self.assertNotIn(prompt, command)
        self.assertNotIn("touch", command)
        self.assertIn('"$(cat \'/data/prompts/abc.txt\')"', command)

    def test_hermes_uses_query_file_flag(self):
        command = compose("flag-file", ["hermes", "chat"], "/data/prompts/abc.txt")
        # Every argv element is quoted, so assert on the quoted forms.
        self.assertIn("'--query-file'", command)
        self.assertIn("'/data/prompts/abc.txt'", command)

    def test_prompt_file_path_is_quoted(self):
        weird = "/data/prompts/it's here.txt"
        command = compose("cat-file", ["pi"], weird)
        self.assertIn(shell_quote(weird), command)

    def test_cwd_with_spaces_is_quoted(self):
        cwd = tempfile.mkdtemp(prefix="agent harness ")
        self.addCleanup(shutil.rmtree, cwd, True)
        script_line = "cd " + shell_quote(cwd)
        self.assertEqual(
            subprocess.run(
                ["/bin/sh", "-c", script_line + " && printf %s \"$PWD\""],
                capture_output=True,
                check=True,
            ).stdout.decode(),
            cwd,
        )


class TestSourceInvariants(unittest.TestCase):
    """Guards that are cheap to check and expensive to get wrong."""

    def setUp(self):
        with open(LAUNCH_LUA, encoding="utf-8") as handle:
            self.source = handle.read()

    def test_launch_luau_never_references_raw_prompt(self):
        # The launch library may only know about the prompt *file*.
        self.assertNotIn("opts.prompt ", self.source)
        self.assertNotIn("opts.prompt)", self.source)
        self.assertIn("opts.promptFile", self.source)

    def test_launch_luau_uses_argv_runasync_not_shell_strings(self):
        self.assertIn("hyprctl", self.source)
        self.assertNotIn("/bin/sh -c", self.source)
        self.assertNotIn("os.execute", self.source)
        self.assertNotIn("io.popen", self.source)


if __name__ == "__main__":
    unittest.main()
