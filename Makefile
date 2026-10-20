# Data repositories are git submodules (SSH URLs; needs GitHub SSH access to byuccl).
#   make submodules         check out the commits recorded in this repo
#   make update_submodules  move each submodule to the tip of its tracked branch
#
# Public hosting through a Cloudflare Tunnel (see README.md):
#   make tunnel_setup       one time: create the tunnel, DNS records and config
#   make install_services   install/refresh the systemd services (uses sudo)
#   make status             show service state and check each site
#   make restart            restart all services (uses sudo)
#   make logs               follow the logs of all services

.PHONY: submodules update_submodules tunnel_setup tunnel_config units \
        install_services uninstall_services restart status logs

submodules:
	git submodule update --init --recursive

update_submodules:
	git submodule update --init --recursive --remote

################################################################################
# Sites: the picker page plus one dashboard per entry in DASHBOARDS. Each
# dashboard <D> sets <D>_NAME (its subdomain), <D>_SUBMODULE, <D>_PORT and
# <D>_ARGS (extra variables for the submodule's `make dashboard_serve`).
################################################################################
DOMAIN      ?= byuccl.org
TUNNEL_NAME ?= byuccl-dashboards

PICKER_HOST ?= test-results.$(DOMAIN)
PICKER_PORT ?= 8080

DASHBOARDS = SRAM STC JUNE

SRAM_NAME      ?= tamu-sram-2026
SRAM_SUBMODULE ?= sandia_sram_data_2026_10
SRAM_PORT      ?= 8051
# Serve the tester's data in the submodule's sram/ (decoded with `make -C
# $(SRAM_SUBMODULE) decode_shots`) instead of an otv_sync copy in from_remote/.
SRAM_ARGS      ?= DASHBOARD_MEM_DIR=sram/shot_mem DASHBOARD_CSV_PATH=sram/data.csv

STC_NAME      ?= tamu-stc-2026
STC_SUBMODULE ?= sandia_stc_data_2026
STC_PORT      ?= 8052
STC_ARGS      ?=

JUNE_NAME      ?= lmtf-combined-2026
JUNE_SUBMODULE ?= sandia_combined_data_2026_06_sanitized
JUNE_PORT      ?= 8053
# One dashboard serves all three boards: it finds each run's board by which of
# sram/post_mem, stc/mem and stm32/mem holds it (`make -C $(JUNE_SUBMODULE)
# generate_mems`). The paths here are only its fallback.
JUNE_ARGS      ?= DASHBOARD_MEM_DIR=stm32/mem DASHBOARD_CSV_PATH=stm32/data.csv

_host = $($(1)_NAME).$(DOMAIN)

# "name:port:hostname" for each site, used by tunnel_config and status
SITES = picker:$(PICKER_PORT):$(PICKER_HOST) \
        $(foreach d,$(DASHBOARDS),$($(d)_NAME):$($(d)_PORT):$(call _host,$(d)))
