You can copy and paste the script directly into your AlmaLinux/RHEL machine, but I recommend saving it as a .sh file and then running it. This makes it easier to troubleshoot if anything fails.

 # create a script file
vi install-sonarqube.sh

Press i to enter insert mode, then paste the complete script I gav

#!/bin/bash

set -e

echo "=============================================="
echo " SonarQube + PostgreSQL + Nginx Installation"
echo " AlmaLinux / RHEL"
echo "=============================================="

# ============================================================
# VARIABLES
# ============================================================

SONAR_VERSION="26.4.0.121862"
SONAR_USER="sonar"
SONAR_DB="sonarqube"
SONAR_DB_USER="sonar"
SONAR_DB_PASSWORD="admin123"

SONAR_DIR="/opt/sonarqube"

echo ""
echo "Starting installation..."
echo ""

# ============================================================
# CHECK ROOT
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run this script as root."
    echo "Example: sudo bash install-sonarqube.sh"
    exit 1
fi

# ============================================================
# OS CHECK
# ============================================================

echo "Checking operating system..."

cat /etc/redhat-release

# ============================================================
# SYSTEM UPDATE
# ============================================================

echo ""
echo "Updating system packages..."

dnf update -y

# ============================================================
# REQUIRED PACKAGES
# ============================================================

echo ""
echo "Installing required packages..."

dnf install -y \
    wget \
    curl \
    unzip \
    zip \
    tar \
    gzip \
    vim \
    nano \
    net-tools \
    lsof \
    firewalld \
    policycoreutils-python-utils \
    java-21-openjdk \
    java-21-openjdk-devel

# ============================================================
# JAVA
# ============================================================

echo ""
echo "Checking Java..."

java -version

JAVA_PATH=$(readlink -f "$(which java)" | sed 's#/bin/java##')

echo "JAVA_HOME = $JAVA_PATH"

cat <<EOF > /etc/profile.d/java.sh
export JAVA_HOME=$JAVA_PATH
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

chmod 644 /etc/profile.d/java.sh

export JAVA_HOME="$JAVA_PATH"
export PATH="$JAVA_HOME/bin:$PATH"

# ============================================================
# KERNEL PARAMETERS
# ============================================================

echo ""
echo "Configuring kernel parameters..."

if [ -f /etc/sysctl.conf ]; then
    cp /etc/sysctl.conf /root/sysctl.conf_backup_$(date +%Y%m%d_%H%M%S)
fi

cat <<EOF > /etc/sysctl.d/99-sonarqube.conf
vm.max_map_count=524288
fs.file-max=65536
EOF

sysctl --system

# ============================================================
# USER LIMITS
# ============================================================

echo ""
echo "Configuring SonarQube user limits..."

if [ -f /etc/security/limits.conf ]; then
    cp /etc/security/limits.conf /root/sec_limit.conf_backup_$(date +%Y%m%d_%H%M%S)
fi

cat <<EOF > /etc/security/limits.d/sonarqube.conf
sonar   -   nofile   65536
sonar   -   nproc    4096
EOF

# ============================================================
# POSTGRESQL REPOSITORY
# ============================================================

echo ""
echo "Installing PostgreSQL..."

dnf install -y postgresql-server postgresql-contrib

# Initialize database if not already initialized

if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
    echo "Initializing PostgreSQL..."
    postgresql-setup --initdb
fi

systemctl enable --now postgresql

echo ""
echo "PostgreSQL status:"
systemctl --no-pager status postgresql

# ============================================================
# CREATE POSTGRESQL USER AND DATABASE
# ============================================================

echo ""
echo "Creating SonarQube PostgreSQL database..."

sudo -u postgres psql <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_catalog.pg_roles
        WHERE rolname = '${SONAR_DB_USER}'
    ) THEN
        CREATE ROLE ${SONAR_DB_USER} LOGIN PASSWORD '${SONAR_DB_PASSWORD}';
    ELSE
        ALTER ROLE ${SONAR_DB_USER} WITH LOGIN PASSWORD '${SONAR_DB_PASSWORD}';
    END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${SONAR_DB} OWNER ${SONAR_DB_USER}'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = '${SONAR_DB}'
)\gexec

GRANT ALL PRIVILEGES ON DATABASE ${SONAR_DB} TO ${SONAR_DB_USER};
EOF

systemctl restart postgresql

echo ""
echo "Testing PostgreSQL connection..."

PGPASSWORD="$SONAR_DB_PASSWORD" \
psql -h 127.0.0.1 \
     -U "$SONAR_DB_USER" \
     -d "$SONAR_DB" \
     -c "SELECT version();"

# ============================================================
# CREATE SONARQUBE USER
# ============================================================

echo ""
echo "Creating SonarQube Linux user..."

if ! getent group "$SONAR_USER" > /dev/null; then
    groupadd "$SONAR_USER"
fi

if ! id "$SONAR_USER" > /dev/null 2>&1; then
    useradd \
        -c "SonarQube User" \
        -d "$SONAR_DIR" \
        -g "$SONAR_USER" \
        -s /bin/bash \
        "$SONAR_USER"
fi

# ============================================================
# DOWNLOAD SONARQUBE
# ============================================================

echo ""
echo "Downloading SonarQube ${SONAR_VERSION}..."

mkdir -p /sonarqube

cd /sonarqube

SONAR_ZIP="sonarqube-${SONAR_VERSION}.zip"

if [ ! -f "$SONAR_ZIP" ]; then

    curl -fL \
        -o "$SONAR_ZIP" \
        "https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ZIP}"

fi

