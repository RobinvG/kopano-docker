#!/bin/bash

ADDITIONAL_KOPANO_PACKAGES=${ADDITIONAL_KOPANO_PACKAGES:-""}
KCCONF_SERVER_MYSQL_SOCKET=${KCCONF_SERVER_MYSQL_SOCKET:-""}
DISABLE_CHECKS=${DISABLE_CHECKS:-false}
DISABLE_CONFIG_CHANGES=${DISABLE_CONFIG_CHANGES:-false}

set -eu # unset variables are errors & non-zero return values exit the whole script
[ "$DEBUG" ] && set -x

if [ ! -e /kopano/"$SERVICE_TO_START".py ]; then
	echo "Invalid service specified: $SERVICE_TO_START" | ts
	exit 1
fi

ADDITIONAL_KOPANO_PACKAGES=$(echo "$ADDITIONAL_KOPANO_PACKAGES" | tr -d '"')
[ -n "${ADDITIONAL_KOPANO_PACKAGES// }" ] && apt update
[ -n "${ADDITIONAL_KOPANO_PACKAGES// }" ] && for installpkg in $ADDITIONAL_KOPANO_PACKAGES; do
	# shellcheck disable=SC2016 disable=SC2086
	if [ "$(dpkg-query -W -f='${Status}' $installpkg 2>/dev/null | grep -c 'ok installed')" -eq 0 ]; then
		DEBIAN_FRONTEND=noninteractive apt --assume-yes --no-upgrade install "$installpkg"
	else
		echo "INFO: $installpkg is already installed"
	fi
done

mkdir -p /kopano/data/attachments /kopano/data/kapi-kvs /tmp/"$SERVICE_TO_START" /var/run/kopano /var/lib/kopano-grapi

if [ "${DISABLE_CONFIG_CHANGES}" == false ]; then
	echo "Configure core service '$SERVICE_TO_START'" | ts
	/usr/bin/python3 /kopano/"$SERVICE_TO_START".py
fi

# ensure removed pid-file on unclean shutdowns and mounted volumes
rm -f /var/run/kopano/"$SERVICE_TO_START".pid

echo "Set ownership" | ts
chown kopano:kopano /kopano/data/ /kopano/data/attachments 
chown kapi:kopano /var/lib/kopano-grapi

# allow helper commands given by "docker-compose run"
if [ $# -gt 0 ]; then
	exec "$@"
	exit
fi

# services need to be aware of the machine-id
if [[ "$DISABLE_CHECKS" == false  ]]; then
	dockerize \
		-wait file:///etc/machine-id \
		-wait file:///var/lib/dbus/machine-id
fi
# start regular service
case "$SERVICE_TO_START" in
server)
	# TODO this could check if the desired locale already exists before calling sed
	KCCONF_ADMIN_DEFAULT_STORE_LOCALE=${KCCONF_ADMIN_DEFAULT_STORE_LOCALE:-"en_US.UTF-8"}
	# get locales from env
	# shellcheck disable=SC1004
	sed --regexp-extended --expression='

		1  {
			i\
# This file lists locales that you wish to have built. You can find a list\
# of valid supported locales at /usr/share/i18n/SUPPORTED, and you can add\
# user defined locales to /usr/local/share/i18n/SUPPORTED. If you change\
# this file, you need to rerun locale-gen.\
\


			}

		/^('"$KCCONF_ADMIN_DEFAULT_STORE_LOCALE"')(_[[:upper:]]+)?(\.UTF-8)?(@[^[:space:]]+)?[[:space:]]+UTF-8$/!   s/^/# /
	' /usr/share/i18n/SUPPORTED >  /etc/locale.gen
	# make sure that en_US and de_DE are always there
	sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
	sed -i -e 's/# de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen
	dpkg-reconfigure --frontend=noninteractive locales

	# determine db connection mode (unix vs. network socket)
	if [ -n "$KCCONF_SERVER_MYSQL_SOCKET" ]; then
		DB_CONN="file://$KCCONF_SERVER_MYSQL_SOCKET"
	else
		DB_CONN="tcp://$KCCONF_SERVER_MYSQL_HOST:$KCCONF_SERVER_MYSQL_PORT"
	fi
	if [[ "$DISABLE_CHECKS" == false ]]; then
		dockerize \
			-wait file://"$KCCONF_SERVER_SERVER_SSL_CA_FILE" \
			-wait file://"$KCCONF_SERVER_SERVER_SSL_KEY_FILE" \
			-wait "$DB_CONN" \
			-timeout 360s
	fi
	# pre populate database
	coreversion=$(dpkg-query --showformat='${Version}' --show kopano-server)
	if dpkg --compare-versions "$coreversion" "gt" "8.7.84"; then
		kopano-dbadm populate
	fi
	# cleaning up env variables
	unset "${!KCCONF_@}"
	exec /usr/sbin/kopano-server -F
	;;
