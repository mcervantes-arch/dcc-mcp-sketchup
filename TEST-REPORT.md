# Test report — safety baseline

Branch `renco/safety-baseline`. Base `main` at `b46b947`. Core pin under test: `dcc-mcp-core==0.20.36`. Adapter version `0.3.2`.

No client files were opened. Nothing was connected to an owner machine. No runtime network call or telemetry was added.

## Counts

| Phase | Suite | Passed | Failed | Notes |
|---|---|---:|---:|---|
| Phase 1, before | Python `pytest` on `main` | 156 | 0 | Same local harness as Phase 3. Worktree `/tmp/dcc-baseline`. |
| Phase 1, before | Ruby contract | — | — | Not executed. This environment has no Ruby interpreter. |
| Phase 3, after | Python `pytest` on this branch | 166 | 0 | Ten new safety tests, all passing. |
| Phase 3, after | Ruby contract | — | — | Not executed. 96 `def test_` methods exist under `tests/ruby/`. |

Phase 1 command, from `/tmp/dcc-baseline`:

```text
python3 -m pytest -q --tb=no
```

Final summary: `156 passed in 39.32s`

Phase 3 command, from the branch root:

```text
python3 -m pytest -q --tb=line
```

Final summary: `166 passed in 39.02s`

The Ruby command CI runs, and the one this environment could not run:

```text
ruby -e 'Dir["tests/ruby/test_*.rb"].sort.each { |file| require File.expand_path(file) }'
```

`ruby` is not installed. Downloads of the Ruby source tarball, a JRuby release asset, Debian packages, and PyPI all failed with TLS EOF or HTTP 403. The tests are in the branch for CI (Ruby 2.7 and 3.2).

The local pytest run used source checkouts on `PYTHONPATH`, a stand-in `validate_skill` (the published wheel could not be downloaded), and package metadata that reports core `0.20.36`. CI installs the real wheel.

## Rule status

PASS means a test ran in this environment and passed. CANNOT VERIFY means the proof is a Ruby contract test or a real SketchUp 2026 run, and that run did not happen here. Nothing in this table is FAIL.

