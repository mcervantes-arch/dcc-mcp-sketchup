from dcc_mcp_core.skill import run_main

from dcc_mcp_sketchup.skill_tools import bridge_main

main = bridge_main("model.validate_spec", "SketchUp spec compared. The model was not edited.")

if __name__ == "__main__":
    run_main(main)
