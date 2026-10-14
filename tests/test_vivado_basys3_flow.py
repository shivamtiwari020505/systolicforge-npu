"""Test Tcl completion gates with stubs, not with real FPGA implementation."""

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
class Basys3FlowTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "build").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "build")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        files = ["fpga/vivado/build_basys3.tcl", "fpga/basys3/basys3.xdc",
                 "rtl/systolic_pe.sv", "rtl/systolic_array.sv",
                 "rtl/systolicforge_matmul_validator.sv"]
        files += ["fpga/common/" + name for name in (
            "systolicforge_fpga_engine.sv", "systolicforge_uart_rx.sv",
            "systolicforge_uart_tx.sv", "systolicforge_fpga_uart_demo.sv")]
        for name in files:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.tcl = tkinter.Tcl()
        self.tcl.eval("""
            set setup_slack 0.5
            set hold_slack 0.1
            set routing_errors 0
            set drc_errors {}
            set bitstream_calls 0
            rename puts original_puts
            proc puts {args} {
                if {[llength $args] == 2} { original_puts {*}$args }
            }
            proc version {args} { return TEST_STUB }
            proc get_timing_paths {args} {
                if {[lsearch $args min] >= 0} { return hold_path }
                return setup_path
            }
            proc get_property {property object} {
                if {$object eq "hold_path"} { return $::hold_slack }
                return $::setup_slack
            }
            proc get_drc_violations {args} { return $::drc_errors }
            proc report_route_status {args} {
                set file [open [lindex $args end] w]
                puts $file "# of nets with routing errors.... : $::routing_errors"
                close $file
            }
            proc write_bitstream {args} { incr ::bitstream_calls }
        """)
        for command in ("read_verilog", "read_xdc", "synth_design", "opt_design",
                        "place_design", "phys_opt_design", "route_design",
                        "write_checkpoint", "write_verilog", "write_sdf",
                        "report_utilization", "report_timing_summary", "report_clock_utilization",
                        "report_io", "report_power", "report_methodology", "report_drc"):
            self.tcl.eval(f"proc {command} {{args}} {{}}")

    def run_flow(self):
        self.tcl.call("source", str(self.root / "fpga/vivado/build_basys3.tcl"))

    def check_failure(self, variable, value, message):
        self.tcl.setvar(variable, value)
        with self.assertRaisesRegex(tkinter.TclError, message):
            self.run_flow()
        self.assertEqual(int(self.tcl.getvar("bitstream_calls")), 0)
        manifest = (self.root / "build/vivado_basys3/build_manifest.txt").read_text()
        self.assertNotIn("bitstream_generated=true", manifest)

    def test_setup_failure_blocks_bitstream(self):
        self.check_failure("setup_slack", -0.1, "fails the 10.000 ns setup")

    def test_hold_failure_blocks_bitstream(self):
        self.check_failure("hold_slack", -0.1, "fails hold")

    def test_routing_errors_block_bitstream(self):
        self.check_failure("routing_errors", 1, "Routing errors remain")

    def test_drc_errors_block_bitstream(self):
        self.check_failure("drc_errors", "error_one", "DRC errors remain")

    def test_success_records_completion_after_bitstream(self):
        self.run_flow()
        self.assertEqual(int(self.tcl.getvar("bitstream_calls")), 1)
        manifest = (self.root / "build/vivado_basys3/build_manifest.txt").read_text()
        self.assertIn("route_whs_ns=0.1", manifest)
        self.assertIn("bitstream_generated=true", manifest)
        self.assertIn("completed_utc=", manifest)
