# Stage D's D2: the sensor probes for the fan regulator (2026-10-17)

**The question** (the coordinator's, for D2, the PL's fan regulator in [`soc.md`](../../../../docs/spec/soc.md) §8.2): can the PL SYSMON be read without disturbing the A53's own fan and temperature readings?
- **Tools:** the SoC track's package `d2-probes-20261017` ([`package_README.txt`](package_README.txt)): `tanager-host` `4f82c552…`, which is D1's plus `psrd` on the AMS block.
- **How it ran:** [`../runs/d2_probe.sh`](../runs/d2_probe.sh), alongside stress run s4 on sc3 (loaded about 15 min before), the same way the monitor's register reads run. Read-only; no PS writes.
- **Raw output:** [`d2_probe_sc3.txt`](d2_probe_sc3.txt). The SoC track decodes it.

**What it shows (a first reading):**
- **fancontrol** regulates on the AMS hwmon's `temp1`, which is the PS (LPD) SYSMON. Its raw `0x9DBC` is 33.6 °C, and hwmon read 33.56. The curve runs from 35 to 45 °C, pwm 15 to 255.
- **The PL SYSMON's temperature** reads through the AMS: `0x9D3E`, 32.6 °C, which is hwmon's `temp3`.
- **The PL SYSMON's configuration and sequence registers all read 0.** The PS SYSMON's hold the AMS driver's settings (41h = `0x2F0F`). This fits sc3's load having reset the PL SYSMON's configuration; step 3, a reload compared before and after, will confirm it once the stress run stops.
- **No disturbance:** hwmon's temperatures before and after the reads agree, and `fancontrol` stayed active at pwm 15/255.
