#!/bin/bash
# User must run the script as root
if [[ $EUID -ne 0 ]]; then
	echo "Please run this script as root"
	exit 1
fi
distro=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
# This function installs v2fly executables and creates an empty config
function install_v2fly {
	# At first install some stuff needed for this script
	apt update
	apt -y install jq curl wget unzip moreutils
	# Now download the latest v2fly executable
	# For that we need to get user's architecture
	local arch
	arch=$(uname -m)
	case $arch in
	"i386" | "i686") arch=1 ;;
	"x86_64") arch=2 ;;
	esac
	echo "1) 32-bit"
	echo "2) 64-bit"
	echo "3) arm-v5"
	echo "4) arm-v6"
	echo "5) arm-v7a"
	echo "6) arm-v8a"
	read -r -p "Select your architecture: " -e -i $arch arch
	case $arch in
	1) arch="32" ;;
	2) arch="64" ;;
	3) arch="arm32-v5" ;;
	4) arch="arm32-v6" ;;
	5) arch="arm32-v7a" ;;
	6) arch="arm64-v8a" ;;
	*)
		echo "$(tput setaf 1)Error:$(tput sgr 0) Invalid option"
		exit 1
		;;
	esac
	# Now download the executable
	local url
	url=$(wget -q -O- https://api.github.com/repos/v2fly/v2ray-core/releases/latest | jq --arg v "v2ray-linux-$arch.zip" -r '.assets[] | select(.name == $v) | .browser_download_url')
	wget -O v2fly.zip "$url"
	unzip v2fly.zip v2ray -d /usr/local/bin/
	# Create the config file
	mkdir /usr/local/etc/v2ray
	echo '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}' > /usr/local/etc/v2ray/config.json
	# Create the config file but dont start it
	unzip -p v2fly.zip systemd/system/v2ray.service > /etc/systemd/system/v2ray.service
	systemctl daemon-reload
	systemctl enable v2ray
	# Cleanup
	rm v2fly.zip
}

# Uninstalls v2ray and service
function uninstall_v2fly {
	# Remove firewall rules
	local to_remove_ports
	to_remove_ports=$(jq '.inbounds[] | select(.listen != "127.0.0.1") | .port' /usr/local/etc/v2ray/config.json)
	while read -r port; do
		if [[ $distro =~ "Ubuntu" ]]; then
			ufw delete allow "$port"/tcp
		elif [[ $distro =~ "Debian" ]]; then
			iptables -D INPUT -p tcp --dport "$port" --jump ACCEPT
			iptables-save >/etc/iptables/rules.v4
		fi
	done <<< "$to_remove_ports"
	# Stop and remove the service and files
	systemctl stop v2ray
	systemctl disable v2ray
	rm /usr/local/bin/v2ray /etc/systemd/system/v2ray.service
	rm -r /usr/local/etc/v2ray
	systemctl daemon-reload
}

# Returns the v2ray tls configuration.
# Generates tls certs or gets them from disk.
# Returns the TlsObject as TLS_SETTINGS variable.
function get_tls_config {
	# Get server name
	local servername
	read -r -p "Select your servername: " -e servername
	# Get cert
	local option certificate
	echo "	1) I already have certificate and private key"
	echo "	2) Create certificate and private key for me"
	read -r -p "What do you want to do? (select by number) " -e option
	case $option in
	1)
		local cert key
		read -r -p "Enter the path to your cert file: " -e cert
		read -r -p "Enter the path to your key file: " -e key
		certificate=$(jq -nc --arg cert "$cert" --arg key "$key" '{certificateFile: $cert, keyFile: $key}')
		;;
	2) certificate=$(v2ray tls cert --domain "$servername") ;;
	*)
		echo "$(tput setaf 1)Error:$(tput sgr 0) Invalid option"
		exit 1
		;;
	esac
	# Generate the config
	TLS_SETTINGS=$(jq -c --arg servername "$servername" '{serverName: $servername, alpn: ["h2","http/1.1"], certificates: [.]}' <<< "$certificate")
}

