#!/bin/bash

REDIS_ROLE=${REDIS_ROLE:-"undefined"}
SENTINEL_HOSTNAME=${SENTINEL_HOSTNAME:-"redis-sentinel"}
SENTINEL_PORT=${SENTINEL_PORT:-26379}
REDIS_MASTER_NAME=${REDIS_MASTER_NAME:-"mymaster"}
REDIS_MASTER_HOSTNAME=${REDIS_MASTER_HOSTNAME:-"redis-init"}
REDIS_REPLICAS_HOSTNAME=${REDIS_REPLICAS_HOSTNAME:-"redis"}
NUM_OF_SENTINELS=${NUM_OF_SENTINELS:-3}
NUM_OF_REPLICAS=${NUM_OF_REPLICAS:-1}
EXPECT_SENTINELS_QUORUM=${EXPECT_SENTINELS_QUORUM:-"true"}
SENTINELS_QUORUM=${SENTINELS_QUORUM:-$((NUM_OF_SENTINELS - 1))}

get_self_address() {
	local self_address=$(getent hosts `hostname` | awk '{ print $1 }')
	echo "[get_self_address] self_address=${self_address}" >&2
	echo ${self_address}
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
	echo "[get_bulk_value] value_list=${value_list[@]}" >&2
	compare_values "${value_list[@]}" && echo ${value_list[0]} || echo null
}

