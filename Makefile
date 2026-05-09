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
	bash scripts/load_to_hdfs.sh

job-top: ## Run Job 1 (top resources)
	set -o pipefail
	bash scripts/run_job.sh top_resources 2>&1 | tee data/output/top_resources.log
	set +o pipefail
	sort -k2 -n -r data/output/top_resources.raw.txt | head -20 > data/output/top_resources.txt

job-status: ## Run Job 2 (status + bytes)
	set -o pipefail
	bash scripts/run_job.sh status_bytes 2>&1 | tee data/output/status_bytes.log
	sort -k1 -n data/output/status_bytes.raw.txt > data/output/status_bytes.txt

results: ## Print job output tables
	@echo "=== Job 1: Top 20 Requested Resources ==="
	cat data/output/top_resources.txt
	echo ""
	echo "=== Job 2: HTTP Status Distribution ==="
	printf "%-8s %-12s %s\n" "Status" "Requests" "Bytes"
	cat data/output/status_bytes.txt
	echo ""
	echo "=== Key Counters ==="
	echo "Job 1 (top_resources):"
	if [ -f data/output/top_resources.log ]; then
		grep -E "(Map input records|Combine input records|Reduce output records|malformed_line)" \
			data/output/top_resources.log | sed 's/^[[:space:]]*/  /'
	else
		echo "  (run make job-top first)"
	fi
	echo "Job 2 (status_bytes):"
	if [ -f data/output/status_bytes.log ]; then
		grep -E "(Map input records|Combine input records|Reduce output records|malformed_line)" \
			data/output/status_bytes.log | sed 's/^[[:space:]]*/  /'
	else
		echo "  (run make job-status first)"
	fi

demo: ## Run full pipeline end-to-end
	set -e
	$(MAKE) up
	$(MAKE) verify
	$(MAKE) download
	$(MAKE) load
	$(MAKE) job-top
	$(MAKE) job-status
	$(MAKE) results

clean: ## Remove outputs, dataset, and Docker resources
	find data/output -mindepth 1 ! -name '.gitkeep' -delete
	find data -maxdepth 1 -name 'NASA_access_log_Jul95*' -delete
	docker compose down -v --remove-orphans 2>/dev/null || true

test: ## Run unit tests for mappers and reducers
	echo "TODO: test"
