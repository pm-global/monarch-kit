# Raw: Advisory Card Action Hints

## What

Advisory cards in the HTML report need action hints — specific guidance text displayed
alongside findings. Critical cards got hints in TODO-1 (privaccess output work). Advisory
cards have a separate hint set with different wording requirements.

## Why It's Raw

The hint text for advisory cards requires careful wording — some conditions (Protected Users
gap, non-privileged Kerberoast, medium-risk legacy protocol) are context-dependent and the
guidance could mislead if phrased incorrectly. Needs a planning pass before implementation.

## Known Constraints

- Must be planned and implemented separately after TODO-1 ships
- Wording must avoid false urgency for advisory-level findings
- Hints reference the same hint infrastructure added during critical card work

## Next Step

When ready to design: promote to docs/plans/ with full hint text for each advisory card type.
