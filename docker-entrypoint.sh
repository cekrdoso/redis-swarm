#!/bin/bash

REDIS_ROLE=${REDIS_ROLE:-"undefined"}
REDIS_MASTER_NAME=${REDIS_MASTER_NAME:-"mymaster"}
REDIS_PILOT_HOSTNAME=${REDIS_PILOT_HOSTNAME:-"redis-pilot"}
REDIS_REPLICA_COUNT=${REDIS_REPLICA_COUNT:-1}
REDIS_REPLICA_HOSTNAME=${REDIS_REPLICA_HOSTNAME:-"redis"}
REDIS_REPLICA_PORT=${REDIS_REPLICA_PORT:-6379}
REDIS_SENTINEL_COUNT=${REDIS_SENTINEL_COUNT:-3}
REDIS_SENTINEL_HOSTNAME=${REDIS_SENTINEL_HOSTNAME:-"redis-sentinel"}
REDIS_SENTINEL_PORT=${REDIS_SENTINEL_PORT:-26379}
REDIS_SENTINEL_WANT_QUORUM=${REDIS_SENTINEL_WANT_QUORUM:-"true"}

SENTINEL_QUORUM_COUNT=$(awk 'BEGIN{ printf "%d",('${REDIS_SENTINEL_COUNT}' * 0.5 + 1) }')
SELF_ADDRESS=$(getent hosts `hostname` | awk '{ print $1 }')

write_log() {
	local level=${1:-info}
	while IFS= read -r LINE; do
		if [ "${level}x" == "errx" ]; then
			echo "[${REDIS_ROLE}:${SELF_ADDRESS}] ${LINE}" >&2
		else
			echo "[${REDIS_ROLE}:${SELF_ADDRESS}] ${LINE}"
		fi
	done
}

write_err() {
	while IFS= read -r LINE; do
		echo "${LINE}" | write_log err
	done
}

