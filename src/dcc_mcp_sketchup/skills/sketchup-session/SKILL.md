---
name: sketchup-session
description: >-
  Inspect a live SketchUp model and manage save, validation, import, and export
  through typed host operations. Use for session discovery and interchange;
  use sketchup-modeling for geometry changes. Never executes arbitrary Ruby.
license: MIT
compatibility: "SketchUp 2021+; external sidecar Python 3.9+; dcc-mcp-core 0.20.36"
allowed-tools: Python
metadata:
  dcc-mcp:
    dcc: sketchup
    layer: domain
    version: "0.3.2"  # x-release-please-version
    stage: session
    search-hint: "SketchUp session inspect entities save copy validate import export SKP DAE STL GLB"
    tags: "sketchup,session,model,interchange"
    tools: tools.yaml
---

# SketchUp Session

Inspect before mutating. Lengths are inches. File paths must be absolute and
inside the configured project folder (`DCC_MCP_SKETCHUP_PROJECT_FOLDER`).
`save_copy` is the only save: a new `<JobID>_<Project>_Model_v<NN>.skp` with the
same base name as the source and a strictly higher version. It is not the
source path and does not already exist. Import and export refuse anything
outside the project folder. There is no overwrite.
