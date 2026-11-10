# RenCo Automation System – Agent Instructions (all projects)

Standing instructions for every agent that builds, changes, or runs the RenCo automation (GitHub, Cursor, SketchUp Ruby API, D5) on any RenCo project. Project-specific details go in that project's `PROJECT.md`. These rules win if the two ever conflict.

## 1. What RenCo does
It turns architectural drawings into an accurate, organized SketchUp model and then into renders. It works in stages, and each stage has to pass review before the next one starts:

1. **Intake.** Register every source (plans, red-line revisions, details, elevations, appliance and selection sheets, client emails). Record each one's file name, date, sheet list, and SHA-256 hash. When sources conflict, the newest dated source wins, unless the owner says otherwise.
2. **Geometry reading.** Pull out walls, openings, cabinets, and appliances with dimensions and their source sheet. Anything without a printed dimension is CANNOT VERIFY and never gets guessed.
3. **Spec.** Write a machine-readable spec (JSON plus a readable summary). Each item gets an id, type, position, size, source sheet, and a status of MATCH, MISMATCH, BLOCK, or CANNOT VERIFY.
4. **Model build** in native SketchUp, with geometry only and no materials unless the owner asks.
5. **Review.** The production reviewer grades each change PASS, FIX, or BLOCK.
6. **Render** in D5, only after the model is approved.
7. **Enhancement,** only after the D5 render exists.
8. **QA:** a final PASS, FIX, or BLOCK verdict, with MLS checks for listing images.

The order is always render first, then enhance, then QA. Stages never get skipped.

## 2. Roles
- **Owner (Michelle Cervantes):** the only person who approves design decisions, mismatches, scope changes, external sends, and access to her machines. An agent's approval never counts as hers.
- **Coordinator (CHARLI):** routes work, collects questions and blockers, and brings decisions to the owner. Every other agent goes through the coordinator and never contacts the owner directly.
- **Spec and architecture review (Phineas):** writes and checks specs and code.
- **Production review (Russ):** grades builds.
- **Creative standard (Tyler)** and **QA (Skrillex):** grade renders.
- Reporting lines stay as they are.

## 3. Hard rules
1. **Never touch the originals.** Before any work, hash every protected file and check the hashes again afterward. Files a project lists as off-limits, like another client's model, are never opened, saved, or closed.
2. **Versioned saves only.** Every change is saved as a new file (`<name> v<major>.<minor>.skp`) to a path that doesn't exist yet. Overwriting is never allowed, and the save refuses if the target exists.
3. **One change, one undo.** Each edit is a single undoable operation (start, commit, or abort), read back afterward, and logged with the entity, before and after extents, and the source sheet.
4. **BLOCK, never resize.** If something doesn't fit, block that placement and report it as specified vs available and the difference. Never resize, substitute, or skip anything without saying so.
5. **Tolerance.** Walls and existing geometry within ±1/8" of the drawing count as MATCH, and anything larger is BLOCK. Appliances and packages get zero tolerance, so any difference is a BLOCK.
6. **Edge-to-edge contact.** All parts line up with full face and edge contact, with no gaps or overlaps. Report any you find; never quietly fix them.
7. **Units.** Inches everywhere, written explicitly in every input and output.
8. **Never invent data.** Undimensioned items stay CANNOT VERIFY until the owner gives a value.
9. **No live-sync or render-scene changes** unless the task explicitly covers D5.
10. **No external sends.** Agents never email or message clients or vendors. Drafts go to the owner for review.

## 4. Model organization (every project)
- **Tags** are grouped in tag folders by category: Roof, Slab, Foundation, Walls – Exterior, Walls – Bedroom, Walls – Bathroom, Walls – Kitchen, Doors, Windows, Cabinetry, Appliances, Stairs, Site, Reference.
- **Groups** are organized by room in the Outliner. Each room's items sit under that room's name, for example `L2 – Gym Bar` or `L1 – Kitchen`, using the room names on the plans.
- **Shared elements,** like a wall between two rooms, get logged under both rooms but never split.
- Reorganizing never moves geometry. Prove it with a before and after bounds check.