# Checks if the port is in use in inbound rules of v2ray.
# First argument must be the port number to check.
# Returns 0 if it's in use otherwise 1
function is_port_in_use_inbound {
	jq --arg port "$1" -e '.inbounds[] | select(.port == $port) | length == 1' /usr/local/etc/v2ray/config.json > /dev/null
}

# This function will print all inbound configs of installed v2ray server
function print_inbound {
	echo "Currently configured inbounds:"
	local inbounds
	inbounds=$(jq -c .inbounds[] /usr/local/etc/v2ray/config.json)
	local i=1
	# Loop over all inbounds
	while read -r inbound; do
		local line
		# Protocol
		line=$(jq -r '.protocol' <<< "$inbound")
		line+=" + "
		# Transport
		line+=$(jq -r '.streamSettings.network' <<< "$inbound")
		# TLS
		if [[ $(jq -r '.streamSettings.security' <<< "$inbound") == "tls" ]]; then
			line+=" + TLS"
		fi
		# Listening port
		line+=" ("
		line+=$(jq -r '"Listening on " + .listen + ":" + (.port | tostring)' <<< "$inbound")
		line+=")"
		# Done
		echo "$i) $line"
		i=$((i+1))
	done <<< "$inbounds"
	echo
}

# Gets the options to setup shadowsocks server and sends back the raw json in
# PROTOCOL_CONFIG variable
function configure_shadowsocks_settings {
	# Ask about method
	local method
	echo "	1) aes-128-gcm"
	echo "	2) aes-256-gcm"
	echo "	3) chacha20-poly1305"
	echo "	4) none"
	read -r -p "Select encryption method for shadowsocks: " -e -i "1" method
	case $method in
	1) method="aes-128-gcm" ;;
	2) method="aes-256-gcm" ;;
	3) method="chacha20-poly1305" ;;
	4)
		method="none"
		echo "$(tput setaf 3)Warning!$(tput sgr 0) none method must be combined with an encrypted trasport like TLS."
		;;
	*)
		echo "$(tput setaf 1)Error:$(tput sgr 0) Invalid option"
		exit 1
		;;
	esac
	# Ask about password
	local password
	read -r -p "Enter a password for shadowsocks. Leave blank for a random password: " password
	if [ "$password" == "" ]; then
		password=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1) # https://gist.github.com/earthgecko/3089509
		echo "$password was chosen."
	fi
	# Create the config file
	PROTOCOL_CONFIG=$(jq -nc --arg method "$method" --arg password "$password" '{method: $method, password: $password}')
}


# Adds and removes users from a user set of vmess or vless.
# First argument must be the initial value of the config.
# Second argument must be either vless or vmess.
# The config result is returned in an variable called PROTOCOL_CONFIG
function manage_vmess_vless_users {
	local config=$1
	local option id email
	while true; do
		echo "	1) View clients"
		echo "	2) Add random ID to config"
		echo "	3) Add custom ID to config"
		echo "	4) Delete ID from config"
		echo "	*) Back"
		read -r -p "What do you want to do? (select by number) " -e option
		case $option in
		1)
			jq -r '.[] | .email + " (" + .id + ")"' <<< "$config"
			;;
		2)
			id=$(v2ray uuid)
			read -r -p "Choose an email for this user. It could be an arbitrary email: " -e email
			config=$(jq -c --arg id "$id" --arg email "$email" '.[. | length] |= . + {id: $id, email: $email}' <<< "$config")
			;;
		3)
			read -r -p "Enter your uuid: " -e id
			read -r -p "Choose an email for this user. It could be an arbitrary email: " -e email
			config=$(jq -c --arg id "$id" --arg email "$email" '.[. | length] |= . + {id: $id, email: $email}' <<< "$config")
			;;
		4)
			local i=1
			for line in $(jq -r '.[] | .email + " (" + .id + ")"' <<< "$config"); do
				echo "$i) $line"
				i=$((i+1))
			done
			read -r -p "Select an ID by it's index to remove it: " -e option
			config=$(jq -c --arg index "$option" 'del(.[$index | tonumber - 1])' <<< "$config")
			;;
		*)
			PROTOCOL_CONFIG=$(jq -c '{clients: .}' <<< "$config")
			if [[ "$2" == "vless" ]]; then
				PROTOCOL_CONFIG=$(jq -c '. += {"decryption": "none"}' <<< "$PROTOCOL_CONFIG")
			fi
			break
		esac
	done
}

