#!/usr/bin/env bash
EPS_BASE_URL=${EPS_BASE_URL:-}
EPS_OS_DISTRO=${EPS_OS_DISTRO:-}
EPS_UTILS_COMMON=${EPS_UTILS_COMMON:-}
EPS_UTILS_DISTRO=${EPS_UTILS_DISTRO:-}
EPS_APP_CONFIG=${EPS_APP_CONFIG:-}
EPS_CLEANUP=${EPS_CLEANUP:-false}
EPS_CT_INSTALL=${EPS_CT_INSTALL:-false}

if [ -z "$EPS_BASE_URL" -o -z "$EPS_OS_DISTRO" -o -z "$EPS_UTILS_COMMON" -o -z "$EPS_UTILS_DISTRO" -o -z "$EPS_APP_CONFIG" ]; then
  printf "Script looded incorrectly!\n\n";
  exit 1;
fi

source <(echo -n "$EPS_UTILS_COMMON")
source <(echo -n "$EPS_UTILS_DISTRO")
source <(echo -n "$EPS_APP_CONFIG")

pms_bootstrap
pms_settraps

if [ $EPS_CT_INSTALL = false ]; then
  pms_header
  pms_check_os
fi

EPS_OS_ARCH=$(os_arch)
EPS_OS_CODENAME=$(os_codename)
EPS_OS_VERSION=${EPS_OS_VERSION:-$(os_version)}

# Check for previous install
if [ -f "$EPS_SERVICE_FILE" ]; then
  step_start "Previous Installation" "Cleaning" "Cleaned"
    svc_stop npm
    svc_stop openresty

    # Remove old installation files
    rm -rf /app \
    /var/www/html \
    /etc/nginx \
    /var/log/nginx \
    /var/lib/nginx \
    /var/cache/nginx \
    /opt/certbot/bin/certbot
fi

step_start "Operating System" "Updating" "Updated"

step_start "Dependencies" "Installing" "Installed"
  # Remove potential conflicting depenedencies
  pkg_del nginx nodejs npm yarn *certbot rust* cargo*
  # Install required depenedencies
  pkg_add ca-certificates gnupg openssl apache2-utils logrotate $EPS_DEPENDENCIES

step_start "Rust" "Installing" "Installed"
  _rustArch=""
  _rustClibtype="gnu"
  
  if [ "$EPS_OS_DISTRO" = "alpine" ]; then
    _rustClibtype="musl"
  fi

  case "${EPS_OS_ARCH##*-}" in
    amd64 | x86_64) _rustArch="x86_64-unknown-linux-${_rustClibtype}";;
    arm64 | aarch64) _rustArch="aarch64-unknown-linux-${_rustClibtype}";;
    armhf) _rustArch="armv7-unknown-linux-gnueabihf";;
    i386 | x86) _rustArch="i686-unknown-linux-${_rustClibtype}";;
    *) step_end "Architecture not supported: ${CLR_CYB}$EPS_OS_ARCH${CLR}" 1;;
  esac

  if [ "$EPS_OS_DISTRO" = "alpine" ]; then
    if [ "$EPS_OS_ARCH" != "x86_64" -a "$EPS_OS_ARCH" != "aarch64" ]; then
      step_end "Architecture not supported: ${CLR_CYB}$EPS_OS_ARCH${CLR}" 1
    fi
  fi
  
  os_fetch -O ./rustup-init https://static.rust-lang.org/rustup/archive/1.26.0/$_rustArch/rustup-init
  chmod +x ./rustup-init
  ./rustup-init -q -y --no-modify-path --profile minimal --default-toolchain $RUST_VERSION --default-host $_rustArch &>$__OUTPUT
  rm ./rustup-init

  ln -sf ~/.cargo/bin/cargo /usr//bin/cargo
  ln -sf ~/.cargo/bin/rustc /usr/bin/rustc
  ln -sf ~/.cargo/bin/rustup /usr/bin/rustup

  step_end "Rust ${CLR_CYB}v$RUST_VERSION${CLR} ${CLR_GN}Installed"

