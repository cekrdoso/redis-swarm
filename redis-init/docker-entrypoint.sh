#!/bin/bash

REDIS_ROLE=${REDIS_ROLE:-"undefined"}
SENTINEL_HOSTNAME=${SENTINEL_HOSTNAME:-"redis-sentinel"}
SENTINEL_PORT=${SENTINEL_PORT:-26379}
REDIS_MASTER_HOSTNAME=${REDIS_MASTER_HOSTNAME:-"redis-init"}
REDIS_MASTER_NAME=${REDIS_MASTER_NAME:-"mymaster"}
NUM_OF_SENTINELS=${NUM_OF_SENTINELS:-3}
NUM_OF_SLAVES=${NUM_OF_SLAVES:-1}
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

	#echo "[get_bulk_value] iplist=\"${iplist[@]}\" port=\"${port}\" key=\"${key}\" command=\"${command}\"" >&2

	local value=null
	local value_list=()
	local c=0
	while [ $c -lt ${#iplist[@]} ]; do
		local v=$(redis-cli -h ${iplist[$c]} -p ${port} ${command} | grep -A1 ${key} | tail -1)
		#echo "[get_bulk_value] v=${v}" >&2
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

		#echo "[compare_values] comparing ${value} with ${l_value}" >&2

		if [ "${value}x" != "${l_value}x" ]; then
			echo "[compare_values] values don't match" >&2
			return 1
		fi

		#echo "[compare_values] ok" >&2

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
			echo "[find_sentinels] Sentinels found: ${sentinels[@]}" >&2
			echo ${sentinels[@]}
			return 0
		fi

		r=$((r - 1))
		sleep ${wait}
	done

	echo "[find_sentinels] Sentinels found: null" >&2
	echo null
	return 1
}

find_master() {
	local iplist="$1"
	local m=null
	local r=10
	while [ $r -gt 0 ]; do
		echo "[find_master] iplist=${iplist}" >&2
		m=$(get_bulk_value "${iplist}" $SENTINEL_PORT \
					ip SENTINEL master $REDIS_MASTER_NAME)
		echo "[find_master] m=${m}" >&2
		[ "${m}x" != "nullx" ] && break
		r=$((r - 1))
		sleep 3
	done
	echo "[find_master] Found master: ${m:-null}" >&2
	echo ${m:-null}
}

check_master() {
	local m=$1
	retries=3
	while [ ${retries} -gt 0 ]; do
		if [ "$(redis-cli -h ${m} -p 6379 INFO replication 2>/dev/null | \
					grep -q -m1 role:master && echo OK)x" == "OKx" ]; then
			echo "[check_master] Master is ok" >&2
			return 0
		fi
		retries=$((retries - 1))
		sleep 3
	done
	echo "[check_master] Could not connect to master" >&2
	return 1
}

check_quorum() {
	local iplist="$1"
	local port=${SENTINEL_PORT}
	local command="SENTINEL ckquorum ${REDIS_MASTER_NAME}"
	for ip in ${iplist}; do
		local v=$(redis-cli -h ${ip} -p ${port} ${command} 2>/dev/null | grep -e "^OK")
		[ -z "${v}" ] && echo "[check_quorum] Quorum was not reached" >&2 && return 1
	done
	echo "[check_quorum] Quorum was reached" >&2
	return 0
}

abort() {
	echo $1
	exit 1
}

self_address=$(get_self_address)
sentinel_ips=null

case $REDIS_ROLE in
	sentinel)

		if check_master "${REDIS_MASTER_HOSTNAME}"; then
			master=${REDIS_MASTER_HOSTNAME}
		else
			while : ; do
				# Search for sentinels
				retries=10
				while [ ${retries} -gt 0 ]; do
					sentinel_ips=$(find_sentinels)
					[ "${sentinel_ips}x" != "nullx" ] && break
					retries=$((retries - 1))
					sleep 3
				done

				# Find master
				retries=10
				master=null
				while [ ${retries} -gt 0 ]; do
					master=$(find_master "${sentinel_ips}")
					[ "${master}x" != "nullx" ] && break
					retries=$((retries - 1))
					sleep 3
				done
				check_master "${master}" && break
			done
		fi

		cat <<-EOF > /sentinel.conf
			port 26379
			sentinel monitor ${REDIS_MASTER_NAME} ${master} 6379 ${SENTINELS_QUORUM}
			sentinel down-after-milliseconds ${REDIS_MASTER_NAME} 5000
			sentinel failover-timeout ${REDIS_MASTER_NAME} 60000
			sentinel parallel-syncs ${REDIS_MASTER_NAME} 1
			EOF
		chown redis:redis /sentinel.conf
		exec gosu redis redis-server /sentinel.conf --sentinel
	;;
	init)
		echo "Starting redis-init..."
		redis-server --port 6379 &
		sleep 5

		while [ "$(redis-cli ping)x" != "PONGx" ]; do
			echo "Waiting redis-init startup..."
			sleep 3
		done

		# Get sentinels ips
		while [ ${#sentinel_ips[@]} -lt ${NUM_OF_SENTINELS} ]; do
			v=$(find_sentinels)
			[ "${v}x" != "nullx" ] && sentinel_ips=( ${v} )
		done
		sentinel_ips="${sentinel_ips[@]}"
		echo "[init] Sentinels: ${sentinel_ips}"

		# Check quorum
		retries=10
		while ! check_quorum "${sentinel_ips}" && [ ${retries} -gt 0 ]; do
			echo "Waiting for sentinels to meet defined quorum..."
			retries=$((retries - 1))
			sleep 3
		done
		if [ ${retries} -eq 0 ]; then
			kill -9 `pidof redis-server`
			abort "Error: sentinels did not met quorum. Exiting."
		fi

		retries=10
		while [ ${retries} -gt 0 ]; do
			
			slave_count=$(get_bulk_value "${sentinel_ips}" $SENTINEL_PORT \
								num-slaves SENTINEL master $REDIS_MASTER_NAME)

			[ "${slave_count}x" == "nullx" ] && slave_count=0

			if [ ${slave_count} -ge ${NUM_OF_SLAVES} ]; then
				# Slaves are up
				break
			fi

			echo "Waiting for all slaves to come up: ${slave_count}/${NUM_OF_SLAVES}"
			retries=$((retries - 1))
			sleep 3
		done
		if [ ${retries} -eq 0 ]; then
			kill -9 `pidof redis-server`
			abort "Error: slaves failed to come up. Exiting."
		fi

		echo "All slaves are up, forcing failover..."
		while ! \
			redis-cli -h ${SENTINEL_HOSTNAME} -p ${SENTINEL_PORT} SENTINEL failover ${REDIS_MASTER_NAME}; do
			sleep 3
		done
		sleep 60

		retries=10
		while [ ${retries} -gt 0 ]; do
			new_master=$(find_master "${sentinel_ips}")
			if [ "${new_master}x" != "nullx" -a ${new_master} != ${self_address} ]; then
				echo "Failover finished. New master is ${new_master}..."
				break
			else
				echo "Waiting failover to finish..."
			fi
			retries=$((retries - 1))
			sleep 3
		done
		if [ ${retries} -eq 0 ]; then
			kill -9 `pidof redis-server`
			abort "Error: failover failed. Exiting."
		fi

		echo "Finished!"
		redis-cli SHUTDOWN NOSAVE
		sleep 10

		for ip in ${sentinel_ips}; do
			redis-cli -h ${ip} -p ${SENTINEL_PORT} SENTINEL RESET ${REDIS_MASTER_NAME}
		done
	;;
	slave)
		echo "Starting slave..."

		# Search for sentinels
		retries=10
		while [ ${retries} -gt 0 ]; do
			sentinel_ips=$(find_sentinels)
			[ "${sentinel_ips}x" != "nullx" ] && break
			retries=$((retries - 1))
			sleep 3
		done
		echo "Sentinels found: ${sentinel_ips}"

		# Find master
		retries=10
		master=null
		echo "Searching master..."
		while [ ${retries} -gt 0 ]; do
			master=$(find_master "${sentinel_ips}")
			echo "Found master=${master}"
			[ "${master}x" != "nullx" ] && break
			retries=$((retries - 1))
			sleep 3
		done

		exec gosu redis redis-server --port 6379 --replicaof ${master} 6379
	;;
	*)
		echo "Error: REDIS_ROLE must be of \"sentinel\" or \"init\" or \"slave\""
		exit 1
	;;
esac

exit 0