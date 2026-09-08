"""Wiring tests for the panel entry.

The panel composes its own launch (it holds the user's intent at the moment Enter is pressed),
so it must forward the prompt-file path that `launch.compose` requires. Forgetting that argument
surfaced to the user as "Missing prompt file" on both Enter and Alt+Enter.

Run from the repo root:  python3 -m unittest -v tests.test_panel
"""

import os
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANEL_LUA = os.path.join(REPO, "plugin", "agent-harness", "panel.luau")


class TestPanelLaunchWiring(unittest.TestCase):
    def setUp(self):
        with open(PANEL_LUA, encoding="utf-8") as handle:
            self.source = handle.read()

    def test_launch_options_takes_a_prompt_file(self):
        self.assertIn("local function launchOptions(oneShot, promptFile)", self.source)
        self.assertIn("promptFile = promptFile,", self.source)

    def test_both_call_sites_pass_the_prompt_file(self):
        # One definition plus exactly two call sites (interactive and one-shot).
        self.assertEqual(self.source.count("launchOptions("), 3)
        self.assertIn("launchOptions(false, promptFile)", self.source)
        self.assertIn("launchOptions(true, promptFile)", self.source)

    def test_prompt_is_written_before_the_script(self):
        for marker in ("launch.writePromptFile(ui_state.text)", "launch.writeLaunchScript("):
            self.assertIn(marker, self.source)
        write_prompt = self.source.index("launch.writePromptFile(ui_state.text)")
        first_script = self.source.index("launch.writeLaunchScript(")
        self.assertLess(write_prompt, first_script)

    def test_no_temporary_debug_ipc_hooks_shipped(self):
        self.assertNotIn('event == "submit"', self.source)
        self.assertNotIn('event == "one-shot"', self.source)


if __name__ == "__main__":
    unittest.main()