step_start "Python"
  export PIP_ROOT_USER_ACTION=ignore
  # Remove old venv and global pip packages
  rm -rf /opt/certbot/ /usr/bin/certbot
  if [ "$(command -v pip)" ]; then
    pip uninstall -q -y cryptography cffi certbot tldextract --break-system-packages &>$__OUTPUT
  fi

  # Remove potential conflicting depenedencies
  pkg_del *3-pip *3-cffi *3-cryptography *3-tldextract *3-distutils *3-venv

  # Install python depenedencies
  pkg_add python3
  if [ "$EPS_OS_DISTRO" != "alpine" ]; then
    pkg_add python3-venv
  fi

  PYTHON_VERSION=$(python3 -V | sed 's/.* \([0-9]\).\([0-9]*\).*/\1.\2/')
  if printf "$PYTHON_VERSION\n3.2" | sort -cV &>/dev/null; then
    step_end "Python 3.2+ required, you currently have ${CLR_CYB}v$PYTHON_VERSION${CLR} installed" 1
  fi

  _pipGetScript="https://bootstrap.pypa.io/get-pip.py"
  if printf "$PYTHON_VERSION\n3.7" | sort -cV &>/dev/null; then
    _pipGetScript="https://bootstrap.pypa.io/pip/$PYTHON_VERSION/get-pip.py"
  fi
  
  # Setup venv and install pip packages in venv
  python3 -m venv /opt/certbot/
  . /opt/certbot/bin/activate
  os_fetch -O- $_pipGetScript | python3 >$__OUTPUT
  pip install -q -U --no-cache-dir cryptography cffi certbot tldextract
  PIP_VERSION=$(pip -V 2>&1 | grep -o 'pip [0-9.]* ' | awk '{print $2}')
  deactivate

  ln -sf /usr/bin/python3 /usr/bin/python
  ln -sf /opt/certbot/bin/pip /usr/bin/pip
  ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
  
  step_end "Python ${CLR_CYB}v$PYTHON_VERSION${CLR} ${CLR_GN}and Pip${CLR} ${CLR_CYB}v$PIP_VERSION${CLR} ${CLR_GN}Installed"

step_start "Openresty"
  if [ "$EPS_OS_DISTRO" = "alpine" ]; then
    os_fetch -O /etc/apk/keys/admin@openresty.com-5ea678a6.rsa.pub 'http://openresty.org/package/admin@openresty.com-5ea678a6.rsa.pub'
    sed -i '/openresty.org/d' /etc/apk/repositories >$__OUTPUT
    printf "http://openresty.org/package/alpine/v3.18/main"| tee -a /etc/apk/repositories >$__OUTPUT
  else
    os_fetch -O- https://openresty.org/package/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/openresty.gpg &>$__OUTPUT

    repository=http://openresty.org/package/$EPS_OS_DISTRO
    if [ "$EPS_OS_ARCH" != "amd64" ]; then
      repository=http://openresty.org/package/$EPS_OS_ARCH/$EPS_OS_DISTRO
    fi

    source="deb [arch=$EPS_OS_ARCH signed-by=/usr/share/keyrings/openresty.gpg] $repository $EPS_OS_CODENAME "
    if [ "$EPS_OS_DISTRO" = "debian" ]; then
      source+="openresty"
    else
      source+="main"
    fi
    printf "$source" | tee /etc/apt/sources.list.d/openresty.list >$__OUTPUT
  fi

  pkg_update
  pkg_add openresty
  ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
  ln -sf /usr/local/openresty/nginx/ /etc/nginx
  OPENRESTY_VERSION=$(openresty -v 2>&1 | grep -o '[0-9.]*$')
  step_end "Openresty ${CLR_CYB}v$OPENRESTY_VERSION${CLR} ${CLR_GN}Installed"

step_start "Node.js"
  _nodePackage=""
  _nodeArch=""
  _opensslArch="linux*"