# Adds an inbound rule to config file
function add_inbound_rule {
	# At first get the port of user
	local port
	local regex_number='^[0-9]+$'
	read -r -p "Select a port to proxy listen on it: " -e port
	if ! [[ $port =~ $regex_number ]]; then
		echo "$(tput setaf 1)Error:$(tput sgr 0) The port is not a valid number"
		exit 1
	fi
	if [ "$port" -gt 65535 ]; then
		echo "$(tput setaf 1)Error:$(tput sgr 0) Number must be less than 65536"
		exit 1
	fi
	# Check if the port is in use by another service of v2ray
	if is_port_in_use_inbound "$port"; then
		echo "$(tput setaf 1)Error:$(tput sgr 0) Port already in use"
		exit 1
	fi
	# Listen address
	local listen_address
	read -r -p "On what interface you want to listen?: " -e -i '0.0.0.0' listen_address
	# Get the service
	local protocol
	echo "	1) VMess"
	echo "	2) VLESS"
	echo "	3) Shadowsocks"
	echo "	4) SOCKS"
	read -r -p "Select your protocol: " -e protocol
	case $protocol in
	1)
		protocol="vmess"
		manage_vmess_vless_users "[]" "vmess"
		;;
	2)
		protocol="vless"
		manage_vmess_vless_users "[]" "vless"
		;;
	3)
		protocol="shadowsocks"
		configure_shadowsocks_settings
		;;
	4)
		local option username password
		read -r -p "Do you want use username and password? (y/n) " -e -i "n" option
		if [[ "$option" == "y" ]]; then
			# For now, we only support one username and password. I doubt someone uses my script
			# for setting up a socks server with v2ray.
			read -r -p "Select a username: " -e username
			read -r -p "Select a password: " -e password
			PROTOCOL_CONFIG=$(jq -nc --arg user "$username" --arg pass "$password" '{auth:"password", accounts: [{user: $user, pass: $pass}]}')
		else
			PROTOCOL_CONFIG='{"auth":"noauth"}'
		fi
		;;
	*)
		echo "$(tput setaf 1)Error:$(tput sgr 0) Invalid option"
		exit 1
		;;
	esac
	# Get the transport
	local network ws_path grpc_service_name
	echo "	1) Raw TCP"
	echo "	2) TLS"
	echo "	3) Websocket"
	echo "	4) Websocket + TLS"
	echo "	5) gRPC"
	#echo "	6) mKCP" Later!
	read -r -p "Select your trasport: " -e network
	case $network in
	1) network='{"network":"tcp","security":"none"}' ;;
	2)
		get_tls_config
		network="{\"network\":\"tcp\",\"security\":\"tls\",\"tlsSettings\":$TLS_SETTINGS}"
		;;
	3)
		read -r -p "Select a path for websocket (do not use special characters execpt /): " -e -i '/' ws_path
		network="{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"$ws_path\"}}"
		;;
	4)
		get_tls_config
		read -r -p "Select a path for websocket (do not use special characters execpt /): " -e -i '/' ws_path
		network="{\"network\":\"ws\",\"security\":\"tls\",\"wsSettings\":{\"path\":\"$ws_path\"},\"tlsSettings\":$TLS_SETTINGS}"
		;;
	5)
		get_tls_certs
		read -r -p "Select a service name for gRPC (do not use special characters): " -e grpc_service_name
		network="{\"network\":\"gun\",\"security\":\"tls\",\"grpcSettings\":{\"serviceName\":\"$grpc_service_name\"},\"tlsSettings\":$TLS_SETTINGS}"
		;;
	*)
		echo "$(tput setaf 1)Error:$(tput sgr 0) Invalid option"
		exit 1
		;;
	esac
	# Finally, create the config chunk
	local inbound
	inbound=$(jq -cn --arg listen "$listen_address" --argjson port "$port" --arg protocol "$protocol" --argjson settings "$PROTOCOL_CONFIG" --argjson network "$network" '{listen: $listen, port: $port, protocol: $protocol, settings: $settings, streamSettings: $network}')
	jq --argjson v "$inbound" '.inbounds[.inbounds | length] |= $v' /usr/local/etc/v2ray/config.json | sponge /usr/local/etc/v2ray/config.json
	echo "Config added!"
	# Restart the server and add the rule to firewall
	systemctl restart v2ray
	if [[ "$listen_address" != "127.0.0.1" ]]; then
		if [[ $distro =~ "Ubuntu" ]]; then
			ufw allow "$port"/tcp
		elif [[ $distro =~ "Debian" ]]; then
			iptables -A INPUT -p tcp --dport "$port" --jump ACCEPT
			iptables-save >/etc/iptables/rules.v4
		fi
	fi
}

