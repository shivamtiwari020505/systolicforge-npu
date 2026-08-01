# Sky130 physical design

The physical-design target is the default 8×8 compute core behind
`systolic_array_pd_top`.
Scratchpad SRAMs are not flattened into standard-cell registers for this pass;
a production mini-NPU floorplan should replace them with characterized SRAM
macros and integrate those LEFs/GDS/liberty views.

The raw array has hundreds of flattened weight and result signals. Treating all
of those as die-edge pins would distort floorplanning and can make pin placement
fail. The PD wrapper uses indexed weight/activation writes and a selected result
read, while leaving the PE array and its cycle timing unchanged. Reported area
therefore includes the small staging-register and access-mux overhead.

Two entry points are supplied:

- `pd/openlane/config.json` for OpenLane 2;
- `pd/openroad/config.mk` for OpenROAD-flow-scripts on `sky130hd`.

Both use a 20 ns target clock (50 MHz), 30–35% initial core utilization, and the
same SDC. The conservative density leaves routing room for the array's local
east/south interconnect.

## OpenLane 2

With the Sky130 PDK installed and selected:

```sh
openlane pd/openlane/config.json
python scripts/collect_openlane_metrics.py <run-directory> -o pd/metrics.md
```

Review synthesis warnings, setup/hold timing, congestion, antenna repair, DRC,
LVS, total standard-cell area, utilization, and power. Do not publish a
frequency based only on the target clock; publish the achieved post-route slack
and corner.

## OpenROAD-flow-scripts

```sh
make -C "$ORFS_ROOT/flow" \
  DESIGN_CONFIG="$PWD/pd/openroad/config.mk"
```

The exact results depend on tool commit, PDK revision, liberty corner, activity
assumptions, and routing settings. Preserve those versions with any reported
number.

## Portfolio evidence checklist

After a successful run, retain:

- synthesis cell count and mapped arithmetic cells;
- post-route die/core area and utilization;
- clock period, worst setup slack, total negative slack, and failing endpoints;
- total power with the activity assumption stated;
- congestion and DRC/LVS summaries;
- a floorplan/routed-layout screenshot;
- the exact OpenLane/OpenROAD and PDK revisions.

This repository does not contain invented PPA numbers. `pd/metrics.md` should be
generated from a real run and committed only together with its provenance.