## 5. Code rules (the repo)
- Work on a feature branch, then open a draft pull request. Never push to `main`, merge, or force-push without the owner's OK.
- Every safety rule in section 3 has an automated test, and tests have to pass before a PR is ready.
- No runtime network calls, telemetry, webhooks, `eval` of AI text, or downloaded scripts. Dependencies are pinned to audited versions.
- File access is limited to the project folder.
- Materials tools stay off by default.
- Real SketchUp runs happen only on a machine the owner approves, and only on a throwaway or versioned test copy.

## 6. Running a project
1. Create `PROJECT.md` with the name, machine and folder, protected files and hashes, off-limits files, the source list, and owner decisions with their dates.
2. Run intake, then geometry reading, then the spec. Send the spec for review.
3. Build each version. After each one, produce:
   - a readout (what changed, entity before and after, statuses)
   - PNGs: a plan, a 3D view, and elevations of the changed areas
   - a hash check of the protected files
4. Review loop: if the reviewer says FIX, fix it in a new version. If the reviewer says BLOCK, it goes to the owner.
5. Collect every BLOCK and CANNOT VERIFY item in one decision list for the owner, instead of sending a stream of small questions.

## 7. Reporting
Every run reports:
- the version built and its file path
- the statuses: MATCH, MISMATCH, BLOCK, CANNOT VERIFY
- what changed, with sources
- protected-file hash results
- open decisions for the owner

Keep it short and plain. A status only counts once the tool output confirms it.

## 8. Stop conditions
Stop and report, without working around it, when:
- a protected file's hash changes
- a save target already exists
- the machine goes offline
- a source is missing
- an action would need access or approval that hasn't been given

## 9. Triggers
Each trigger starts exactly one action. If a trigger's inputs or approvals are missing, the agent stops and reports what's missing instead of running.

| # | Trigger (event) | Runs | Needs first | Output, and who gets it |
|---|---|---|---|---|
| T1 | New project or first drawing set added | Intake: source register and hashes, `PROJECT.md` | Owner names the project | Register, to the Coordinator |
| T2 | New or revised drawing, red-line, detail, or appliance/selection sheet added | Intake update and a diff against the spec | T1 done | Revision register, to Spec review |
| T3 | Owner decision recorded | Log it with its date in `PROJECT.md`, then update the spec | Comes from the owner, not an agent | Decision log, to Spec review |
| T4 | Intake complete | Geometry reading and spec draft | T1 and T2 done | `spec-vX`, to Spec review |
| T5 | Spec approved | Build on a new versioned copy | Approved machine online, hashes verified | Model version, readout, PNGs, hash check, to Production review |
| T6 | Build saved | Production review | T5 output exists | PASS, FIX, or BLOCK, to the Coordinator |
| T7 | Review = FIX | Fix it in the next version (back to T5) | The fix is backed by a source | New version |
| T8 | BLOCK, MISMATCH, or CANNOT VERIFY | Add it to the decision list; the item stays blocked | None | One list, to the owner through the Coordinator |
| T9 | Model all PASS and owner approves | Organize pass (tags by category, groups by room) on a new version, with a bounds check | T6 all PASS | Category and room report |
| T10 | Owner gives the render go | D5 render | Approved model, scene list | Renders, to Creative and QA |
| T11 | D5 render exists | Enhancement | T10 done | Enhanced images, to QA |
| T12 | Enhanced images exist | QA verdict, plus MLS check for listing images | T11 done | PASS, FIX, or BLOCK |
| T13 | Designer or client feedback (material boards, comments) | Revision list mapped to model items | A labeled source file | Back to T3 and T5 |
| T14 | QA PASS and owner approval | Delivery package: view-only folder and a draft note; nothing is sent | T12 PASS | To the owner |

**Stop triggers (always on):**
- A protected file's hash changes, an off-limits file is touched, a save target already exists, the machine goes offline, or a source is missing: stop and report.
- The owner says stop: halt everything until the owner says go.

**Code triggers:**
- A pull request is opened or pushed: run the full test suite.
- Tests fail: the PR stays in draft.
- Tests pass: request Phineas's review. Only the owner merges.
- A dependency changes: pin it and re-audit it.
- Merged to `main`: tag the release and update `CHANGELOG.md`. Nothing deploys automatically to any of the owner's machines.
