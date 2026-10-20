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
# Sites: one hostname and local port per site
################################################################################
DOMAIN      ?= byuccl.org
TUNNEL_NAME ?= byuccl-dashboards

PICKER_HOST ?= test-results.$(DOMAIN)
PICKER_PORT ?= 8080

SRAM_NAME      ?= tamu-sram-2026
SRAM_SUBMODULE ?= sandia_sram_data_2026_10
SRAM_HOST      ?= $(SRAM_NAME).$(DOMAIN)
SRAM_PORT      ?= 8051
# Serve the tester's data in the submodule's sram/ (decoded with `make -C
# $(SRAM_SUBMODULE) decode_shots`) instead of an otv_sync copy in from_remote/.
SRAM_ARGS      ?= DASHBOARD_MEM_DIR=sram/shot_mem DASHBOARD_CSV_PATH=sram/data.csv

STC_NAME      ?= tamu-stc-2026
STC_SUBMODULE ?= sandia_stc_data_2026
STC_HOST      ?= $(STC_NAME).$(DOMAIN)
STC_PORT      ?= 8052
STC_ARGS      ?=

# "name port hostname" for each site, used by `make status`
SITES = picker:$(PICKER_PORT):$(PICKER_HOST) \
        $(SRAM_NAME):$(SRAM_PORT):$(SRAM_HOST) \
        $(STC_NAME):$(STC_PORT):$(STC_HOST)

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
	@for host in $(PICKER_HOST) $(SRAM_HOST) $(STC_HOST); do \
		$(CLOUDFLARED) tunnel route dns --overwrite-dns $(TUNNEL_NAME) $$host || exit 1; \
	done
	@$(MAKE) --no-print-directory tunnel_config

# Regenerate cloudflared/config.yml from its template (after changing sites).
tunnel_config:
	@ID="$(_tunnel_id)"; \
	if [ -z "$$ID" ]; then echo "Tunnel $(TUNNEL_NAME) not found; run 'make tunnel_setup'."; exit 1; fi; \
	sed -e "s|@TUNNEL_ID@|$$ID|" \
	    -e "s|@CREDENTIALS_FILE@|$(CLOUDFLARED_DIR)/$$ID.json|" \
	    -e "s|@PICKER_HOST@|$(PICKER_HOST)|" -e "s|@PICKER_PORT@|$(PICKER_PORT)|" \
	    -e "s|@SRAM_HOST@|$(SRAM_HOST)|"     -e "s|@SRAM_PORT@|$(SRAM_PORT)|" \
	    -e "s|@STC_HOST@|$(STC_HOST)|"       -e "s|@STC_PORT@|$(STC_PORT)|" \
	    $(TUNNEL_CONFIG).in > $(TUNNEL_CONFIG); \
	$(CLOUDFLARED) tunnel --config $(TUNNEL_CONFIG) ingress validate && \
	echo "Wrote $(TUNNEL_CONFIG) for tunnel $$ID."

################################################################################
# systemd services (start at boot, restart on failure)
################################################################################
SRAM_SERVICE = byuccl-$(SRAM_NAME)
STC_SERVICE  = byuccl-$(STC_NAME)
SERVICES     = byuccl-tunnel byuccl-picker $(SRAM_SERVICE) $(STC_SERVICE)
UNIT_FILES   = $(SERVICES:%=systemd/%.service)

_render = sed -e 's|@USER@|$(USER)|g' -e 's|@REPO@|$(CURDIR)|g' \
              -e 's|@CLOUDFLARED@|$(CLOUDFLARED)|g' -e 's|@PICKER_PORT@|$(PICKER_PORT)|g'

systemd/byuccl-tunnel.service: systemd/byuccl-tunnel.service.in Makefile
	$(_render) $< > $@

systemd/byuccl-picker.service: systemd/byuccl-picker.service.in Makefile
	$(_render) $< > $@

systemd/$(SRAM_SERVICE).service: systemd/byuccl-dashboard.service.in Makefile
	$(_render) -e 's|@NAME@|$(SRAM_NAME)|g' -e 's|@HOST@|$(SRAM_HOST)|g' \
	    -e 's|@SUBMODULE@|$(SRAM_SUBMODULE)|g' -e 's|@PORT@|$(SRAM_PORT)|g' -e 's|@ARGS@|$(SRAM_ARGS)|g' $< > $@

systemd/$(STC_SERVICE).service: systemd/byuccl-dashboard.service.in Makefile
	$(_render) -e 's|@NAME@|$(STC_NAME)|g' -e 's|@HOST@|$(STC_HOST)|g' \
	    -e 's|@SUBMODULE@|$(STC_SUBMODULE)|g' -e 's|@PORT@|$(STC_PORT)|g' -e 's|@ARGS@|$(STC_ARGS)|g' $< > $@

units: $(UNIT_FILES)

# Install (or refresh) the units, enable them at boot and (re)start them.
install_services: $(UNIT_FILES)
	@test -f $(TUNNEL_CONFIG) || { echo "Missing $(TUNNEL_CONFIG); run 'make tunnel_setup' first."; exit 1; }
	@for d in $(SRAM_SUBMODULE) $(STC_SUBMODULE); do \
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
	@for s in $(SERVICES); do printf '%-28s %s\n' $$s "$$(systemctl is-active $$s)"; done
	@echo
	@printf '%-16s %-7s %-7s %s\n' SITE LOCAL PUBLIC URL
	@for site in $(SITES); do \
		name=$${site%%:*}; rest=$${site#*:}; port=$${rest%%:*}; host=$${rest#*:}; \
		lc=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:$$port/); \
		pc=$$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://$$host/); \
		printf '%-16s %-7s %-7s %s\n' $$name $$lc $$pc https://$$host/; \
	done
