# Operator entry points for the production-service-env stack.
# Most targets wrap systemd / the scripts in ./scripts. Run `make help`.

SERVICES := ride-api matching-service dispatch-service

.PHONY: help install start stop restart status verify evidence logs ports

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install:  ## Full first-time deploy (sudo): code, venv, units, nginx, firewall
	sudo ./scripts/install.sh

start:  ## Start all services (dependency order: matching-service, dispatch-service, then ride-api)
	sudo systemctl start matching-service dispatch-service ride-api

stop:  ## Stop all services
	sudo systemctl stop ride-api matching-service dispatch-service

restart:  ## Restart all services
	sudo systemctl restart matching-service dispatch-service ride-api

status:  ## Show unit status for all three services
	systemctl status $(SERVICES) --no-pager

ports:  ## Show what's listening on 3001/3002/3003
	sudo ss -ltnp '( sport = :3001 or sport = :3002 or sport = :3003 )'

verify:  ## Run the end-to-end smoke test
	./scripts/test-end-to-end.sh

evidence:  ## Capture an inside-VM proof transcript into docs/evidence/
	./scripts/collect-evidence.sh

logs:  ## Follow structured JSON logs for all three services
	journalctl -u ride-api -u matching-service -u dispatch-service -f -o cat