get_bulk_value() {
	local iplist=( $1 ); shift
	local port=$1; shift
	local key=$1; shift
	local command=$@

	local value=null
	local value_list=()
	local c=0
	while [ $c -lt ${#iplist[@]} ]; do
		local v=$(redis-cli -h ${iplist[$c]} -p ${port} ${command} | grep -A1 ${key} | tail -1)
		if [ "${v}x" != "x" ]; then
			value_list[$c]="${v}"
		else
			echo null
			return 1
		fi
		c=$((c + 1))
	done
	echo "[get_bulk_value] value_list=${value_list[@]}" | write_err
	compare_values "${value_list[@]}" && echo ${value_list[0]} || echo null
}

compare_values() {
	local valuelist=( $1 )
	local c=0
	while [ $c -lt ${#valuelist[@]} ]; do
		value=${valuelist[$c]}

		[ $c -eq 0 ] && l_value=${value:-null}

		if [ "${value}x" != "${l_value}x" ]; then
			echo "[compare_values] values don't match: ${valuelist[@]}" | write_err
			return 1
		fi

		l_value=${value}
		c=$((c + 1))
	done
	echo "[compare_values] ok" | write_err
	return 0
}

find_sentinels() {
	local wait=3
	local r=10
	while [ $r -gt 0 ]; do
		# Get sentinels ips
		sentinels=( $(getent hosts tasks.${REDIS_SENTINEL_HOSTNAME} | awk '{ print $1 }') )

		local success=0
		for ip in ${sentinels[@]}; do
			if [ "${ip}x" == "${SELF_ADDRESS}x" ]; then
				continue
			fi

			if [ "$(redis-cli -h ${ip} -p ${REDIS_SENTINEL_PORT} ping)x" != "PONGx" ]; then
				success=0
				break
			fi

			success=1
			sleep 5
		done

		if [ $success -eq 1 ]; then
			echo "[find_sentinels] sentinels found: ${sentinels[@]}" | write_err
			echo ${sentinels[@]}
			return 0
		fi

		r=$((r - 1))
		sleep ${wait}
	done

	echo "[find_sentinels] sentinels found: null" | write_err
	echo null
	return 1
}

find_master() {
	local m=null
	local success=0
	for host in $REDIS_PILOT_HOSTNAME $REDIS_REPLICA_HOSTNAME; do
		echo "[find_master] host: ${host}" | write_err
		for l in $(getent hosts ${host} | awk '{ print $1 }'); do
			[ "${l}x" == "${SELF_ADDRESS}x" ] && continue
			echo "[find_master] checking master: ${l}" | write_err
			if check_master ${l}; then
				echo "[find_master] master found: ${l}" | write_err
				success=1
				m=${l}
				break
			fi
		done
		[ ${success} -eq 1 ] && break
	done
	echo "[find_master] master: ${m:-null}" | write_err
	echo ${m:-null}
}

check_master() {
	local m=$1
	local role=null
	retries=3
	while [ ${retries} -gt 0 ]; do
		echo "[check_master] checking: ${m}" | write_err
		role=$((redis-cli -h ${m} INFO replication 2>/dev/null || echo 'role:ERROR') | \
                    tr -d '\r' | awk -F : '/^role:/ { print $2 }')
		echo "[check_master] role: \"${role}\"" | write_err
		[ "${role}x" != "ERRORx" ] && break
		retries=$((retries - 1))
		sleep 3
	done
	[ "${role}x" == "masterx" ] && return 0 || return 1
}

check_quorum() {
	local iplist="$1"
	local port=${REDIS_SENTINEL_PORT}
	local command="SENTINEL ckquorum ${REDIS_MASTER_NAME}"

	if [ ${REDIS_SENTINEL_WANT_QUORUM} = "true" ]; then

		for ip in ${iplist}; do
			local v=$(redis-cli -h ${ip} -p ${port} ${command} 2>/dev/null | grep -e "^OK")
			if [ -z "${v}" ]; then
				echo "[check_quorum] quorum was not reached" | write_err
				return 1
			fi
		done
		echo "[check_quorum] quorum was reached" | write_err

	else
		echo "[check_quorum] sentinels quorum is not expected, ignoring." | write_err
	fi

	return 0
}

abort() {
	echo $1 | write_err
	exit 1
}

sentinel_ips=null

case $REDIS_ROLE in
	debug)
		while true; do
			echo "MASTER: $(find_master)" | write_log
			echo "SENTINELS: $(find_sentinels)" | write_log
			sleep 3
		done
	;;
	sentinel)

		# Find master
		retries=10
		master=null
		while [ ${retries} -gt 0 ]; do
			master=$(find_master)
			[ "${master}x" != "nullx" ] && break
			echo "could not find master, waiting..." | write_log
			retries=$((retries - 1))
			sleep 5
		done

		if [ "${master}x" == "nullx" ]; then
			abort "ERROR: Could not find master, exiting."
		fi

		cat <<-EOF > /tmp/sentinel.conf
			port ${REDIS_SENTINEL_PORT}
			sentinel monitor ${REDIS_MASTER_NAME} ${master} ${REDIS_REPLICA_PORT} ${SENTINEL_QUORUM_COUNT}
			sentinel down-after-milliseconds ${REDIS_MASTER_NAME} 5000
			sentinel failover-timeout ${REDIS_MASTER_NAME} 60000
			sentinel parallel-syncs ${REDIS_MASTER_NAME} 1
			EOF
		chown redis:redis /tmp/sentinel.conf
		exec gosu redis redis-server /tmp/sentinel.conf --sentinel
	;;
	pilot)
		# Check if a master already exist
		master=$(find_master)
		if [ "${master}x" != "nullx" ]; then
			echo "a master already exist: ${master}" | write_log
			sentinel_ips=$(find_sentinels)
			echo "sentinels are: ${sentinel_ips}" | write_log
			if [ "${sentinel_ips}x" != "nullx" ]; then
				if check_quorum "${sentinel_ips}"; then
					echo "quorum is ok" | write_log
				else
					echo "quorum is not ok." | write_log
				fi
				for ip in ${sentinel_ips}; do
					m=$(redis-cli -h ${ip} -p ${REDIS_SENTINEL_PORT} SENTINEL get-master-addr-by-name ${REDIS_MASTER_NAME} | head -1)
					echo "sentinel=${ip}, master=${m:-null}" | write_log
				done
			fi
			exit 0
		fi

		echo "starting redis-pilot..." | write_log
		rm -rf dump.rdb
		redis-server --port ${REDIS_REPLICA_PORT} &
		sleep 5

		while [ "$(redis-cli ping)x" != "PONGx" ]; do
			echo "waiting redis-pilot startup..." | write_log
			sleep 3
		done

		# Get sentinels ips
		while [ ${#sentinel_ips[@]} -lt ${REDIS_SENTINEL_COUNT} ]; do
			v=$(find_sentinels)
			[ "${v}x" != "nullx" ] && sentinel_ips=( ${v} )
		done
		sentinel_ips="${sentinel_ips[@]}"
		echo "sentinels: ${sentinel_ips}" | write_log

		# Check quorum
		if [ "${REDIS_SENTINEL_WANT_QUORUM}" = "true" ]; then

			retries=30
			while ! check_quorum "${sentinel_ips}" && [ ${retries} -gt 0 ]; do
				echo "waiting for sentinels to meet defined quorum..." | write_log
				retries=$((retries - 1))
				sleep 3
			done
			if [ ${retries} -eq 0 ]; then
				kill -9 `pidof redis-server`
				abort "ERROR: sentinels did not met quorum. Exiting."
			fi

		fi

		retries=30
		while [ ${retries} -gt 0 ]; do
			replica_list=()
			i=0
			while IFS= read -r LINE; do
				eval ${LINE//,/ }
				redis-cli -h ${ip} PING >/dev/null 2>&1
				if [ $? -eq 0 ]; then
					echo -n "pinging replica ${ip}... OK" | write_log
					replica_list[$i]=${ip}
					i=$((i + 1))
				else
					echo -n "pinging replica ${ip}... ERR" | write_log
				fi
				unset ip port state offset lag LINE
			done < <(redis-cli INFO replication | awk -F : '/^slave[0-9]/ { print $2 }')

			replica_count=${#replica_list[@]}

			if [ ${replica_count} -ge ${REDIS_REPLICA_COUNT} ]; then
				# Replicas are up
				break
			fi

			echo "waiting for all replicas to come up: ${replica_count:-0}/${REDIS_REPLICA_COUNT}" | write_log

			retries=$((retries - 1))
			sleep 1
		done
		if [ ${retries} -eq 0 ]; then
			kill -9 `pidof redis-server`
			abort "ERROR: replicas failed to come up. exiting."
		fi

		sleep 60
		echo "all replicas are up, forcing failover..." | write_log
		while ! \
			redis-cli -h ${REDIS_SENTINEL_HOSTNAME} -p ${REDIS_SENTINEL_PORT} SENTINEL failover ${REDIS_MASTER_NAME}; do
			sleep 3
		done
		sleep 60

		retries=10
		while [ ${retries} -gt 0 ]; do
			new_master=$(find_master)
			if [ "${new_master}x" != "nullx" -a ${new_master} != ${SELF_ADDRESS} ]; then
				echo "failover finished. new master is ${new_master}..." | write_log
				break
			else
				echo "waiting failover to finish..." | write_log
			fi
			retries=$((retries - 1))
			sleep 3
		done
		if [ ${retries} -eq 0 ]; then
			kill -9 `pidof redis-server`
			abort "ERROR: failover failed. Exiting."
		fi

		echo "shuting down redis-pilot instance:" | write_log
		redis-cli SHUTDOWN NOSAVE
		sleep 60

		echo "reseting sentinels:" | write_log
		for ip in ${sentinel_ips}; do
			redis-cli -h ${ip} -p ${REDIS_SENTINEL_PORT} SENTINEL RESET ${REDIS_MASTER_NAME}
		done

		echo "done." | write_log
	;;
	replica)
		# Find sentinels
		echo "searching sentinels..." | write_log
		sentinel_ips=$(find_sentinels)

		# Check quorum
		echo "checking quorum..." | write_log
		check_quorum "${sentinel_ips}"

		# Find master
		retries=10
		master=null
		echo "searching master..." | write_log
		while [ ${retries} -gt 0 ]; do
			master=$(find_master)
			echo "found master: ${master}" | write_log
			[ "${master}x" != "nullx" ] && break
			retries=$((retries - 1))
			sleep 5
		done

		echo "starting replica..." | write_log
		rm -rf dump.rdb
		exec gosu redis redis-server --port ${REDIS_REPLICA_PORT} --replicaof ${master} ${REDIS_REPLICA_PORT}
	;;
	*)
		echo "error: REDIS_ROLE must be one of: \"sentinel\" | \"pilot\" | \"replica\" | \"debug\""
		exit 1
	;;
esac

exit 0
