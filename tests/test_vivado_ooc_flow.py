"""Exercise profile selection and failure provenance using stubbed Vivado commands.

These tests execute Tcl control flow; they do not perform FPGA synthesis.
"""

import shutil
import tempfile
import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:
    tkinter = None

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(tkinter is None, "Tcl interpreter requires python3-tk")
class OOCFlowTests(unittest.TestCase):
    def setUp(self):
        # Keep Python and native Tcl in the same workspace filesystem view.
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="ooc-flow-test-", dir=build)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for relative in [
            "fpga/vivado/synth_npu_ooc.tcl", "fpga/vivado/npu_ooc.xdc",
            "rtl/systolic_pe.sv", "rtl/systolic_array.sv",
            "rtl/systolicforge_sdp_ram.sv", "rtl/systolicforge_npu.sv", "rtl/scratchpad_dma.sv",
            "rtl/systolicforge_soc.sv",
        ]:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        self.tcl = tkinter.Tcl()
        self.tcl.eval("""
            set synth_calls 0
            set tool_params {}
            rename puts original_puts
            proc puts {args} {
                if {[llength $args] == 2} { original_puts {*}$args }
            }
        """)
        self.tcl.eval("""
            proc version {args} { return TEST_STUB }
            proc set_param {args} { lappend ::tool_params $args }
            proc get_cells {args} { return {ram_a ram_b ram_c ram_imem} }
            proc synth_design {args} {
                incr ::synth_calls
                set ::synth_args $args
            }
        """)
        for command in ("read_verilog", "read_xdc", "write_checkpoint",
                        "write_verilog", "write_xdc", "report_utilization",
                        "report_timing_summary", "report_methodology", "report_drc"):
            self.tcl.eval(f"proc {command} {{args}} {{}}")

    def run_flow(self, *args):
        self.tcl.setvar("argv", args)
        self.tcl.call("source", str(self.root / "fpga/vivado/synth_npu_ooc.tcl"))

    def manifest(self, profile):
        return (self.root / f"build/vivado_npu_ooc_{profile}/build_manifest.txt").read_text()

    def test_no_profile_rejected_before_synthesis(self):
        with self.assertRaisesRegex(tkinter.TclError, "Select an OOC profile"):
            self.run_flow()
        self.assertEqual(int(self.tcl.getvar("synth_calls")), 0)
        self.assertFalse((self.root / "build").exists())

    def test_invalid_profile_rejected_before_synthesis(self):
        with self.assertRaisesRegex(tkinter.TclError, "Unknown OOC profile"):
            self.run_flow("typo")
        self.assertEqual(int(self.tcl.getvar("synth_calls")), 0)

    def test_compact_overrides_and_manifest(self):
        self.run_flow("compact")
        args = self.tcl.splitlist(self.tcl.getvar("synth_args"))
        self.assertIn("ADDR_W=7", args)
        self.assertIn("IMEM_DEPTH=16", args)
        self.assertEqual(self.tcl.splitlist(self.tcl.getvar("tool_params")), ())
        manifest = self.manifest("compact")
        for item in ("profile=compact", "scratchpad_words_per_memory=128",
                     "instruction_words=16", "completed_utc="):
            self.assertIn(item, manifest)

    def test_full_is_explicit_and_separate(self):
        self.run_flow("full")
        args = self.tcl.splitlist(self.tcl.getvar("synth_args"))
        self.assertIn("ADDR_W=12", args)
        self.assertIn("IMEM_DEPTH=256", args)
        params = self.tcl.splitlist(self.tcl.getvar("tool_params"))
        self.assertEqual(len(params), 0)
        self.assertIn("execution_engine=scheduled_synchronous_sdp", self.manifest("full"))
        self.assertIn("operand_prefetch=pipelined_active_lanes", self.manifest("full"))
        self.assertIn("activation_row_buffers=2", self.manifest("full"))
        self.assertIn("scratchpad_words_per_memory=4096", self.manifest("full"))
        self.assertFalse((self.root / "build/vivado_npu_ooc_compact").exists())

    def test_failed_synthesis_retains_config_without_completion(self):
        self.tcl.eval('proc synth_design {args} { error "injected failure" }')
        with self.assertRaisesRegex(tkinter.TclError, "injected failure"):
            self.run_flow("compact")
        manifest = self.manifest("compact")
        self.assertIn("profile=compact", manifest)
        self.assertNotIn("completed_utc=", manifest)

    def test_missing_block_ram_is_a_failed_run(self):
        self.tcl.eval('proc get_cells {args} { return {} }')
        with self.assertRaisesRegex(tkinter.TclError, "No block RAM inferred"):
            self.run_flow("full")
        self.assertNotIn("completed_utc=", self.manifest("full"))


if __name__ == "__main__":
    unittest.main()
