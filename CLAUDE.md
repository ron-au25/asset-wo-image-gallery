# Asset WO Image Gallery

SFDX project. Target org: `rsfieldnov25.demo` (demo org, registered in `~/.claude/mods/registry.json`).
Repo: https://github.com/ron-au25/asset-wo-image-gallery (branch `main`).

## Start of session
- Read `README.md` and `PLAN.md` before changing anything.

## Standing rules
- No new custom fields or objects.
- Never show record Ids in output or UI.
- Use `sfx deploy|test|query|retrieve rsfieldnov25.demo ...` instead of raw `sf` (avoids false gate/skills-first blocks).
- Tests use `SeeAllData=true` (a flow blocks WorkOrder inserts in isolated tests).
- Deploy runs 0 tests; run `ImageGalleryControllerTest` separately.
- Re-query the org after deploy to confirm the change landed.
- Update `README.md` and `PLAN.md` when behavior changes.
- Use `/ship` to finish and `/verify` after a deploy.
