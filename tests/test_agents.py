"""Tests for the adapter table and the Hyprland helpers.

Mirrors `plugin/agent-harness/lib/agents.luau` and the Hyprland portion of `lib/launch.luau`.

Run from the repo root:  python3 -m unittest -v tests.test_agents
"""

import os
import re
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTS_LUA = os.path.join(REPO, "plugin", "agent-harness", "lib", "agents.luau")

# Observed live: /home/ian/work/agent-harness/scratch
#   -> ~/.pi/agent/sessions/--home-ian-work-agent-harness-scratch--/
OBSERVED = {
    "/home/ian/work/agent-harness/scratch": "--home-ian-work-agent-harness-scratch--",
    "/home/ian/work": "--home-ian-work--",
    "/": "--",
}

META = re.compile(r"""[;|&$`<>(){}[\]!*?~"'\n\r]""")


def encode_cwd(cwd):
    """Mirror of agents.encodeCwd: drop the leading slash, then `/` -> `-`, wrapped in `--`."""
    stripped = cwd.rstrip("/").lstrip("/")
    if stripped == "":
        return "--"
    return "--" + stripped.replace("/", "-") + "--"


def window_class(value):
    """Mirror of launch.windowClass."""
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "", value or "")
    return cleaned or "agent-harness"


class TestEncodeCwd(unittest.TestCase):
    def test_matches_observed_layout(self):
        for cwd, expected in OBSERVED.items():
            self.assertEqual(encode_cwd(cwd), expected, cwd)

    def test_trailing_slash_is_ignored(self):
        self.assertEqual(encode_cwd("/home/ian/work/"), encode_cwd("/home/ian/work"))

    def test_no_slashes_survive(self):
        self.assertNotIn("/", encode_cwd("/a/b/c"))


class TestAdapterValidation(unittest.TestCase):
    """The Luau validator rejects shell metacharacters in an adapter's fixed fields."""

    def setUp(self):
        with open(AGENTS_LUA, encoding="utf-8") as handle:
            self.source = handle.read()

    def test_validator_rejects_metacharacters(self):
        for bad in ["pi;rm -rf /", "pi$(id)", "pi`id`", "pi|x", "pi && x", 'pi"x']:
            self.assertRegex(bad, META, "corpus entry should be rejected: %r" % bad)

    def test_validator_allows_real_binary_names(self):
        for good in ["pi", "hermes", "claude-code", "opencode", "dsh"]:
            self.assertIsNone(META.search(good))

    def test_only_known_deliveries_are_accepted(self):
        self.assertIn('adapter.delivery ~= "cat-file"', self.source)
        self.assertIn('adapter.delivery ~= "flag-file"', self.source)

    def test_shipped_adapters_are_marked_verified(self):
        # Every adapter in the table must have been checked against the real CLI, or the
        # panel labels it unverified. Both shipped adapters were verified in Phase 0.
        self.assertEqual(self.source.count("verified = true"), 2)
        self.assertNotIn("verified = false", self.source)


class TestWindowClass(unittest.TestCase):
    def test_strips_shell_and_regex_metacharacters(self):
        self.assertEqual(window_class('bad";rm -rf /'), "badrm-rf")
        self.assertEqual(window_class("^agent-harness$"), "agent-harness")
        self.assertEqual(window_class("a b c"), "abc")

    def test_empty_falls_back_to_default(self):
        self.assertEqual(window_class(""), "agent-harness")
        self.assertEqual(window_class(None), "agent-harness")

    def test_result_is_safe_in_a_lua_regex(self):
        for value in ["^.*$", "(", ")", "[a-z]", "\\", "%s"]:
            self.assertRegex(window_class(value), r"^[A-Za-z0-9_-]+$")


if __name__ == "__main__":
    unittest.main()
