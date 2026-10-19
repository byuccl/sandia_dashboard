# Data repositories are git submodules (SSH URLs; needs GitHub SSH access to byuccl).
#   make submodules         check out the commits recorded in this repo
#   make update_submodules  move each submodule to the tip of its tracked branch

.PHONY: submodules update_submodules

submodules:
	git submodule update --init --recursive

update_submodules:
	git submodule update --init --recursive --remote
