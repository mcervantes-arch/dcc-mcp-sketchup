# Test report — safety baseline follow-up

Branch `renco/safety-baseline`. Base `main` at `b46b947`. Reviewed head was `de11019`. Core pin: `dcc-mcp-core==0.20.36`. Adapter version `0.3.2`.

No client files were opened. Nothing was connected to Michelle's computers, including TKTPC. No runtime network call or telemetry was added. Fixtures are synthetic.

## Counts

| When | Suite | Result |
|---|---|---|
| Phase 1, before, on `main` | Python `pytest` | 156 passed, 0 failed (`156 passed in 39.32s`) |
| Phase 1, before | Ruby | Not executed here |
| Phase 3, head `de11019` (this environment) | Python `pytest` | 166 passed, 0 failed (`166 passed in 39.02s`) |
| Phase 3, head `de11019` (Phineas) | Ruby 3.2.6 | 96 runs, 458 assertions, 0 failures |
| Phase 3, head `de11019` (Phineas) | `ruff check` | passed |
| Phase 3, head `de11019` (Phineas) | `ruff format --check` | failed at `src/dcc_mcp_sketchup/doctor.py:232` |
| Follow-up, this environment | Python `pytest` | 171 passed, 0 failed (`171 passed in 38.34s`) |
| Follow-up, this environment | Ruby 3.2.6 | Did not run. Portable ruby-builder asset download returned TLS EOF. |
| Follow-up, this environment | `ruff check` | Did not run. The ruff binary download returned TLS EOF. |
| Follow-up, this environment | `ruff format --check` | Did not run. The known `doctor.py` reason string was rewritten to the Black form ruff formats. |

Follow-up command, from the branch root:

```text
python3 -m pytest -q --tb=line
```

Final summary: `171 passed in 38.34s`

The Ruby command CI runs, and the one this environment could not run:

```text
ruby -e 'Dir["tests/ruby/test_*.rb"].sort.each { |file| require File.expand_path(file) }'
```

`tests/ruby/` now has 105 `def test_` methods (`test_commands.rb` 69, `test_verification.rb` 17, `test_runtime.rb` 17, `test_bootstrap_errors.rb` 2). They were not executed here.

The local pytest run used source checkouts on `PYTHONPATH`, a stand-in `validate_skill` (the published wheel could not be downloaded), and package metadata that reports core `0.20.36`. CI installs the real wheel. `requirements.lock` records the GitHub release digests for the `dcc-mcp-core` 0.20.36 wheels and sdist.

## Follow-up items

| ID | Status | Note |
|---|---|---|
| D1 | DONE | Any appliance, product, or package difference is BLOCK with specified, available, and delta. Walls and openings stay ±1/8". No filler path. Ruby proof not executed here. |
| D2 | DONE | `save_copy` requires `<JobID>_<Project>_Model_v<NN>.skp`, the same base name, and a strictly higher version. |
| F1 | DONE | Symlinked files are refused via `lstat`. File-symlink tests cover save, export, and import. |
| F2 | DONE | Default and accumulated skill paths are disabled, path overrides are cleared, `reload_skill_paths` refuses `include_bundled=True`, and loaded names are allow-listed. Pytest covers this. |
| F3 | DONE | `DCC_MCP_ETC_DIR` points at this package's `etc/` folder. A webhooks file there refuses startup. Pytest covers this. |
| F4 | DONE | Opening, product, and package kinds are in `validate_spec`. Contact, gap, and overlap are reported and do not move geometry. |
| F5 | DONE | Rotated or nested entities return CANNOT VERIFY. World-axis sizes are not invented for them. |
| F6 | DONE | A missing axis returns per-element CANNOT VERIFY with `missing_axes`. The aggregate includes CANNOT VERIFY. |
| F7 | DONE | `attributes.set` allows only the `renco` dictionary. `renco/type` is write-once unless owner approval is set. |
| F8 | DONE | Non-root room input is refused before anything moves. The after-check re-resolves by persistent id. `LEVEL / 00_REFERENCE..05` stays a manual standard. |
| F9 | DONE | Same naming rule as D2, enforced in `save_copy`. |
| F10 | DONE | `docs/architecture.md` no longer says `overwrite=true`. Dead material checks are gone. Inspect text says material count. |
| F11 | DONE | `compat_matrix.json` lists `Layers#add_folder`, `Layers#folders`, `Layer#folder=`, `Entity#set_attribute`, and `Entity#attribute_dictionaries`. |
| F12 | DONE | `unit: inches` is added only when the result contains lengths. Ping does not get a unit. |
| F13 | DONE | `tags.assign` refuses a raw Face or Edge. |
| F14 | DONE | `entity.erase`, `tags.remove`, and `scenes.remove` refuse unless `DCC_MCP_SKETCHUP_OWNER_APPROVAL=1`. AGENTS.md rule 11 says so. |
| F15 | CANNOT VERIFY | `doctor.py` was rewritten for the reported format failure. `ruff format` itself did not run. |
| F16 | DONE | `requirements.lock` pins `dcc-mcp-core==0.20.36` with sha256 digests from the v0.20.36 GitHub release. |
| A1 | DONE | The code-rules line is "Only Michelle merges." |
| A2 | DONE | Versioned names match D2. Tag codes (`A-WALL-EXT`, `I-CABINETRY`) sit in the existing category folders. |
| A3 | DONE | Real SketchUp is limited to TKTPC, the Alienware, and needs Michelle's OK before opening or saving. |
| A4 | DONE | Rule 1 hash before/after passed in pytest. Rule 6 contact/gap/overlap test is written; the Ruby suite did not run. |

## Open risks

- The Ruby contract suite has not run on this follow-up. A syntax or fake-API mistake would fail CI and would not have shown up here.
- `ruff check` and `ruff format --check` did not run here. The `doctor.py` edit matches the usual Black layout; it is not a substitute for ruff.
- Local pytest did not load the published `dcc-mcp-core` wheel. Skill validation used a structural stand-in.
- The SketchUp fake applies translation only. Rotated entities are refused as CANNOT VERIFY rather than measured on their own axes.
- Room grouping refuses nested parents. It does not build the `LEVEL / 00_REFERENCE..05` hierarchy.
- Real SketchUp 2026 for Windows has not been run. That remains a later manual test on a throwaway synthetic model on TKTPC, after Michelle's OK.
- `DCC_MCP_SKETCHUP_PROJECT_FOLDER` must be set or save, import, and export fail closed.