# Removes one inbound rule from configs
function remove_inbound_rule {
	local option port
	read -r -p "Select an inbound rule to remove by it's index: " -e option
	# Remove the firewall rule
	port=$(jq -r --arg index "$option" '.inbounds[$index | tonumber - 1].port')
	if [[ "$port" != "null" ]]; then
		if [[ $distro =~ "Ubuntu" ]]; then
			ufw delete allow "$port"/tcp
		elif [[ $distro =~ "Debian" ]]; then
			iptables -D INPUT -p tcp --dport "$port" --jump ACCEPT
			iptables-save >/etc/iptables/rules.v4
		fi
	fi
	# Change the config
	jq -c --arg index "$option" 'del(.inbounds[$index | tonumber - 1])' /usr/local/etc/v2ray/config.json | sponge /usr/local/etc/v2ray/config.json
	systemctl restart v2ray
}

# This function will act as a user manager for vless/vmess inbounds
function edit_v_config {
	# Ask user to choose from vless/vmess configs
	local option
	read -r -p "Select an vless/vmess rule to remove by it's index: " -e option
	# Check if it's vless/vmess
	local protocol
	protocol=$(jq -r --arg index "$option" '.inbounds[$index | tonumber - 1].protocol' /usr/local/etc/v2ray/config.json)
	if [[ "$protocol" != "vless" && "$protocol" != "vmess" ]]; then
		echo "$(tput setaf 1)Error:$(tput sgr 0) Selected inbound is not vless nor vmess"
		exit 1
	fi
	# Get the users array
	manage_vmess_vless_users "$(jq -c --arg index "$option" '.inbounds[$index | tonumber - 1].settings.clients' /usr/local/etc/v2ray/config.json)" "$protocol"
	jq --argjson protocol_config "$PROTOCOL_CONFIG" --arg index "$option" '.inbounds[$index | tonumber - 1] += {settings: $protocol_config}' /usr/local/etc/v2ray/config.json | sponge /usr/local/etc/v2ray/config.json
}

# Shows a menu to edit user
function main_menu {
	local option
	# Get current inbound stuff
	print_inbound
	# Main menu
	echo "What do you want to do?"
	echo "	1) Add rule"
	echo "	2) Edit VMess or VLess accounts"
	echo "	3) Delete rule"
	echo "	4) Uninstall v2fly"
	echo "	*) Exit"
	read -r -p "Please enter an option: " option
	case $option in
	1) add_inbound_rule ;;
	2) edit_v_config ;;
	3) remove_inbound_rule ;;
	4) uninstall_v2fly ;;
	esac
}

# Check if v2ray is installed
if [ ! -f /usr/local/etc/v2ray/config.json ]; then
	echo "It looks like that v2ray is not installed on your system."
	read -n 1 -s -r -p "Press any key to install it or Ctrl+C to cancel..."
	install_v2fly
fi

# Open main menu
clear
echo "V2Fly insatller script by Hirbod Behnam"
echo "Source at https://github.com/HirbodBehnam/V2Ray-Installer"
echo
main_menu