| Rule | Status | Proof |
|---|---|---|
| `model.save` removed; `save_copy` is the only save script | PASS | `tests/test_safety.py::test_materials_skill_and_save_model_are_gone`, `tests/test_skills.py` (script set matches the Ruby command map) |
| `overwrite` is not a `save_copy` parameter | PASS | same safety test (schema). Runtime refusal: CANNOT VERIFY, `test_overwrite_is_refused` |
| Existing save or export target is refused | CANNOT VERIFY | `test_existing_save_target_is_refused`, `test_existing_export_target_is_refused` |
| `save_copy` refuses the source path and a non-versioned name | CANNOT VERIFY | `test_save_copy_refuses_the_source_path`, `test_unversioned_save_name_is_refused` |
| Versioned copy writes a new file and does not retarget the source | CANNOT VERIFY | `test_save_copy_writes_a_new_versioned_file` |
| Scale is not part of transform | PASS for the tool schema (`test_transform_has_no_scale_and_lengths_default_to_inches`). Command rejection CANNOT VERIFY | `test_scale_is_rejected` |
| Lengths default to inches in the tool schemas | PASS | same schema test. Command read-back CANNOT VERIFY: `test_omitted_unit_is_inches` |
| Wall ±1/8 inch: 1/16 MATCH, exact 1/8 MATCH, 3/16 BLOCK | CANNOT VERIFY | `test_wall_offset_of_one_sixteenth_matches`, `test_wall_offset_of_exactly_one_eighth_matches`, `test_wall_offset_of_three_sixteenths_blocks` |
| Appliance tolerance 0: 1/32 BLOCK | CANNOT VERIFY | `test_appliance_offset_of_one_thirty_second_blocks` |
| `validate_spec` is read-only and returns specified, available, and delta | CANNOT VERIFY | `test_missing_entity_blocks_without_editing`, `test_read_only_commands_carry_no_verification_block` |
| MISMATCH when the recorded type differs and the geometry is inside tolerance; BLOCK wins | CANNOT VERIFY | `test_type_conflict_within_tolerance_is_a_mismatch`, `test_block_wins_over_mismatch` |
| Never invent a missing axis or an absent type | CANNOT VERIFY | `test_missing_axis_is_not_invented`, `test_absent_type_is_not_invented` |
| BLOCK does not resize the wall | CANNOT VERIFY | bounds assertion in `test_wall_offset_of_three_sixteenths_blocks` |
| Materials skill and its commands are gone | PASS | `test_materials_skill_and_save_model_are_gone`, `tests/test_skills.py` |
| Attributes, persistent IDs, nested groups, component instances, Outliner | CANNOT VERIFY | `test_outliner_reads_nested_groups_components_and_attributes`, `test_attribute_write_is_one_undo` |
| Category tag folders and room groups; a shared element is not split | CANNOT VERIFY | `test_category_folders_do_not_move_geometry`, `test_shared_room_is_logged_and_not_split` |
| Reorganizing does not move geometry | CANNOT VERIFY | bounds checks in those two tests |
| One undo per edit | CANNOT VERIFY | `test_attribute_write_is_one_undo`, `test_category_folders_do_not_move_geometry` (commits increase by 1) |
| Disabled skills refused (`ui-control`, `media`, `execute_python`), including bundled load and skill-path env | PASS | `test_disabled_skills_are_refused`, `test_bundled_skills_and_skill_paths_fail_closed` |
| OTLP and webhooks removed; telemetry forced off; fail closed on the wrong core | PASS | `test_lockdown_strips_otlp_and_webhooks`, `test_wrong_core_still_locks_down_before_refusing` |
| A missing host PID still raises before lockdown | PASS | `test_missing_host_pid_raises_before_lockdown` |
| Core pinned to exactly `0.20.36`; doctor does not suggest `pip install --upgrade` | PASS | `test_core_dependency_is_pinned_exactly`, `test_core_install_contract_floor_is_projected_everywhere`, `test_doctor_core_failure_does_not_suggest_pip_upgrade` |
| Import and export limited to the project folder, including a symlink escape | CANNOT VERIFY | `test_path_outside_the_project_folder_is_refused`, `test_symlink_escape_is_refused`, `test_unset_project_folder_fails_closed` |
| Edge-to-edge full face contact | CANNOT VERIFY | No command measures face contact. Real SketchUp only. See `REAL-SKETCHUP-TEST-PLAN.md`. |
| No client send / no live-sync | PASS for the sidecar lockdown (webhooks and OTLP). There is no client-email tool. | `test_lockdown_strips_otlp_and_webhooks` |

## Open risks

- The Ruby contract suite has not run. A syntax or fake-API mistake in `commands.rb` or `tests/ruby/test_commands.rb` would fail CI and would not have shown up here.
- Local pytest did not load the published `dcc-mcp-core` wheel. Skill validation used a structural stand-in. CI runs the real validator.
- `ruff check` and `ruff format --check` were not run here. Ruff could not be installed (PyPI TLS EOF).
- The SketchUp fake applies translation only. Rotation and real `transform_entities` behavior are unproven.
- Tag folders, component definitions, and attribute dictionaries are proven only against the fake, and that proof has not been executed yet.
- Edge contact, gaps, and overlaps are not computed. A model can pass `validate_spec` and still have a gap.
- Real SketchUp 2026 for Windows has not been run. That is a later manual test, on a throwaway synthetic model, on a machine the owner approves.
- `DCC_MCP_SKETCHUP_PROJECT_FOLDER` must be set or save, import, and export fail closed. An unset folder on a real host is a hard stop, which is intended, and it is easy to miss in a manual run.
