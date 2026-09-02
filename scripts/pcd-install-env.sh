export DU_FQDN=pcd.rye.ninja
export TELEMETRY=false
export SKIP_RATING_PROMPT="true"
export ACCEPT_EULA="true"
export SHOULD_CLEANUP="true"
export ENABLE_K8S="false"
export USER_CERT_PATH=/etc/public-certs/pcd.pem
export USER_KEY_PATH=/etc/public-certs/pcd.key
export SKIP_PRECHECKS=true

curl -sfL https://go.pcd.run > /usr/bin/pcd-run.sh
chmod 755 /usr/bin/pcd-run.sh
/usr/bin/pcd-run.sh | tee /var/log/pcd-install.log
ln -s /opt/pf9/airctl/conf/airctl-config.yaml /root/airctl-config.yaml