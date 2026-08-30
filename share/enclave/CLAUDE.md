<!-- Seeded by severance into a fresh enclave. This file is yours: edit it. -->
# Work enclave

This directory is a sealed work enclave, and the boundary is the kernel, not a
convention.

## The split, and why

Work here is confidential (treat it as zero-data-retention): a personal,
non-confidential account or process must never read or touch these files. The
enclave's top directory is owned `root:<group>`, mode `2770`, with a default
ACL, so only members of the enclave group may enter it. That one directory is
the whole wall. Personal processes are denied entry by the kernel. Do not loosen
its mode or ownership, and do not weaken it in favor of app-level config
(.ignore files, permission lists) that a process can bypass.

## Working in here

- Enter with `work` before editing files, running tools, or launching an agent.
  The enclave group and the matching (confidential) account follow from it; the
  group is acquired per session and never held permanently.
- New files you create inherit the enclave group (setgid + the default ACL), so
  they stay reachable by the enclave and its service accounts with no extra
  steps.
- Put session-only environment in this enclave's own rc, not in any global,
  box-wide config: enclave settings must never leak to the rest of the machine,
  and box config must never enter the enclave.

## The box is provisioned; do not install into it directly

This machine is set up by a separate provisioning layer, and its system state is
meant to be reproducible from that layer's declared inputs, not from ad-hoc
changes.

- Do NOT install system packages or toolchains straight into the box. Register
  the dependency with the provisioning layer (or hand it to the operator) so it
  becomes a reviewed, reproducible input. If a privileged or box-wide step is
  needed, hand it off as a small script for the operator to run rather than
  running it inline.
- The project's OWN dependencies (its language packages, pinned by its
  lockfile) are the project's to install by its own bootstrap, inside the
  enclave. Keep the two layers separate: the shared, reproducible OS floor
  underneath, and the project's self-contained toolchain on top.