_split_site = name=$${site%%:*}; rest=$${site\#*:}; port=$${rest%%:*}; host=$${rest\#*:}

################################################################################
# Cloudflare Tunnel
################################################################################
CLOUDFLARED     ?= $(shell command -v cloudflared 2>/dev/null || echo /usr/bin/cloudflared)
CLOUDFLARED_DIR ?= $(HOME)/.cloudflared
TUNNEL_CONFIG    = cloudflared/config.yml

_tunnel_id = $(shell $(CLOUDFLARED) tunnel list --name $(TUNNEL_NAME) --output json 2>/dev/null \
	| python3 -c 'import json,sys; t=json.load(sys.stdin); print(t[0]["id"] if t else "")' 2>/dev/null)

# Create the tunnel (if missing), point each hostname at it, and write the config.
tunnel_setup:
	@test -x "$(CLOUDFLARED)" || { echo "cloudflared is not installed (see README.md)."; exit 1; }
	@test -f $(CLOUDFLARED_DIR)/cert.pem || { echo "Run 'cloudflared tunnel login' first."; exit 1; }
	@if [ -z "$(_tunnel_id)" ]; then $(CLOUDFLARED) tunnel create $(TUNNEL_NAME); \
	else echo "Tunnel $(TUNNEL_NAME) already exists."; fi
	@for site in $(SITES); do $(_split_site); \
		$(CLOUDFLARED) tunnel route dns --overwrite-dns $(TUNNEL_NAME) $$host || exit 1; \
	done
	@$(MAKE) --no-print-directory tunnel_config

# Regenerate cloudflared/config.yml (after changing sites): the template's
# header plus one ingress rule per site and a final catch-all.
tunnel_config:
	@ID="$(_tunnel_id)"; \
	if [ -z "$$ID" ]; then echo "Tunnel $(TUNNEL_NAME) not found; run 'make tunnel_setup'."; exit 1; fi; \
	{ sed -e "s|@TUNNEL_ID@|$$ID|" -e "s|@CREDENTIALS_FILE@|$(CLOUDFLARED_DIR)/$$ID.json|" $(TUNNEL_CONFIG).in; \
	  for site in $(SITES); do $(_split_site); \
		printf '  - hostname: %s\n    service: http://127.0.0.1:%s\n' $$host $$port; \
	  done; \
	  echo '  - service: http_status:404'; \
	} > $(TUNNEL_CONFIG); \
	$(CLOUDFLARED) tunnel --config $(TUNNEL_CONFIG) ingress validate && \
	echo "Wrote $(TUNNEL_CONFIG) for tunnel $$ID."

################################################################################
# systemd services (start at boot, restart on failure)
################################################################################
SERVICES   = byuccl-tunnel byuccl-picker $(foreach d,$(DASHBOARDS),byuccl-$($(d)_NAME))
UNIT_FILES = $(SERVICES:%=systemd/%.service)

_render = sed -e 's|@USER@|$(USER)|g' -e 's|@REPO@|$(CURDIR)|g' \
              -e 's|@CLOUDFLARED@|$(CLOUDFLARED)|g' -e 's|@PICKER_PORT@|$(PICKER_PORT)|g'

systemd/byuccl-tunnel.service: systemd/byuccl-tunnel.service.in Makefile
	$(_render) $< > $@

systemd/byuccl-picker.service: systemd/byuccl-picker.service.in Makefile
	$(_render) $< > $@

define _dashboard_unit
systemd/byuccl-$($(1)_NAME).service: systemd/byuccl-dashboard.service.in Makefile
	$$(_render) -e 's|@NAME@|$($(1)_NAME)|g' -e 's|@HOST@|$(call _host,$(1))|g' \
	    -e 's|@SUBMODULE@|$($(1)_SUBMODULE)|g' -e 's|@PORT@|$($(1)_PORT)|g' -e 's|@ARGS@|$($(1)_ARGS)|g' $$< > $$@
endef
$(foreach d,$(DASHBOARDS),$(eval $(call _dashboard_unit,$(d))))

units: $(UNIT_FILES)

# Install (or refresh) the units, enable them at boot and (re)start them.
install_services: $(UNIT_FILES)
	@test -f $(TUNNEL_CONFIG) || { echo "Missing $(TUNNEL_CONFIG); run 'make tunnel_setup' first."; exit 1; }
	@for d in $(foreach d,$(DASHBOARDS),$($(d)_SUBMODULE)); do \
		test -f $$d/.venv/bin/activate || { echo "Missing $$d/.venv; run 'make -C $$d env' first."; exit 1; }; \
	done
	sudo install -m 644 $(UNIT_FILES) /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable $(SERVICES)
	sudo systemctl restart $(SERVICES)
	@$(MAKE) --no-print-directory status

uninstall_services:
	-sudo systemctl disable --now $(SERVICES)
	sudo rm -f $(SERVICES:%=/etc/systemd/system/%.service)
	sudo systemctl daemon-reload

restart:
	sudo systemctl restart $(SERVICES)

logs:
	journalctl -f $(SERVICES:%=-u %)

# Service state, then each site locally (should be 200) and publicly (should be
# 302: a redirect to the Cloudflare Access login page).
status:
	@for s in $(SERVICES); do printf '%-36s %s\n' $$s "$$(systemctl is-active $$s)"; done
	@echo
	@printf '%-20s %-7s %-7s %s\n' SITE LOCAL PUBLIC URL
	@for site in $(SITES); do $(_split_site); \
		lc=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$$port/); \
		pc=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://$$host/); \
		printf '%-20s %-7s %-7s %s\n' $$name $$lc $$pc https://$$host/; \
	done
