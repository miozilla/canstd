#!/bin/bash
# setup initials
gcloud config set project "PROJECT_ID"
gcloud config set compute/region "REGION"
gcloud config set compute/zone "ZONE"
gcloud services enable compute.googleapis.com container.googleapis.com iap.googleapis.com
# Create VPC Network & Subnet
gcloud compute networks create test-vpc --subnet-mode=custom
gcloud compute networks subnets create test-subnet-us --network=test-vpc --region="REGION" --range=10.10.10.0/24
gcloud compute firewall-rules create allow-iap-ssh \
  --direction=INGRESS \
  --priority=1000 \
  --network=test-vpc \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20 \
  --target-tags=iap-gce
gcloud compute firewall-rules create allow-http \
    --direction=INGRESS \
    --priority=1500 \
    --network=test-vpc \
    --allow=tcp:80,tcp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=http-server,https-server
# Implement Backend Service with Health checks
gcloud compute health-checks create http health-check-http \
    --port=80
gcloud compute backend-services create backend-service \
    --health-checks=health-check-http \
    --global
# Create Instance Template & Managed Instance Group
gcloud compute instance-templates create backend-template \
  --machine-type=e2-medium \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --subnet=test-subnet-us \
  --tags=http-server,https-server,iap-gce \
  --metadata=startup-script='#! /bin/bash
    apt-get update
    apt-get install -y apache2 php libapache2-mod-php
    a2ensite default-ssl
    a2enmod ssl
    systemctl restart apache2
    rm /var/www/html/index.html
    echo "
<p>Query string: <!--?php echo \$_SERVER['QUERY_STRING']; ?--></p>" > /var/www/html/index.php
    systemctl restart apache2'
gcloud compute instance-groups managed create backend-mig \
  --base-instance-name=backend-vm \
  --size=2 \
  --template=backend-template \
  --zone="ZONE"
gcloud compute backend-services add-backend backend-service \
  --instance-group=backend-mig \
  --instance-group-zone="ZONE" \
  --global
# Create frontend config
gcloud compute url-maps create url-map \
    --default-service=backend-service
gcloud compute target-http-proxies create http-proxy \
  --url-map=url-map
gcloud compute addresses create global-ip-address --global
gcloud compute forwarding-rules create http-forwarding-rule \
  --address=$(gcloud compute addresses describe global-ip-address \
  --global --format='value(address)') \
  --global \
  --target-http-proxy=http-proxy \
  --ports=80
# Direct Cross-Site Scripting (XSS) / SQL Injection (SQLi) Attacks
gcloud compute instances create test-instance \
  --subnet=test-subnet-us \
  --machine-type=e2-medium \
  --tags=http-server,iap-gce \
  --zone="ZONE" \
  --metadata=startup-script='#! /bin/bash
    apt-get update
    apt-get install -y apache2 php libapache2-mod-php
    a2ensite default-ssl
    a2enmod ssl
    systemctl restart apache2
    rm /var/www/html/index.html
    echo "
<p>Query string: <!--?php echo $_SERVER['QUERY_STRING']; ?--></p>" > /var/www/html/index.php
    systemctl restart apache2'
TEST_IP=$(gcloud compute instances describe test-instance --zone="ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)') && echo $TEST_IP
# Test XSS attack
curl -v -G $TEST_IP  --data-urlencode "q=<script>alert('Cloud Armor is now enabled')</script>"
# Test SQLi attack
curl -v -G $TEST_IP --data-urlencode "q=1%27%20OR%20%271%27%3D%271%27--%20"
# Enable Cloud Armor threat protection
gcloud compute security-policies create "threat-policy" \
    --description="Blocks traffic from potential threats"
gcloud compute security-policies rules create 1 \
  --security-policy="threat-policy" \
  --description="Block XSS and SQLi attacks" \
  --expression="evaluatePreconfiguredExpr('xss-stable') || evaluatePreconfiguredExpr('sqli-stable')" \
  --action=deny-403
gcloud compute backend-services update backend-service \
  --security-policy="threat-policy" \
  --global
gcloud compute backend-services describe backend-service --global | grep securityPolicy
# Test the Protected Load Balancer
BACKEND_IP=$(gcloud compute addresses describe global-ip-address --global --format='value(address)') && echo $BACKEND_IP
sleep 60 # Policy rollout can take upto 10 minutes to propagate
# retest
curl -v -G $BACKEND_IP  --data-urlencode "q=<script>alert('Cloud Armor is now enabled')</script>"
curl -v -G $BACKEND_IP --data-urlencode "q=1%27%20OR%20%271%27%3D%271%27--%20"
#
echo "Exercise Completed: Configured Cloud Armor to detect common web application attacks"
