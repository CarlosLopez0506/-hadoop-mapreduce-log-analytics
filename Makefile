SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

.PHONY: help up down verify download load job-top job-status job-hourly results demo clean test report ec2-up ec2-deploy ec2-demo ec2-down ec2-dashboard

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"; printf "%-15s %s\n", "Target", "Description"; printf "%-15s %s\n", "------", "-----------"} /^[a-zA-Z_-]+:.*?##/ { printf "%-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: ## Start the Hadoop cluster (7 containers)
	docker build -t mapreduce-nasa:3.4.1 . && docker compose up -d --scale datanode=2 --scale nodemanager=2
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

ec2-up: ## Launch EC2 instance for the Hadoop demo
	@set -e; \
	echo "Getting latest Amazon Linux 2023 AMI..."; \
	AMI=$$(aws ec2 describe-images --owners amazon \
	  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
	  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text); \
	echo "Using AMI: $$AMI"; \
	if [ ! -f nasa-demo.pem ]; then \
	  echo "Creating key pair nasa-demo..."; \
	  aws ec2 create-key-pair --key-name nasa-demo --query 'KeyMaterial' --output text > nasa-demo.pem; \
	  chmod 400 nasa-demo.pem; \
	  echo "Key pair created and saved to nasa-demo.pem"; \
	else \
	  echo "Key pair nasa-demo.pem already exists, skipping creation."; \
	fi; \
	echo "Opening additional ports on security group..."; \
	aws ec2 authorize-security-group-ingress --group-id sg-0ce597dbefd715675 \
	  --protocol tcp --port 9870 --cidr 0.0.0.0/0 2>/dev/null || true; \
	aws ec2 authorize-security-group-ingress --group-id sg-0ce597dbefd715675 \
	  --protocol tcp --port 8088 --cidr 0.0.0.0/0 2>/dev/null || true; \
	aws ec2 authorize-security-group-ingress --group-id sg-0ce597dbefd715675 \
	  --protocol tcp --port 19888 --cidr 0.0.0.0/0 2>/dev/null || true; \
	echo "Launching EC2 instance..."; \
	INSTANCE_ID=$$(aws ec2 run-instances \
	  --image-id "$$AMI" \
	  --instance-type m5.xlarge \
	  --security-group-ids sg-0ce597dbefd715675 \
	  --key-name nasa-demo \
	  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
	  --user-data file://scripts/ec2_bootstrap.sh \
	  --query 'Instances[0].InstanceId' --output text); \
	echo "$$INSTANCE_ID" > .ec2_instance_id; \
	echo "Instance launched: $$INSTANCE_ID"; \
	echo "Waiting for instance to be running..."; \
	aws ec2 wait instance-running --instance-ids "$$INSTANCE_ID"; \
	EC2_IP=$$(aws ec2 describe-instances \
	  --instance-ids "$$INSTANCE_ID" \
	  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text); \
	echo "$$EC2_IP" > .ec2_ip; \
	echo "./nasa-demo.pem" > .ec2_key; \
	echo ""; \
	echo "=========================================="; \
	echo "Instance ID : $$INSTANCE_ID"; \
	echo "Public IP   : $$EC2_IP"; \
	echo "YARN UI     : http://$$EC2_IP:8088"; \
	echo "NameNode UI : http://$$EC2_IP:9870"; \
	echo "HistoryServer: http://$$EC2_IP:19888"; \
	echo "=========================================="

ec2-deploy: ## Upload project to EC2 and prepare dataset
	bash scripts/ec2_deploy.sh

ec2-demo: ## Run make demo on the EC2 instance
	ssh -i $$(cat .ec2_key) -o StrictHostKeyChecking=no ec2-user@$$(cat .ec2_ip) \
	  "cd /home/ec2-user/ml-big-data && make up && make demo"

ec2-down: ## Terminate the EC2 instance
	aws ec2 terminate-instances --instance-ids $$(cat .ec2_instance_id)
	@echo "Instance $$(cat .ec2_instance_id) terminating."

