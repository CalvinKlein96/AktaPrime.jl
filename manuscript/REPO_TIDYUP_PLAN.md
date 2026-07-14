# Repository tidy-up plan (pre-submission)

Things in the repository that should be addressed before the code is
published alongside the HardwareX manuscript and bioRxiv preprint. Ordered
roughly by importance. Nothing here has been changed yet — this is a plan for
your review.

## A. Blockers for open publication

1. **Add a LICENSE file.** There is currently no licence anywhere in the
   repository. HardwareX requires the software to carry an open-source licence,
   and the interoperability-exemption framing in the manuscript reads oddly
   without one. *Decision needed:* which licence. Recommendation: an
   OSI-approved permissive licence (MIT or Apache-2.0) for the code. Apache-2.0
   additionally grants a patent licence, which is a mild plus for
   reverse-engineering work. The article itself will be CC-BY per HardwareX
   policy. Add the corresponding `license = "…"` note and fill the licence
   column in the manuscript's design-files table.

2. **Make the repository public** and update the README. The README's
   install section is written for a *private* repo ("Access to this private
   repository", SSH/credential authentication notes). Once public, simplify
   these instructions. The manuscript's specifications table and Section 5
   both flag this.

3. **Decide how the validation run data is shipped.** `.gitignore` currently
   ignores `*.csv`, so no experimental run data is (or can be) committed. For
   the paper you will want at least the featured validation run's CSV log and
   exported chromatogram to be citable under "Data availability". Options:
   commit the chosen run under an un-ignored path (e.g. `examples/` or
   `data/`, with a narrow `.gitignore` exception), or deposit it with the
   archived release (Zenodo) and link it. Either way the demo/replay filenames
   referenced in the README (`akta_demo_…csv`, `run_log.csv`) currently point
   to files that are not in the repo — either add a small sample log or adjust
   the wording.

## B. Scholarly-metadata niceties

4. **Add a `CITATION.cff`** so the repository is citable, and cross-link the
   archived DOI once minted.

5. **Expand the README** to mention what the software is (an FPLC controller,
   not just a "logger/visualiser"), the hardware it targets, the protocol
   documentation under `assets/`, the licence, and a citation pointer. The
   current one-line description undersells the project relative to the
   manuscript.

6. **Archive a tagged release** (e.g. Zenodo) to obtain the permanent DOI the
   manuscript's metadata tables ask for, and bump/confirm the version tag to
   match `Project.toml` (v0.1.0).

## C. Code-quality items (optional, non-blocking)

7. **No tests and no CI.** There is no `test/` directory and no
   `.github/` workflow. Even a small test set would strengthen the software
   publication considerably and is straightforward for the pure-logic parts:
   - `checksum`, `build_poll_frame`/`build_ack_frame`/`build_i_frame` against
     the worked byte sequences already given in `assets/PROTOCOL.md` (e.g. the
     SNRM `#0S5\r`, UA `#1uX\r`, and the fully worked `0x1001/0x01` connect
     frame `23 30 40 32 31 30 31 31 30 47 0D`);
   - `encode_opc_payload`/`decode_opc_payload` round-tripping;
   - `_handle_trend_data` decoding a known 14-byte payload to the expected
     engineering values;
   - the fraction state machine (`update_fraction_state!`) and CSV
     round-tripping via `load_csv_log!`.
   These need no hardware. Add a minimal GitHub Actions matrix (Julia 1.12) to
   run them. Note that GUI code (`gui.jl`) is hard to test headlessly and can
   be excluded.

8. **Naming idiom (cosmetic, for a Julia audience).** The manuscript's style
   note (idiomatic Julia: no underscores in function names, multiple dispatch
   over `if/elseif`) does not match the current code, which uses
   leading-underscore, underscore-separated private helpers (`_handle_trend_data`,
   `_run_live`, `build_poll_frame`, …) and a long `if opc == … elseif …`
   ladder in `dispatch_rx_opc`. This is a legitimate style choice and is *not*
   a defect, but if the code is going to be read by Julia reviewers you may
   wish to (a) dispatch OPC handling on `Val{opc}` or a set of singleton OPC
   types via multiple dispatch, and (b) reconsider the underscore-heavy names.
   Weigh this against the risk of churn in working, hardware-validated code —
   it is safe to leave as-is.

9. **Resolve or clearly annotate the remaining protocol unknowns in code.**
   The pH scale and the pressure unit are recorded as "TBD" in `types.jl`
   comments and in the decompilation reference. If your instrument can pin
   these down (a pH electrode; a known pressure reference), doing so and
   updating both the code comments and the manuscript's Section 3.5 would close
   the last open items. Otherwise, leaving the explicit "TBD" annotations is
   the honest choice and matches the manuscript.

10. **Minor consistency.** `README.md` example commands reference
    `/dev/tty.usbserial-110`, which is also the hard-coded `DEFAULT_SERIAL_PORT`
    in `protocol.jl` — fine, but worth a one-line note that this default is
    macOS-flavoured; Linux users will see `/dev/ttyUSB0` etc. and Windows
    `COM3`. Consider mentioning platform-specific device names in the README.

## D. Manuscript-linked placeholders (need your input)

These are the `⟦…⟧` markers in `HardwareX_manuscript.md`, collected here:

- Author list, order, ORCIDs, affiliations, corresponding author.
- Funding statement, competing-interests declaration, CRediT roles,
  acknowledgements.
- The specific WineHQ AppDB entry and LabWrench threads to cite as evidence of
  user need (URLs + access dates).
- Legal-framing review of the interoperability-exemption paragraph (§1.1).
- Choice of licence (feeds items A1 and the design-files table).
- The featured validation run(s): what was purified, the chromatogram figure,
  the CSV log to deposit, and any downstream evidence (e.g. SDS-PAGE).
- Whether the pH/pressure unknowns have since been resolved (§3.5).
- Archived-release DOI once minted.
- References list (do not fabricate; see the References placeholder).
