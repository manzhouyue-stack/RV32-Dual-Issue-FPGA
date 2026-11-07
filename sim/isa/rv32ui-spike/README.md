This directory contains the 41 `*.spike.log` reference files produced by
`tests/prepare_rv32ui.py` on the scorpion Ubuntu VM with Spike 1.1.1-dev.

To regenerate, run the preparation script on Ubuntu, copy
`~/rv32ui-build/*.spike.log` into this directory, and run
`python tests/compare_rv32ui_spike.py` from the project root.
