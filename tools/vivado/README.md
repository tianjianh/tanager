# Minimal Vivado 2025.2 install (command line, Kria devices only)

**What gets installed:** Vivado ML Standard (no-cost edition) with only "Install Devices for Kria SOMs and Starter Kits", which provides the XCK26 part and the KV260 board files. It skips DocNav, Model Composer, shortcuts and every other device family. The configuration is [install_config_kria.txt](install_config_kria.txt), and it installs to `~/Xilinx`.

**Who does what:**
- You do two steps that need you: signing in with your AMD account and accepting the AMD EULAs.
- Everything else is scripted.

## Steps (in WSL Ubuntu-24.04 on the build host)

1. Get the web installer, `FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157_Lin64.bin` (about 350 MB). It is downloaded from amd.com with your AMD account, or copied from another host. Extract it:
   ```bash
   chmod +x FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157_Lin64.bin
   ./FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157_Lin64.bin --keep --noexec --target ~/xinstall-tmp
   cp tools/vivado/install_config_kria.txt ~/.Xilinx/install_config.txt   # Destination assumes user w
   ```
2. System libraries: `sudo bash tools/setup_root.sh`. This also installs GCC 15 and the RTL tool dependencies.
3. **(you)** Sign in once. This prompts for your AMD account e-mail and password; the token lasts 7 days.
   ```bash
   cd ~/xinstall-tmp && ./xsetup -b AuthTokenGen
   ```
4. **(you)** Install. The `-a` flag accepts the AMD EULAs. This downloads and installs about 20–30 GB and takes roughly 20–40 minutes, so run it in the background with a log:
   ```bash
   cd ~/xinstall-tmp; nohup ./xsetup -a XilinxEULA,3rdPartyEULA -b Install \
       -c ~/.Xilinx/install_config.txt > ~/vivado_install.log 2>&1 < /dev/null &
   ```
   Use `;` after `cd`, not `&&`. With `&&`, the whole `cd ... && nohup ...` list runs as a background subshell that keeps the terminal's (or SSH session's) output open. An `ssh host '...'` call then does not return until the install ends. The install itself is unaffected, and Ctrl+C on such an ssh call is safe: no terminal is attached and nohup ignores hang-ups.
5. Check and clean up:
   ```bash
   tail -3 ~/vivado_install.log
   rm -rf ~/xinstall-tmp ~/xinstall-dl ~/.Xilinx/xinstall/*.trace
   ```
   Then run the smoke test: `tools/vivado_run.sh` with any OOC script, or `tools/tcl/elab.tcl` (conventions §9). It must list `xck26-sfvc784-2LV-c`.

**If `xck26` is missing after the install,** the Kria option did not bring the part with it. Re-run step 4 with `Zynq UltraScale+ MPSoCs:1` added to `Modules` in `~/.Xilinx/install_config.txt`.
