SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

.PHONY: help up down verify download load job-top job-status results demo clean test

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "%-15s %s\n", "Target", "Description"; printf "%-15s %s\n", "------", "-----------"} /^[a-zA-Z_-]+:.*?##/ { printf "%-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: ## Start the Hadoop cluster (5 containers)
	docker compose up -d --build
	echo "Waiting for all containers to be healthy (up to 180s)..."
	elapsed=0
	while [ $$elapsed -lt 180 ]; do
		count=$$(docker inspect --format '{{.State.Health.Status}}' \
			nasa-namenode nasa-datanode nasa-resourcemanager nasa-nodemanager nasa-historyserver \
			2>/dev/null | grep -c '^healthy$$' || true)
		if [ "$$count" -eq 5 ]; then
			echo "All 5 containers healthy."
			exit 0
		fi
		sleep 5
		elapsed=$$((elapsed + 5))
	done
	echo "Timeout: not all containers healthy after 180s." >&2
	exit 1

down: ## Stop the Hadoop cluster
	docker compose down

verify: ## Verify cluster health and run smoke test
	bash scripts/verify_cluster.sh

download: ## Download and validate the NASA dataset
	bash scripts/download_dataset.sh

load: ## Load dataset into HDFS
	echo "TODO: load"

job-top: ## Run Job 1 (top resources)
	echo "TODO: job-top"

job-status: ## Run Job 2 (status + bytes)
	echo "TODO: job-status"

results: ## Print job output tables
	echo "TODO: results"

demo: ## Run full pipeline end-to-end
	echo "TODO: demo"

clean: ## Remove outputs, dataset, and Docker resources
	find data/output -mindepth 1 ! -name '.gitkeep' -delete
	find data -maxdepth 1 -name 'NASA_access_log_Jul95*' -delete
	docker compose down -v --remove-orphans 2>/dev/null || true

test: ## Run unit tests for mappers and reducers
	echo "TODO: test"
