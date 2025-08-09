# uvm-axi-lite-smoke-and-coverage

A minimal yet complete **AXI-Lite UVM** verification environment featuring both a `smoke` functional test sequence and a `coverage`-driven sequence.  
Includes driver, monitor, scoreboard, and coverage collection with a standard UVM data flow.  
Suitable for learning, interview demos, and as a base for more complex protocol verification.

---

## ✨ Features
- Standard UVM components: `env / agent / driver / sequencer / monitor / scoreboard`
- Two sequences:
  - **`axi_smoke_seq`** – quick smoke test (basic write→readback)
  - **`axi_cov_seq`** – coverage-driven stimulus to hit all planned bins (cmd/addr/data + cross coverage)
- Coverage design (covergroup + bins + cross coverage) integrated with sequence stimulus
- Clear transaction data flow and informative log naming for easy debug
- Simple structure, easy to extend to larger protocols (AXI4, PCIe, etc.)

---

## 📂 Directory Structure
.
├── dut/ # Design Under Test (AXI-Lite example register block)
│ └── axi_lite_slave_regs.sv
├── tb/
│ ├── axi_if.sv # AXI-Lite interface (with virtual interface)
│ ├── axi_seq_item.sv # Transaction definition (addr/is_write/wdata/rdata/resp)
│ ├── axi_driver.sv
│ ├── axi_monitor.sv
│ ├── axi_agent.sv
│ ├── axi_env.sv
│ ├── axi_scoreboard.sv
│ ├── axi_coverage.sv # Covergroup (cmd/addr[7:0]/wdata[7:0] + cross)
│ ├── axi_smoke_seq.sv # Simple smoke test sequence
│ └── axi_cov_seq.sv # Coverage-driven sequence
├── sim/
│ ├── tb_top.sv # Top-level testbench (instantiate DUT + interface + run_test)
│ └── sim.do # (Optional) Simulation script template
├── uvm_pkg/ # (Optional) UVM library placeholder
└── README.md

- **Sequence** generates `axi_seq_item` transactions (write/read, address, data).
- **Driver** translates transactions into AXI-Lite handshake signals to drive the DUT.
- **Monitor** samples bus activity, reconstructs transactions, and sends them to:
  - `scoreboard` for write→readback checking
  - `coverage` for bin/cross hit tracking
- **Scoreboard** compares DUT outputs against expected results.

---
<img width="1249" height="634" alt="image" src="https://github.com/user-attachments/assets/9281a869-2352-4794-a1d8-5358f64598d7" />
<img width="1839" height="642" alt="image" src="https://github.com/user-attachments/assets/a737b871-8a3f-46a2-bc1c-d44a4625581e" />

## 🚀 How to Run
1. Ensure you have a SystemVerilog simulator with UVM 1.2 or later (e.g., Questa, Riviera, VCS).
2. Compile the DUT and testbench sources, including UVM library path.
3. Run `tb_top` with:
   ```tcl
   run_test("axi_smoke_test"); // for smoke testing
   run_test("axi_cov_test");   // for coverage-driven run