ec2-dashboard: ## Deploy dashboard to EC2 via SSM
	mkdir -p dashboard/api/results dashboard/api/logs
	bash scripts/results_to_json.sh
	@echo "Deploying dashboard to EC2..."
	@# Step 1: Install Apache
	@CMD_ID=$$(AWS_DEFAULT_REGION=us-east-1 aws ssm send-command \
	  --instance-ids i-003b293d36c02e0cd \
	  --document-name "AWS-RunShellScript" \
	  --timeout-seconds 120 \
	  --parameters "commands=[\"yum install -y httpd && systemctl start httpd && systemctl enable httpd && echo APACHE_DONE\"]" \
	  --query 'Command.CommandId' --output text); \
	until [ "$$(AWS_DEFAULT_REGION=us-east-1 aws ssm get-command-invocation --command-id $$CMD_ID --instance-id i-003b293d36c02e0cd --query 'Status' --output text 2>/dev/null)" != "InProgress" ]; do sleep 5; done; \
	AWS_DEFAULT_REGION=us-east-1 aws ssm get-command-invocation --command-id $$CMD_ID --instance-id i-003b293d36c02e0cd --query 'StandardOutputContent' --output text
	@# Step 2: Create dirs
	@CMD_ID=$$(AWS_DEFAULT_REGION=us-east-1 aws ssm send-command \
	  --instance-ids i-003b293d36c02e0cd \
	  --document-name "AWS-RunShellScript" \
	  --timeout-seconds 30 \
	  --parameters "commands=[\"mkdir -p /var/www/html/api/results /var/www/html/api/logs && echo DIRS_DONE\"]" \
	  --query 'Command.CommandId' --output text); \
	until [ "$$(AWS_DEFAULT_REGION=us-east-1 aws ssm get-command-invocation --command-id $$CMD_ID --instance-id i-003b293d36c02e0cd --query 'Status' --output text 2>/dev/null)" != "InProgress" ]; do sleep 5; done
	@# Step 3: Upload index.html via base64
	@B64=$$(base64 -w 0 dashboard/index.html); \
	CMD_ID=$$(AWS_DEFAULT_REGION=us-east-1 aws ssm send-command \
	  --instance-ids i-003b293d36c02e0cd \
	  --document-name "AWS-RunShellScript" \
	  --timeout-seconds 30 \
	  --parameters "commands=[\"echo '$$B64' | base64 -d > /var/www/html/index.html\"]" \
	  --query 'Command.CommandId' --output text); \
	until [ "$$(AWS_DEFAULT_REGION=us-east-1 aws ssm get-command-invocation --command-id $$CMD_ID --instance-id i-003b293d36c02e0cd --query 'Status' --output text 2>/dev/null)" != "InProgress" ]; do sleep 5; done; \
	echo "index.html uploaded"
	@# Step 4: Upload JSON results
	@for f in top_resources status_bytes hourly_traffic; do \
	  B64=$$(base64 -w 0 dashboard/api/results/$$f.json); \
	  CMD_ID=$$(AWS_DEFAULT_REGION=us-east-1 aws ssm send-command \
	    --instance-ids i-003b293d36c02e0cd \
	    --document-name "AWS-RunShellScript" \
	    --timeout-seconds 30 \
	    --parameters "commands=[\"echo '$$B64' | base64 -d > /var/www/html/api/results/$$f.json\"]" \
	    --query 'Command.CommandId' --output text); \
	  until [ "$$(AWS_DEFAULT_REGION=us-east-1 aws ssm get-command-invocation --command-id $$CMD_ID --instance-id i-003b293d36c02e0cd --query 'Status' --output text 2>/dev/null)" != "InProgress" ]; do sleep 5; done; \
	  echo "$$f.json uploaded"; \
	done
	@# Step 5: Create empty logs file
	@CMD_ID=$$(AWS_DEFAULT_REGION=us-east-1 aws ssm send-command \
	  --instance-ids i-003b293d36c02e0cd \
	  --document-name "AWS-RunShellScript" \
	  --timeout-seconds 30 \
	  --parameters "commands=[\"echo '' > /var/www/html/api/logs/current.txt\"]" \
	  --query 'Command.CommandId' --output text); \
	until [ "$$(AWS_DEFAULT_REGION=us-east-1 aws ssm get-command-invocation --command-id $$CMD_ID --instance-id i-003b293d36c02e0cd --query 'Status' --output text 2>/dev/null)" != "InProgress" ]; do sleep 5; done
	@echo "Dashboard deployed to http://100.26.134.124/"
