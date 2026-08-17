<!-- Managed by severance; a generic enclave note. Replace with your own. -->
# Work enclave

This directory is a sealed work enclave. Its top directory is owned
`root:<group>`, mode `2770`, with a default ACL, so only members of the enclave
group can enter it. That one directory is the whole wall: personal processes are
denied by the kernel, not by convention. Do not loosen its mode or ownership.

Enter the enclave with `work` before editing files, running tools, or launching
an agent here; the enclave group and the matching account follow from it. Work
here is treated as confidential (zero data retention), so a personal (non-ZDR)
account must never touch these files.

New files you create inherit the enclave group (setgid + the default ACL), so
they stay reachable by the enclave and its service accounts with no extra steps.
