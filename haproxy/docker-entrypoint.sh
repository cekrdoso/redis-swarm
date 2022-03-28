#!/bin/sh
set -e

parse_cfg_template() {
    REDIS_REPLICA_HOSTNAME=${REDIS_REPLICA_HOSTNAME:-"redis"}
    REDIS_REPLICA_PORT=${REDIS_REPLICA_PORT:-6379}
	HAPROXY_SERVER_COUNT=${HAPROXY_SERVER_COUNT:-5}
    export REDIS_REPLICA_HOSTNAME REDIS_REPLICA_PORT HAPROXY_SERVER_COUNT
    envsubst < ${HAPROXY_CFG_TEMPLATE} > /usr/local/etc/haproxy/haproxy.cfg
}

# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
	parse_cfg_template
	set -- haproxy "$@"
fi

if [ "$1" = 'haproxy' ]; then
	parse_cfg_template
	shift # "haproxy"
	# if the user wants "haproxy", let's add a couple useful flags
	#   -W  -- "master-worker mode" (similar to the old "haproxy-systemd-wrapper"; allows for reload via "SIGUSR2")
	#   -db -- disables background mode
	set -- haproxy -W -db "$@"
fi

exec "$@"