dagent)
	dockerize \
		-wait file:///var/run/kopano/server.sock \
		-timeout 360s
	# cleaning up env variables
	unset "${!KCCONF_@}"
	exec /usr/sbin/kopano-dagent -l
	;;
gateway)
	dockerize \
		-wait tcp://kopano_server:236 \
		-timeout 360s
	# cleaning up env variables
	unset "${!KCCONF_@}"
	exec /usr/sbin/kopano-gateway -F
	;;
ical)
	dockerize \
		-wait tcp://kopano_server:236 \
		-timeout 360s
	# cleaning up env variables
	unset "${!KCCONF_@}"
	exec /usr/sbin/kopano-ical -F
	;;
grapi)
	LC_CTYPE=en_US.UTF-8
	export socket_path=/var/run/kopano/grapi
	mkdir -p "$socket_path"
	chown -R kapi:kopano "$socket_path"
	# TODO there could be a case where multiple backends are desired
	case $GRAPI_BACKEND in
	ldap)
		[ -n "$KCCONF_GRAPI_LDAP_URI" ] && export LDAP_URI="${KCCONF_GRAPI_LDAP_URI}"
		[ -n "$KCCONF_GRAPI_LDAP_BASEDN" ] && export LDAP_BASEDN="${KCCONF_GRAPI_LDAP_BASEDN}"
		[ -n "$KCCONF_GRAPI_LDAP_BINDDN" ] && export LDAP_BINDDN="${KCCONF_GRAPI_LDAP_BINDDN}"
		if [ -n "$KCCONF_GRAPI_LDAP_BINDPW_FILE" ]; then
			bindpw="$(cat "${KCCONF_GRAPI_LDAP_BINDPW_FILE}")"
			export LDAP_BINDPW="${bindpw}"
		fi
		;;
	esac
	sed s/\ *=\ */=/g /etc/kopano/grapi.cfg > /tmp/grapi-env
	# shellcheck disable=SC2046
	export $(grep -v '^#' /tmp/grapi-env | xargs -d '\n')
	# cleaning up env variables
	unset "${!KCCONF_@}"
	# the backend option is only available in more recent versions of grapi
	grapiversion=$(dpkg-query --showformat='${Version}' --show kopano-grapi)
	if dpkg --compare-versions "$grapiversion" "gt" "10.0.0"; then
		exec kopano-grapi serve --backend="$GRAPI_BACKEND"
	else
		exec kopano-grapi serve
	fi
	;;
kapi)
	if [ "$KCCONF_KAPID_INSECURE" = "yes" ]; then
		dockerize \
		-skip-tls-verify \
		-wait file:///var/run/kopano/grapi/notify.sock \
		-wait "$KCCONF_KAPID_OIDC_ISSUER_IDENTIFIER"/.well-known/openid-configuration \
		-timeout 360s
	else
		dockerize \
		-wait file:///var/run/kopano/grapi/notify.sock \
		-wait "$KCCONF_KAPID_OIDC_ISSUER_IDENTIFIER"/.well-known/openid-configuration \
		-timeout 360s
	fi
	LC_CTYPE=en_US.UTF-8
	sed s/\ *=\ */=/g /etc/kopano/kapid.cfg > /tmp/kapid-env
	# shellcheck disable=SC2046
	export $(grep -v '^#' /tmp/kapid-env | xargs -d '\n')
	kopano-kapid setup
	# cleaning up env variables
	unset "${!KCCONF_@}"
	exec kopano-kapid serve --log-timestamp=false
	;;
monitor)
	dockerize \
		-wait file:///var/run/kopano/server.sock \
		-timeout 360s
	# cleaning up env variables
	unset "${!KCCONF_@}"
	exec /usr/sbin/kopano-monitor -F
	;;
search)
	dockerize \
		-wait file:///var/run/kopano/server.sock \
		-timeout 360s
	# give kopano-server a moment to settler before starting search
	sleep 5
	# cleaning up env variables
	unset "${!KCCONF_@}"
	# with commit 702bb3fccb3 search does not need -F any longer
	searchversion=$(dpkg-query --showformat='${Version}' --show kopano-search)
	if dpkg --compare-versions "$searchversion" "gt" "8.7.82.165"; then
		exec /usr/sbin/kopano-search
	else
		exec /usr/bin/python3 /usr/sbin/kopano-search -F
	fi
	;;
spooler)
	dockerize \
		-wait file:///var/run/kopano/server.sock \
		-wait tcp://"$KCCONF_SPOOLER_SMTP_SERVER":25 \
		-timeout 1080s
	# cleaning up env variables
	unset "${!KCCONF_@}"
	exec /usr/sbin/kopano-spooler -F
	;;
*)
	echo "Failed to start: Unknown service name: '$SERVICE_TO_START'" | ts
	exit 1
esac
