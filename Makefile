SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

.PHONY: help up down verify download load job-top job-status job-hourly results demo clean test report

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "%-15s %s\n", "Target", "Description"; printf "%-15s %s\n", "------", "-----------"} /^[a-zA-Z_-]+:.*?##/ { printf "%-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: ## Start the Hadoop cluster (7 containers)
	docker compose up -d --build --scale datanode=2 --scale nodemanager=2
	echo "Waiting for all containers to be healthy (up to 240s)..."
	elapsed=0; \
	while [ $$elapsed -lt 240 ]; do \
		count=$$(docker compose ps --format json 2>/dev/null | python3 -c "import sys,json; data=sys.stdin.read().strip(); rows=[json.loads(l) for l in data.splitlines() if l.strip()]; print(sum(1 for r in rows if r.get('Health')=='healthy'))" 2>/dev/null || echo 0); \
		if [ "$$count" -ge 7 ]; then \
			echo "All 7 containers healthy."; \
			exit 0; \
		fi; \
		sleep 5; \
		elapsed=$$((elapsed + 5)); \
	done; \
	echo "Timeout: only $$count/7 containers healthy after 240s." >&2; \
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

job-hourly: ## Run Job 3 (hourly traffic distribution)
	set -o pipefail
	bash scripts/run_job.sh hourly_traffic 2>&1 | tee data/output/hourly_traffic.log
	set +o pipefail
	sort -k1 -n data/output/hourly_traffic.raw.txt > data/output/hourly_traffic.txt

results: ## Print job output tables
	@echo "=== Job 1: Top 20 Requested Resources ==="
	cat data/output/top_resources.txt
	echo ""
	echo "=== Job 2: HTTP Status Distribution ==="
	printf "%-8s %-12s %s\n" "Status" "Requests" "Bytes"
	cat data/output/status_bytes.txt
	echo ""
	echo ""
	echo "=== Job 3: Hourly Traffic Distribution ==="
	printf "%-6s %s\n" "Hour" "Requests"
	cat data/output/hourly_traffic.txt
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
	$(MAKE) job-hourly
	$(MAKE) results

clean: ## Remove outputs, dataset, and Docker resources
	find data/output -mindepth 1 ! -name '.gitkeep' -delete
	find data -maxdepth 1 -name 'NASA_access_log_Jul95*' -delete
	docker compose down -v --remove-orphans 2>/dev/null || true

test: ## Run unit tests for mappers and reducers
	cd tests && python3 -m unittest -v

report: ## Build the technical report PDF (requires TeX Live + biber)
	python3 scripts/build_figures.py
	cd report && pdflatex -interaction=nonstopmode main.tex && biber main && pdflatex -interaction=nonstopmode main.tex && pdflatex -interaction=nonstopmode main.tex
	@echo "Report written to report/main.pdf"
