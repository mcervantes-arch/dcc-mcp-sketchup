# Real SketchUp test plan

Later manual run only. SketchUp 2026 for Windows, on a machine the owner has approved. This cloud run does not connect to that machine.

Use a new throwaway model. Do not open a client file, and do not save over any existing `.skp`.

## Setup

1. Install this branch's extension and sidecar with `dcc-mcp-core` exactly `0.20.36`. Any other core version must refuse to start, and the doctor must not suggest `pip install --upgrade`.
2. Create an empty folder, for example `C:\RenCo\synthetic-safety\`. Set `DCC_MCP_SKETCHUP_PROJECT_FOLDER` to that folder.
3. In SketchUp 2026, start a new empty model. Draw nothing from a client file.
4. Confirm the sidecar log shows telemetry off and that no webhook or OTLP endpoint is set. A request for `ui-control`, `media`, or `execute_python` must be refused.

## Save

5. Open a throwaway model named `JOB1_Synthetic_Model_v01.skp`. Save the next copy as `JOB1_Synthetic_Model_v02.skp` inside the project folder. The base name must match and the version must be higher. It must be a new file.
6. Call `save_copy` again on that same path. It must refuse because the file exists, and the file bytes must be unchanged.
7. Call `save_copy` with `overwrite: true`. It must refuse. There is no overwrite switch.
8. Call `save_copy` with the path of the model that is already open. It must refuse, and the open model path must stay the same.
9. Call `save_copy` as `model.skp` (no version in the name), as `JOB9_Other_Model_v02.skp` (different base name), and as a path outside the project folder. All three must refuse.
10. Confirm there is no `model.save` command.

## Units, transform, materials

11. Add a box with width 10, depth 5, height 8 and no unit argument. The read-back extents must be 10 x 5 x 8 inches, not a meter conversion.
12. Move that box by 12 inches on X. The bounds center must move by 12 inches. One undo must undo the whole move.
13. Send `scale` on the same transform. It must be rejected and the box must stay the same size.
14. Confirm the materials skill is not offered and a materials command is rejected.

## Spec check (read-only)

Build two groups and write down their persistent IDs.

15. Wall: 120 x 6 x 96 inches. Place it 1/16 inch off the spec X. `validate_spec` type `wall` must return MATCH, with specified, available, and delta. Delta X is 0.0625 inch. The model is not edited.
16. Move that wall so it is exactly 1/8 inch off. MATCH.
17. Move it to 3/16 inch off. BLOCK. The box size must be unchanged. Do not resize it to force a match.
18. Appliance: 36 x 28 x 70 inches, 1/32 inch off the spec. Type `appliance` must return BLOCK. Tolerance is 0.
19. Set the wall's `renco` / `type` attribute to `appliance` and put the geometry back on the spec. Status must be MISMATCH, not a silent relabel.
20. Omit `width` from an element. The command must raise and must not guess a width.
21. Use an id that is not in the model. BLOCK, available null, and the entity count unchanged.

## Organization

22. Run category folders. The Outliner tag folders must include Roof, Slab, Foundation, Walls – Exterior, Walls – Bedroom, Walls – Bathroom, Walls – Kitchen, Doors, Windows, Cabinetry, Appliances, Stairs, Site, and Reference. The en dash is part of the name.
23. Record the wall's min and max before and after. They must match. One undo restores the folders.
24. Put the wall in Kitchen only. It becomes a group named Kitchen. Bounds unchanged.
25. Put one group in both Kitchen and Living. It stays one object, is listed under both rooms, and is not split or copied. Bounds unchanged.
26. Read the Outliner. It must show the nested group, a component instance if you place one synthetic component, persistent id, entity id, and the attribute dictionary.

## Paths

27. Import a small synthetic `.dae` from inside the project folder. It must not delete existing geometry.
28. Import and export a path outside the folder, including a shortcut whose target is outside the folder. Both must refuse.
29. Unset `DCC_MCP_SKETCHUP_PROJECT_FOLDER` and retry the save. It must fail closed.

## Stop

30. If a save target already exists, a path is outside the folder, or the host is not the approved machine, stop. Do not work around it.
31. Edge-to-edge contact is a visual check on this throwaway model only: faces that should meet should meet, with no gap and no overlap. This adapter does not measure that. Record any gap as CANNOT VERIFY or BLOCK for the owner. Do not quietly move geometry to close it.

Write the results next to this plan: each step PASS, FAIL, or CANNOT VERIFY, plus the `.skp` version path. Phineas reviews. Only Michelle merges.