apk add --no-cache curl xz tar
curl -fsSL https://unofficial-builds.nodejs.org/download/release/$NODE_VERSION/node-$NODE_VERSION-linux-x64-musl.tar.xz -o /tmp/node.tar.xz
tar -xJf /tmp/node.tar.xz -C /usr/ #--strip-components=1 --no-same-owner
ln -sf /usr/node-$NODE_VERSION-linux-x64-musl/bin/node /usr/bin/node
export PATH=/usr/bin:$PATH
node -v &>$__OUTPUT
find /usr/node-$NODE_VERSION-linux-x64-musl/include/node/openssl/archs -mindepth 1 -maxdepth 1 ! -name "$_opensslArch" -exec rm -rf {} \; >$__OUTPUT
 

  step_end "Node.js ${CLR_CYB}$NODE_VERSION${CLR} ${CLR_GN}Installed"

step_start "Yarn"
  export GNUPGHOME="$(mktemp -d)"
  for key in 6A010C5166006599AA17F08146C2130DFD2497F5; do
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$key" || gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key" ; &>$__OUTPUT
  done
  echo "$YARN_VERSION" &>$__OUTPUT
  os_fetch -O yarn-v$YARN_VERSION.tar.gz https://github.com/yarnpkg/yarn/releases/download/v$YARN_VERSION/yarn-v$YARN_VERSION.tar.gz
  os_fetch -O yarn-v$YARN_VERSION.tar.gz.asc https://github.com/yarnpkg/yarn/releases/download/v$YARN_VERSION/yarn-v$YARN_VERSION.tar.gz.asc
  gpgconf --kill all
  tar -xzf yarn-v$YARN_VERSION.tar.gz -C /opt/ &>$__OUTPUT
  ln -sf /opt/yarn-v$YARN_VERSION/bin/yarn /usr/local/bin/yarn &>$__OUTPUT
  ln -sf /opt/yarn-v$YARN_VERSION/bin/yarnpkg /usr/local/bin/yarnpkg &>$__OUTPUT
  rm -rf "$GNUPGHOME" yarn-v$YARN_VERSION.tar.gz.asc yarn-v$YARN_VERSION.tar.gz &>$__OUTPUT
  step_end "Yarn ${CLR_CYB}v$YARN_VERSION${CLR} ${CLR_GN}Installed"