compare_values() {
	local valuelist=( $1 )
	local c=0
	while [ $c -lt ${#valuelist[@]} ]; do
		value=${valuelist[$c]}

		[ $c -eq 0 ] && l_value=${value:-null}

		if [ "${value}x" != "${l_value}x" ]; then
			echo "[compare_values] values don't match: ${valuelist[@]}" >&2
			return 1
		fi

		l_value=${value}
		c=$((c + 1))
	done
	echo "[compare_values] ok" >&2
	return 0
}

find_sentinels() {
	local wait=3
	local self=$(get_self_address)

	local r=10
	while [ $r -gt 0 ]; do
		# Get sentinels ips
		sentinels=( $(getent hosts tasks.${SENTINEL_HOSTNAME} | awk '{ print $1 }') )

		local success=0
		for ip in ${sentinels[@]}; do
			if [ "${ip}x" == "${self}x" ]; then
				continue
			fi

			if [ "$(redis-cli -h ${ip} -p ${SENTINEL_PORT} ping)x" != "PONGx" ]; then
				success=0
				break
			fi

			success=1
			sleep 5
		done

		if [ $success -eq 1 ]; then
			echo "[find_sentinels] sentinels found: ${sentinels[@]}" >&2
			echo ${sentinels[@]}
			return 0
		fi

		r=$((r - 1))
		sleep ${wait}
	done

	echo "[find_sentinels] sentinels found: null" >&2
	echo null
	return 1
}

find_master() {
	local m=null
	local success=0
	for host in $REDIS_MASTER_HOSTNAME $REDIS_REPLICAS_HOSTNAME; do
		echo "[find_master] host: ${host}" >&2
		for l in $(getent hosts ${host} | awk '{ print $1 }'); do
			[ "${l}x" == "${self_address}x" ] && continue
			echo "[find_master] checking master: ${l}" >&2
			if check_master ${l}; then
				echo "[find_master] master found: ${l}" >&2
				success=1
				m=${l}
				break
			fi
		done
		[ ${success} -eq 1 ] && break
	done
	echo "[find_master] master: ${m:-null}" >&2
	echo ${m:-null}
}

check_master() {
	local m=$1
	local role=null
	retries=3
	while [ ${retries} -gt 0 ]; do
		echo "[check_master] checking: ${m}" >&2
		role=$((redis-cli -h ${m} INFO replication 2>/dev/null || echo 'role:ERROR') | \
                    tr -d '\r' | awk -F : '/^role:/ { print $2 }')
		echo "[check_master] role: \"${role}\"" >&2
		[ "${role}x" != "ERRORx" ] && break
		retries=$((retries - 1))
		sleep 3
	done
	[ "${role}x" == "masterx" ] && return 0 || return 1
}

check_quorum() {
	local iplist="$1"
	local port=${SENTINEL_PORT}
	local command="SENTINEL ckquorum ${REDIS_MASTER_NAME}"

	if [ ${EXPECT_SENTINELS_QUORUM} = "true" ]; then

		for ip in ${iplist}; do
			local v=$(redis-cli -h ${ip} -p ${port} ${command} 2>/dev/null | grep -e "^OK")
			[ -z "${v}" ] && echo "[check_quorum] quorum was not reached" >&2 && return 1
		done
		echo "[check_quorum] quorum was reached" >&2

	else
		echo "[check_quorum] sentinels quorum is not expected, ignoring." >&2
	fi

	return 0
}

abort() {
	echo $1
	exit 1
}

self_address=$(get_self_address)
sentinel_ips=null

case $REDIS_ROLE in
	debug)
		while true; do
			echo "[debug] MASTER: $(find_master)"
			echo "[debug] SENTINELS: $(find_sentinels)"
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
			echo "[sentinel] could not find master, waiting..."
			retries=$((retries - 1))
			sleep 5
		done

		if [ "${master}x" == "nullx" ]; then
			abort "[sentinel] Error: Could not find master, exiting."
		fi

		cat <<-EOF > /tmp/sentinel.conf
			port 26379
			sentinel monitor ${REDIS_MASTER_NAME} ${master} 6379 ${SENTINELS_QUORUM}
			sentinel down-after-milliseconds ${REDIS_MASTER_NAME} 5000
			sentinel failover-timeout ${REDIS_MASTER_NAME} 60000
			sentinel parallel-syncs ${REDIS_MASTER_NAME} 1
			EOF
		chown redis:redis /tmp/sentinel.conf
		exec gosu redis redis-server /tmp/sentinel.conf --sentinel
	;;
	init)
		# Check if a master already exist
		master=$(find_master)
		if [ "${master}x" != "nullx" ]; then
			echo "[init] a master already exist: ${master}"
			sentinel_ips=$(find_sentinels)
			echo "[init] sentinels are: ${sentinel_ips}"
			if [ "${sentinel_ips}x" != "nullx" ]; then
				check_quorum "${sentinel_ips}" && \
					echo "[init] quorum is ok" || \
					echo "[init] quorum is not ok."
				for ip in ${sentinel_ips}; do
					m=$(redis-cli -h ${ip} -p ${SENTINEL_PORT} SENTINEL get-master-addr-by-name ${REDIS_MASTER_NAME} | head -1)
					echo "[init] sentinel=${ip}, master=${m:-null}"
				done
			fi
			exit 0
		fi

		echo "[init] starting redis-init..."
		rm -rf dump.rdb
		redis-server --port 6379 &
		sleep 5

		while [ "$(redis-cli ping)x" != "PONGx" ]; do
			echo "[init] waiting redis-init startup..."
			sleep 3
		done

		# Get sentinels ips
		while [ ${#sentinel_ips[@]} -lt ${NUM_OF_SENTINELS} ]; do
			v=$(find_sentinels)
			[ "${v}x" != "nullx" ] && sentinel_ips=( ${v} )
		done
		sentinel_ips="${sentinel_ips[@]}"
		echo "[init] sentinels: ${sentinel_ips}"

		# Check quorum
		if [ "${EXPECT_SENTINELS_QUORUM}" = "true" ]; then

			retries=30
			while ! check_quorum "${sentinel_ips}" && [ ${retries} -gt 0 ]; do
				echo "[init] waiting for sentinels to meet defined quorum..."
				retries=$((retries - 1))
				sleep 3
			done
			if [ ${retries} -eq 0 ]; then
				kill -9 `pidof redis-server`
				abort "[init] error: sentinels did not met quorum. Exiting."
			fi

		fi

		retries=30
		while [ ${retries} -gt 0 ]; do

			replica_list=()
			i=0
			while IFS= read -r LINE; do
				eval ${LINE//,/ }
				echo -n "[init] pinging replica ${ip}... "
				redis-cli -h ${ip} PING >/dev/null 2>&1
				if [ $? -eq 0 ]; then
					echo "OK"
					replica_list[$i]=${ip}
					i=$((i + 1))
				else
					echo "ERR"
				fi
				unset ip port state offset lag LINE
			done < <(redis-cli INFO replication | awk -F : '/^slave[0-9]/ { print $2 }')

			replica_count=${#replica_list[@]}

			if [ ${replica_count} -ge ${NUM_OF_REPLICAS} ]; then
				# Replicas are up
				break
			fi

			echo "[init] waiting for all replicas to come up: ${replica_count:-0}/${NUM_OF_REPLICAS}"

			retries=$((retries - 1))
			sleep 1
		done
		if [ ${retries} -eq 0 ]; then
			kill -9 `pidof redis-server`
			abort "[init] error: replicas failed to come up. exiting."
		fi

		sleep 60
		echo -n "[init] all replicas are up, forcing failover..."
		while ! \
			redis-cli -h ${SENTINEL_HOSTNAME} -p ${SENTINEL_PORT} SENTINEL failover ${REDIS_MASTER_NAME}; do
			sleep 3
		done
		sleep 60

		retries=10
		while [ ${retries} -gt 0 ]; do
			new_master=$(find_master)
			if [ "${new_master}x" != "nullx" -a ${new_master} != ${self_address} ]; then
				echo "[init] failover finished. new master is ${new_master}..."
				break
			else
				echo "[init] waiting failover to finish..."
			fi
			retries=$((retries - 1))
			sleep 3
		done
		if [ ${retries} -eq 0 ]; then
			kill -9 `pidof redis-server`
			abort "[init] Error: failover failed. Exiting."
		fi

		echo "[init] shuting down redis-init instance:"
		redis-cli SHUTDOWN NOSAVE
		sleep 60

		echo "[init] reseting sentinels:"
		for ip in ${sentinel_ips}; do
			redis-cli -h ${ip} -p ${SENTINEL_PORT} SENTINEL RESET ${REDIS_MASTER_NAME}
		done

		echo "[init] done."
	;;
	replica)
		# Find sentinels
		echo "[replica] searching sentinels..."
		sentinel_ips=$(find_sentinels)

		# Check quorum
		echo "[replica] checking quorum..."
		check_quorum "${sentinel_ips}"

		# Find master
		retries=10
		master=null
		echo "[replica] searching master..."
		while [ ${retries} -gt 0 ]; do
			master=$(find_master)
			echo "[replica] found master: ${master}"
			[ "${master}x" != "nullx" ] && break
			retries=$((retries - 1))
			sleep 5
		done

		echo "[replica] starting replica..."
		rm -rf dump.rdb
		exec gosu redis redis-server --port 6379 --replicaof ${master} 6379
	;;
	*)
		echo "error: REDIS_ROLE must be one of: \"sentinel\" | \"init\" | \"replica\" | \"debug\""
		exit 1
	;;
esac

exit 0