# ============================================================
# INSTALL SONARQUBE
# ============================================================

echo ""
echo "Installing SonarQube..."

rm -rf /opt/sonarqube-${SONAR_VERSION}

unzip -o "$SONAR_ZIP" -d /opt/

rm -rf "$SONAR_DIR"

mv "/opt/sonarqube-${SONAR_VERSION}" "$SONAR_DIR"

chown -R "$SONAR_USER:$SONAR_USER" "$SONAR_DIR"

# ============================================================
# SONARQUBE CONFIGURATION
# ============================================================

echo ""
echo "Configuring sonar.properties..."

cp \
    "$SONAR_DIR/conf/sonar.properties" \
    "/root/sonar.properties_backup_$(date +%Y%m%d_%H%M%S)"

cat <<EOF > "$SONAR_DIR/conf/sonar.properties"

# ============================================================
# PostgreSQL Database
# ============================================================

sonar.jdbc.username=${SONAR_DB_USER}
sonar.jdbc.password=${SONAR_DB_PASSWORD}
sonar.jdbc.url=jdbc:postgresql://127.0.0.1:5432/${SONAR_DB}

# ============================================================
# SonarQube Web Server
# ============================================================

sonar.web.host=0.0.0.0
sonar.web.port=9000

# ============================================================
# Java Memory
# ============================================================

sonar.web.javaOpts=-Xms512m -Xmx1024m
sonar.search.javaOpts=-Xms512m -Xmx512m

# ============================================================
# Logs
# ============================================================

sonar.log.level=INFO

EOF

chown "$SONAR_USER:$SONAR_USER" "$SONAR_DIR/conf/sonar.properties"

# ============================================================
# SYSTEMD SERVICE
# ============================================================

echo ""
echo "Creating SonarQube systemd service..."

cat <<EOF > /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=forking

User=${SONAR_USER}
Group=${SONAR_USER}

ExecStart=${SONAR_DIR}/bin/linux-x86-64/sonar.sh start
ExecStop=${SONAR_DIR}/bin/linux-x86-64/sonar.sh stop

Restart=always
RestartSec=10

LimitNOFILE=65536
LimitNPROC=4096

TimeoutStartSec=300
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable sonarqube

# ============================================================
# SELINUX
# ============================================================

echo ""
echo "Checking SELinux..."

getenforce || true

# ============================================================
# FIREWALL
# ============================================================

echo ""
echo "Configuring firewalld..."

systemctl enable --now firewalld

firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-port=9000/tcp

firewall-cmd --reload

# ============================================================
# START SONARQUBE
# ============================================================

echo ""
echo "Starting SonarQube..."

systemctl start sonarqube

sleep 15

echo ""
echo "SonarQube service status:"

systemctl --no-pager status sonarqube

# ============================================================
# INSTALL NGINX
# ============================================================

echo ""
echo "Installing Nginx..."

dnf install -y nginx

systemctl enable nginx

# ============================================================
# NGINX CONFIGURATION
# ============================================================

echo ""
echo "Configuring Nginx reverse proxy..."

rm -f /etc/nginx/conf.d/default.conf

cat <<'EOF' > /etc/nginx/conf.d/sonarqube.conf

server {

    listen 80;
    server_name sonarqube.groophy.in;

    access_log /var/log/nginx/sonar.access.log;
    error_log /var/log/nginx/sonar.error.log;

    proxy_buffers 16 64k;
    proxy_buffer_size 128k;

    location / {

        proxy_pass http://127.0.0.1:9000;

        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;

        proxy_redirect off;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;

        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}

EOF

# ============================================================
# NGINX CONFIG TEST
# ============================================================

echo ""
echo "Testing Nginx configuration..."

nginx -t

# ============================================================
# START NGINX
# ============================================================

echo ""
echo "Starting Nginx..."

systemctl restart nginx

# ============================================================
# FIREWALL HTTP
# ============================================================

firewall-cmd --permanent --add-service=http
firewall-cmd --reload

# ============================================================
# CHECK SERVICES
# ============================================================

echo ""
echo "=============================================="
echo " Service Status"
echo "=============================================="

systemctl --no-pager --full status postgresql
systemctl --no-pager --full status sonarqube
systemctl --no-pager --full status nginx

# ============================================================
# PORT CHECK
# ============================================================

echo ""
echo "Listening ports:"

ss -lntp | grep -E ':80 |:9000 |:5432 ' || true

# ============================================================
# LOCAL TEST
# ============================================================

echo ""
echo "Testing SonarQube locally..."

curl -I http://127.0.0.1:9000 || true

echo ""
echo "=============================================="
echo " INSTALLATION COMPLETED"
echo "=============================================="

echo ""
echo "SonarQube URL:"
echo "http://YOUR_SERVER_IP/"
echo ""
echo "Direct SonarQube URL:"
echo "http://YOUR_SERVER_IP:9000/"
echo ""
echo "Nginx domain:"
echo "http://sonarqube.groophy.in/"
echo ""
echo "PostgreSQL database:"
echo "Database : ${SONAR_DB}"
echo "Username : ${SONAR_DB_USER}"
echo ""
echo "IMPORTANT:"
echo "1. Configure DNS sonarqube.groophy.in to your server IP."
echo "2. Change the database password after installation."
echo "3. Do not expose PostgreSQL port 5432 publicly."
echo "4. For production, configure HTTPS using SSL/TLS."
echo ""
echo "Installation finished."
:wq

*Now make it executable:
#chmod +x install-sonarqube.sh

*Run it:
#sudo ./install-sonarqube.sh