step_start "Nginx Proxy Manager" "Downloading" "Downloaded"
  NPM_VERSION=$(os_fetch -O- https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')
echo $NPM_VERSION
NPM_VERSION="2.16.0"
echo $NPM_VERSION
 os_fetch -O- https://codeload.github.com/NginxProxyManager/nginx-proxy-manager/tar.gz/v$NPM_VERSION | tar -xz &>$__OUTPUT
 #https://github.com/rogitsundar-rgb/proxmox-scripts/releases/download/3/nginx-proxy-manager-2.16.0.tar.gz

cd *nginx-proxy-manager*
cd frontend/src/locale
#wget -O- https://github.com/rogitsundar-rgb/proxmox-scripts/releases/download/lang/lang.zip | gunzip ./
wget https://github.com/user-attachments/files/33315960/lang.zip 
unzip lang.zip
pwd
cd ../../../
pwd
  step_end "Nginx Proxy Manager ${CLR_CYB}v$NPM_VERSION${CLR} ${CLR_GN}Downloaded"

step_start "Enviroment" "Setting up" "Setup"
  # Update NPM version in package.json files
  sed -i "s/\"version\": \"0.0.0\"/\"version\": \"$NPM_VERSION\"/" backend/package.json
  sed -i "s/\"version\": \"0.0.0\"/\"version\": \"$NPM_VERSION\"/" frontend/package.json
  
  # Fix nginx config files for use with openresty defaults
  sed -i 's/user npm/user root/g; s/^pid/#pid/g; s+^daemon+#daemon+g' docker/rootfs/etc/nginx/nginx.conf
  sed -i 's/include-system-site-packages = false/include-system-site-packages = true/g' /opt/certbot/pyvenv.cfg
  _nginxConfigs=$(find ./ -type f -name "*.conf")
  for _nginxConfig in $_nginxConfigs; do
    sed -i 's+include conf.d+include /etc/nginx/conf.d+g' "$_nginxConfig"
  done

  # Copy runtime files
  mkdir -p /var/www/html /etc/nginx/logs
  cp -r docker/rootfs/var/www/html/* /var/www/html/
  cp -r docker/rootfs/etc/nginx/* /etc/nginx/
  cp docker/rootfs/etc/letsencrypt.ini /etc/letsencrypt.ini
  cp docker/rootfs/etc/logrotate.d/nginx-proxy-manager /etc/logrotate.d/nginx-proxy-manager
  ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf
  rm -f /etc/nginx/conf.d/dev.conf

  # Create required folders
  mkdir -p \
	/data/nginx \
	/data/custom_ssl \
	/data/logs \
	/data/access \
	/data/nginx/default_host \
	/data/nginx/default_www \
	/data/nginx/proxy_host \
	/data/nginx/redirection_host \
	/data/nginx/stream \
	/data/nginx/dead_host \
	/data/nginx/temp \
	/data/letsencrypt-acme-challenge \
	/run/nginx \
	/tmp/nginx/body \
	/var/log/nginx \
	/var/lib/nginx/cache/public \
	/var/lib/nginx/cache/private \
	/var/cache/nginx/proxy_temp

  # Set permissions
  touch /var/log/nginx/error.log
  chmod 777 /var/log/nginx/error.log
  chmod -R 777 /var/cache/nginx
  chmod 644 /etc/logrotate.d/nginx-proxy-manager
  chown root /tmp/nginx
  chmod -R 777 /var/cache/nginx

  # Dynamically generate resolvers file, if resolver is IPv6, enclose in `[]`
  echo resolver "$(awk 'BEGIN{ORS=" "} $1=="nameserver" { sub(/%.*$/,"",$2); print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf) valid=10s;" > /etc/nginx/conf.d/include/resolvers.conf

  # Copy app files
  mkdir -p /app/global /app/frontend/images
  cp -r backend/* /app
  #cp -r global/* /app/global

step_start "Frontend" "Building" "Built"
  cd ./frontend
  export NODE_ENV=development
  yarn cache clean --force  >$__OUTPUT
  yarn install  --network-timeout=30000 --verbose &>$__OUTPUT
  yarn build &>$__OUTPUT
  cp -r dist/* /app/frontend

step_start "Backend" "Initializing" "Initialized"
  rm -rf /app/config/default.json &>$__OUTPUT
  if [ ! -f /app/config/production.json ]; then
    _npmConfig="{\n  \"database\": {\n    \"engine\": \"knex-native\",\n    \"knex\": {\n      \"client\": \"sqlite3\",\n      \"connection\": {\n        \"filename\": \"/data/database.sqlite\"\n      }\n    }\n  }\n}"
    printf "$_npmConfig\n" | tee /app/config/production.json >$__OUTPUT
  fi
  cd /app
  export NODE_ENV=development
  yarn install --network-timeout=30000 -silent &>$__OUTPUT

ln -sf /usr/bin/node /usr/local/bin/node
step_start "Services" "Starting" "Started"
  printf "$EPS_SERVICE_DATA\n" | tee $EPS_SERVICE_FILE >$__OUTPUT
  chmod a+x $EPS_SERVICE_FILE
  svc_add openresty
  svc_add npm

step_start "Enviroment" "Cleaning" "Cleaned"
  yarn cache clean --silent --force >$__OUTPUT
  # find /tmp -mindepth 1 -maxdepth 1 -not -name nginx -exec rm -rf '{}' \;
  if [ "$EPS_CLEANUP" = true ]; then
    pkg_del "$EPS_DEPENDENCIES"
  fi
  pkg_clean

step_end "Installation complete"
printf "\nNginx Proxy Manager should be reachable at ${CLR_CYB}http://$(os_ip):81${CLR}\n\n"
